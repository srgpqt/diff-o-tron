#import <Cocoa/Cocoa.h>

/* A comparison's window: its changed files in a sidebar, and the diff of the selected one beside it; for a merge, with the merged result below. */
@interface DiffWindowController : NSWindowController <NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSplitViewDelegate, NSTextViewDelegate>
	- (void) documentDidChange;
	/* side is a side, or kSideCount to replace all sides. */
	- (void) dropURLs:(NSArray<NSURL*>*)urls side:(NSInteger)side;
@end
