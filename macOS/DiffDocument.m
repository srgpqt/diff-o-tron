#import "DiffDocument.h"

#import "DiffWindowController.h"
#import "PathWatcher.h"

#include "request.h"

/* Drags can carry file reference URLs (file:///.file/id=…); compare by path. */
static id path_url(NSURL* url) {
	NSURL* pathURL = url.filePathURL;
	return pathURL ? pathURL : (url ? (id)url : [NSNull null]);
}

@implementation DiffDocument {
	/* An NSURL or NSNull per side. */
	NSMutableArray* _urls;
	/* A label per side, empty for none. */
	NSMutableArray<NSString*>* _labels;

	/* Watching the sides, to reload when they change. */
	NSArray<PathWatcher*>* _watchers;
	/* Identifies the latest reload asked for, so that earlier ones gathered in its delay don't run. */
	NSUInteger _reloadRequest;
	BOOL _reloading;
	/* A reload asked for while comparing, to run when that's done. */
	BOOL _reloadWhenCompared;
}

- (instancetype) init {
	if ((self = [super init])) {
		_urls = [NSMutableArray array];
		_labels = [NSMutableArray array];
		for (NSUInteger side = 0; side < kSideCount; side++) {
			[_urls addObject:[NSNull null]];
			[_labels addObject:@""];
		}
	}
	return self;
}

- (void) dealloc {
	for (PathWatcher* watcher in _watchers) [watcher stop];
	dt_comparison_free(_comparison);
}

+ (BOOL) autosavesInPlace {
	return NO;
}

- (void) makeWindowControllers {
	[self addWindowController:[[DiffWindowController alloc] init]];
}

- (void) close {
	for (PathWatcher* watcher in _watchers) [watcher stop];
	_watchers = nil;
	NSString* token = _closeToken;
	_closeToken = nil;
	[super close];
	if (token) post_request_notification(kClosedNotification, token);
}

- (NSString*) displayName {
	NSString* a = [self urlForSide:0] ? [self nameForSide:0] : nil;
	NSString* b = [self urlForSide:1] ? [self nameForSide:1] : nil;
	if (a && b) {
		if ([a isEqualToString:b]) return a;
		return [NSString stringWithFormat:@"%@ ↔ %@", a, b];
	}
	if (a || b) return a ? a : b;
	return @"New Comparison";
}

- (NSString*) labelForSide:(NSUInteger)side {
	NSString* label = side < _labels.count ? _labels[side] : nil;
	return label.length > 0 ? label : nil;
}

- (NSString*) nameForSide:(NSUInteger)side {
	NSString* label = [self labelForSide:side];
	return label ? label : [self urlForSide:side].lastPathComponent;
}

- (NSURL*) urlForSide:(NSUInteger)side {
	id url = side < _urls.count ? _urls[side] : nil;
	return [url isKindOfClass:[NSURL class]] ? url : nil;
}

- (BOOL) isEmpty {
	for (NSUInteger side = 0; side < kSideCount; side++) {
		if ([self urlForSide:side]) return NO;
	}
	return YES;
}

- (void) setURL:(NSURL*)url forSide:(NSUInteger)side {
	if (side >= kSideCount) return;
	_urls[side] = path_url(url);
	_labels[side] = @"";
	[self urlsDidChange];
}

- (void) setURLs:(NSArray<NSURL*>*)urls {
	[self setURLs:urls labels:nil];
}

- (void) setURLs:(NSArray<NSURL*>*)urls labels:(NSArray<NSString*>*)labels {
	for (NSUInteger side = 0; side < kSideCount && side < urls.count; side++) {
		_urls[side] = path_url(urls[side]);
		id label = side < labels.count ? labels[side] : nil;
		_labels[side] = [label isKindOfClass:[NSString class]] ? label : @"";
	}
	[self urlsDidChange];
}

/* Start comparing in the background once every side is set, and watch the sides for changes. */
- (void) urlsDidChange {
	_generation++;
	dt_comparison_free(_comparison);
	_comparison = NULL;
	_reloaded = NO;
	_reloading = NO;
	_reloadWhenCompared = NO;

	NSURL* a = [self urlForSide:0];
	NSURL* b = [self urlForSide:1];
	_comparing = a && b;
	[self watchSides];
	if (_comparing) [self compareReloading:NO];
	[self notifyWindowControllers];
}

- (void) watchSides {
	for (PathWatcher* watcher in _watchers) [watcher stop];
	NSMutableArray<PathWatcher*>* watchers = [NSMutableArray array];
	__weak DiffDocument* weakSelf = self;
	for (NSUInteger side = 0; side < kSideCount; side++) {
		NSURL* url = [self urlForSide:side];
		if (!url) continue;
		[watchers addObject:[[PathWatcher alloc] initWithURL:url handler:^(void) {
			[weakSelf sideDidChange];
		}]];
	}
	_watchers = watchers;
}

/* Reload a moment after the last of a burst of changes. */
- (void) sideDidChange {
	NSUInteger request = ++_reloadRequest;
	__weak DiffDocument* weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kReloadDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^(void) {
		DiffDocument* doc = weakSelf;
		if (doc && doc->_reloadRequest == request) [doc reload];
	});
}

- (void) reload {
	if (![self urlForSide:0] || ![self urlForSide:1]) return;
	if (_comparing || _reloading) {
		_reloadWhenCompared = YES;
		return;
	}
	_reloading = YES;
	[self compareReloading:YES];
}

/*
 * Compare the sides in the background. Reloading keeps showing the current
 * comparison until the new one's ready, and keeps it if a side is gone, as
 * git difftool's temporary files are once it's done.
 */
- (void) compareReloading:(BOOL)reloading {
	NSUInteger generation = _generation;
	NSString* pathA = [self urlForSide:0].path;
	NSString* pathB = [self urlForSide:1].path;
	__weak DiffDocument* weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(void) {
		DtComparison* cmp = dt_comparison_new(pathA.fileSystemRepresentation, pathB.fileSystemRepresentation);
		dispatch_async(dispatch_get_main_queue(), ^(void) {
			DiffDocument* doc = weakSelf;
			if (!doc || doc->_generation != generation) {
				dt_comparison_free(cmp);
				return;
			}
			DtComparison* result = cmp;
			if (reloading) {
				doc->_reloading = NO;
				if (doc->_comparison && dt_comparison_error(result).len > 0) {
					dt_comparison_free(result);
					result = NULL;
				}
			}
			if (result) {
				dt_comparison_free(doc->_comparison);
				doc->_generation++;
				doc->_comparison = result;
				doc->_comparing = NO;
				doc->_reloaded = reloading;
				[doc notifyWindowControllers];
			}
			if (doc->_reloadWhenCompared) {
				doc->_reloadWhenCompared = NO;
				[doc reload];
			}
		});
	});
}

- (void) notifyWindowControllers {
	for (NSWindowController* controller in self.windowControllers) {
		if ([controller isKindOfClass:[DiffWindowController class]]) {
			[(DiffWindowController*)controller documentDidChange];
		}
	}
}

@end
