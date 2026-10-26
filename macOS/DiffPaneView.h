#import <Cocoa/Cocoa.h>

@class DiffView;

/* One side's text, in its own scroll view. */
@interface DiffPaneView : NSView
	@property (nonatomic, readonly) NSUInteger side;
	- (instancetype) initWithOwner:(DiffView*)owner side:(NSUInteger)side;
	/* The diff changed: clear the selection, and scroll to the top if scrollToTop is set. */
	- (void) diffDidChange:(BOOL)scrollToTop;
	- (void) modeDidChange;
	- (void) relayout;
	- (void) clearSelection;
@end
