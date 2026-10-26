#import "DiffDocumentController.h"

#import "Common.h"
#import "DiffDocument.h"

#include "request.h"

@implementation DiffDocumentController {
	/* URLs AppKit opened one by one, gathered to open together. */
	NSMutableArray<NSURL*>* _pendingURLs;
}

- (NSString*) defaultType {
	return kComparisonType;
}

- (NSArray<NSString*>*) documentClassNames {
	return @[NSStringFromClass([DiffDocument class])];
}

- (Class) documentClassForType:(NSString*)typeName {
	return [DiffDocument class];
}

- (NSString*) displayNameForType:(NSString*)typeName {
	return kComparisonType;
}

/* Choose the files or folders to compare. */
- (IBAction) openDocument:(id)sender {
	NSOpenPanel* panel = [NSOpenPanel openPanel];
	panel.canChooseFiles = YES;
	panel.canChooseDirectories = YES;
	panel.allowsMultipleSelection = YES;
	panel.message = @"Choose two files or folders to compare.";
	panel.prompt = @"Compare";
	[panel beginWithCompletionHandler:^(NSModalResponse result) {
		if (result == NSModalResponseOK) [self openComparisonWithURLs:panel.URLs labels:nil];
	}];
}

/*
 * Files and folders opened from the Finder, the Dock, `open -a` or the
 * diffotron command. AppKit opens them through the document controller one at
 * a time, even when opened together, so gather them up.
 */
- (void) openDocumentWithContentsOfURL:(NSURL*)url display:(BOOL)display completionHandler:(void (^)(NSDocument*, BOOL, NSError*))completionHandler {
	os_log(open_log(), "Document controller opening %{public}@", url);
	if (!_pendingURLs) {
		_pendingURLs = [NSMutableArray array];
		dispatch_async(dispatch_get_main_queue(), ^(void) {
			NSArray<NSURL*>* urls = self->_pendingURLs;
			self->_pendingURLs = nil;
			[self openFilesAtURLs:urls];
		});
	}
	[_pendingURLs addObject:url];
	completionHandler(nil, NO, nil);
}

- (void) openFilesAtURLs:(NSArray<NSURL*>*)urls {
	os_log(open_log(), "Opening %{public}@", urls);
	NSMutableArray<NSURL*>* files = [NSMutableArray array];
	BOOL requested = NO;
	for (NSURL* url in urls) {
		if ([url.pathExtension isEqualToString:kRequestExtension]) {
			[self openRequestAtURL:url];
			requested = YES;
		} else {
			[files addObject:url];
		}
	}
	/* With a request, the other files only came along so the sandbox lets the app read them. */
	if (!requested) [self openComparisonWithURLs:files labels:nil];
}

/* Open a comparison requested by the diffotron command, and tell it so. */
- (void) openRequestAtURL:(NSURL*)url {
	NSError* error = nil;
	NSData* data = [NSData dataWithContentsOfURL:url options:0 error:&error];
	NSDictionary* request = data
		? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:&error]
		: nil;
	NSString* token = [request isKindOfClass:[NSDictionary class]] ? request[kRequestToken] : nil;
	if (![token isKindOfClass:[NSString class]]) {
		os_log_error(open_log(), "Can't read request %{public}@: %{public}@", url.path, error);
		if (!error) {
			NSString* reason = [NSString stringWithFormat:@"“%@” isn't a comparison request.", url.lastPathComponent];
			error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{NSLocalizedDescriptionKey: reason}];
		}
		[self presentError:error];
		return;
	}

	NSMutableArray<NSURL*>* urls = [NSMutableArray array];
	NSArray* paths = request[kRequestPaths];
	if ([paths isKindOfClass:[NSArray class]]) {
		for (id path in paths) {
			if ([path isKindOfClass:[NSString class]]) [urls addObject:[NSURL fileURLWithPath:path]];
		}
	}
	NSArray* labels = request[kRequestLabels];
	if (![labels isKindOfClass:[NSArray class]]) labels = nil;
	BOOL wait = [request[kRequestWait] boolValue];

	DiffDocument* doc = urls.count == kSideCount ? [self openComparisonWithURLs:urls labels:labels] : nil;
	if (doc && wait) doc.closeToken = token;
	post_request_notification(kOpenedNotification, token);
	if (!doc && wait) post_request_notification(kClosedNotification, token);
}

/* Compare the URLs in the frontmost window if it's empty, or else in a new one. */
- (DiffDocument*) openComparisonWithURLs:(NSArray<NSURL*>*)urls labels:(NSArray<NSString*>*)labels {
	if (urls.count == 0) return nil;
	DiffDocument* doc = nil;
	NSDocument* current = self.currentDocument;
	if ([current isKindOfClass:[DiffDocument class]] && [(DiffDocument*)current isEmpty]) {
		doc = (DiffDocument*)current;
	} else {
		NSError* error = nil;
		doc = [self openUntitledDocumentAndDisplay:YES error:&error];
		if (!doc) {
			if (error) [self presentError:error];
			return nil;
		}
	}
	[doc setURLs:urls labels:labels];
	[doc showWindows];
	return doc;
}

@end
