#import "Common.h"

/* DiffView.mode */
enum {
	kDiffModeBlocks = 0, /* the sides' lines aligned, with filler where a side has none */
	kDiffModeFluid = 1,  /* each side's lines together, with connectors joining the changes */
	kDiffModeUnified = 2, /* one column of lines, the changed ones from either side */
};

/* The width of the gap between sides. */
static const CGFloat kMiddleWidth = 40;

/*
 * Draws a file diff as side-by-side panes. A DiffView lays out, for each side,
 * a gutter of line numbers and a scroll view with that side's text, with
 * connectors between the sides. Each side scrolls sideways on its own, and up
 * and down together with the others.
 */
@interface DiffView : NSView
	/* Owned: freed when replaced. */
	@property (nonatomic) DtFileDiff* diff;
	/*
	 * Show a new diff, keeping where the view is scrolled to and the nearest hunk
	 * current if keep is set, as when the same files are reloaded.
	 */
	- (void) setDiff:(DtFileDiff*)diff keepingPosition:(BOOL)keep;
	@property (nonatomic) NSInteger mode;
	@property (nonatomic) BOOL wrapsLines;
	/* The files shown, for their context menus: an NSURL per side, or NSNull for none. */
	@property (nonatomic, copy) NSArray* fileURLs;
	@property (nonatomic) CGFloat fontSize;
	/* Index of the highlighted hunk, or -1. */
	@property (nonatomic) NSInteger currentHunk;
	/* Called when a click changes currentHunk. */
	@property (nonatomic, copy) void (^currentHunkChanged)(void);
	- (void) scrollToCurrentHunk;
	/* Light up the current hunk for a moment, as when there's no hunk further on to move to. */
	- (void) flashCurrentHunk;
@end
