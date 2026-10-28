#import "Common.h"

NSString* dt_string(DtStr s) {
	NSString* string = [[NSString alloc] initWithBytes:s.ptr length:s.len encoding:NSUTF8StringEncoding];
	return string ? string : @"";
}

os_log_t open_log(void) {
	static os_log_t log = NULL;
	if (!log) log = os_log_create("com.srgpqt.diff-o-tron", "open");
	return log;
}

void post_request_notification(NSString* name, NSString* token) {
	os_log(open_log(), "Posting %{public}@ for %{public}@", name, token);
	[[NSDistributedNotificationCenter defaultCenter] postNotificationName:name object:token userInfo:nil deliverImmediately:YES];
}

void clip_to_bounds(NSView* view) {
	if (@available(macOS 14.0, *)) view.clipsToBounds = YES;
}

void add_subviews(NSView* parent, NSArray<NSView*>* views) {
	for (NSView* view in views) {
		view.translatesAutoresizingMaskIntoConstraints = NO;
		[parent addSubview:view];
	}
}

BOOL is_directory(NSURL* url) {
	NSNumber* directory = nil;
	[url getResourceValue:&directory forKey:NSURLIsDirectoryKey error:NULL];
	return directory.boolValue;
}

NSFont* text_font(NSString* family, CGFloat size) {
	/* Weight 5 is regular. */
	NSFont* font = family.length > 0 ? [[NSFontManager sharedFontManager] fontWithFamily:family traits:0 weight:5 size:size] : nil;
	return font ? font : [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular];
}
