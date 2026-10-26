#import "PathWatcher.h"

#import "Common.h"

#include <fcntl.h>
#include <unistd.h>

/* How often to look for a watched file that's gone, such as while it's being saved. */
static const NSTimeInterval kRewatchDelay = 1;

@implementation PathWatcher {
	NSURL* _url;
	void (^_handler)(void);
	FSEventStreamRef _stream;
	dispatch_source_t _source;
	BOOL _stopped;
}

static void folder_did_change(
	ConstFSEventStreamRef stream, void* info, size_t count, void* paths,
	const FSEventStreamEventFlags flags[], const FSEventStreamEventId ids[]
) {
	PathWatcher* watcher = (__bridge PathWatcher*)info;
	[watcher changed];
}

- (instancetype) initWithURL:(NSURL*)url handler:(void (^)(void))handler {
	if ((self = [super init])) {
		_url = url;
		_handler = [handler copy];
		if (is_directory(url)) {
			[self watchFolder];
		} else {
			[self watchFileAfterChange:NO];
		}
	}
	return self;
}

- (void) dealloc {
	[self stop];
}

- (void) stop {
	_stopped = YES;
	if (_stream) {
		FSEventStreamStop(_stream);
		FSEventStreamInvalidate(_stream);
		FSEventStreamRelease(_stream);
		_stream = NULL;
	}
	if (_source) {
		dispatch_source_cancel(_source);
		_source = nil;
	}
}

- (void) changed {
	if (!_stopped) _handler();
}

- (void) watchFolder {
	FSEventStreamContext context = {0, (__bridge void*)self, NULL, NULL, NULL};
	NSArray* paths = @[_url.path];
	_stream = FSEventStreamCreate(
		NULL, folder_did_change, &context, (__bridge CFArrayRef)paths, kFSEventStreamEventIdSinceNow,
		kReloadDelay, kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer);
	if (!_stream) return;
	FSEventStreamSetDispatchQueue(_stream, dispatch_get_main_queue());
	FSEventStreamStart(_stream);
}

/*
 * Watch the file at the URL, or look for it again later if it's gone. Saving
 * often replaces a file with a new one, so after one is deleted or renamed,
 * watch whatever's at the URL next. changed: whether to call the handler once
 * the file's found.
 */
- (void) watchFileAfterChange:(BOOL)changed {
	if (_stopped) return;
	int fd = open(_url.fileSystemRepresentation, O_EVTONLY);
	if (fd < 0) {
		__weak PathWatcher* weakSelf = self;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRewatchDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^(void) {
			[weakSelf watchFileAfterChange:YES];
		});
		return;
	}
	if (changed) [self changed];

	unsigned long events = DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_ATTRIB
		| DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE;
	dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd, events, dispatch_get_main_queue());
	__weak PathWatcher* weakSelf = self;
	dispatch_source_set_event_handler(source, ^(void) {
		PathWatcher* watcher = weakSelf;
		if (!watcher) return;
		[watcher changed];
		if (dispatch_source_get_data(source) & (DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE)) {
			dispatch_source_cancel(source);
			watcher->_source = nil;
			[watcher watchFileAfterChange:NO];
		}
	});
	dispatch_source_set_cancel_handler(source, ^(void) {
		close(fd);
	});
	_source = source;
	dispatch_resume(source);
}

@end
