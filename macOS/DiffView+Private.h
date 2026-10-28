/* What the parts of a DiffView share: DiffView.m, DiffPaneView.m, DiffGutterView.m and DiffConnectorView.m; and its colors, with MergeEditor.m. */

#import <CoreText/CoreText.h>

#import "DiffView.h"

static const CGFloat kTopPadding = 4;
static const CGFloat kGutterPadding = 8;
static const CGFloat kTextPadding = 8;
static const CGFloat kUnifiedLetterWidth = 14;

/* The number of DtLine.kind values, which also color hunks by DtHunk.kind. */
#define kKindCount 5

/* Colors, indexed by DtLine.kind and DtHunk.kind. */
extern NSColor* g_line_colors[kKindCount];
/* For the lines of the current hunk. */
extern NSColor* g_current_line_colors[kKindCount];
extern NSColor* g_emphasis_colors[kKindCount];
extern NSColor* g_edge_colors[kKindCount];
extern NSColor* g_filler_color;
extern NSColor* g_middle_color;

/* The background of a changed line, or the band joining a hunk across sides. */
NSColor* line_color(uint8_t kind, BOOL inCurrentHunk);

static NSUInteger min_index(NSUInteger a, NSUInteger b) {
	return a < b ? a : b;
}

@class DiffPaneView;

/* What the parts of a DiffView share. */
@interface DiffView ()
	@property (nonatomic, readonly) NSFont* font;
	/* Core Text attributes, so drawing and hit testing share one layout. */
	@property (nonatomic, readonly) NSDictionary* textAttributes;
	@property (nonatomic, readonly) NSDictionary* numberAttributes;

	@property (nonatomic, readonly) CGFloat lineHeight;
	@property (nonatomic, readonly) CGFloat fontLineHeight;
	@property (nonatomic, readonly) CGFloat textInset;
	@property (nonatomic, readonly) CGFloat charWidth;
	@property (nonatomic, readonly) CGFloat gutterWidth;
	/* In Unified mode, the width of each side's column of line numbers in the gutter. */
	@property (nonatomic, readonly) CGFloat unifiedColumnWidth;
	/* The widest line of any side. */
	@property (nonatomic, readonly) uint32_t maxColumns;
	/* The sides the diff has: 2, or 3 for a merge. */
	@property (nonatomic, readonly) NSUInteger sideCount;

	/*
	 * The layout. Each line takes a line height, or several when wrapped. In
	 * Blocks mode, rows take the height of their tallest line; in Fluid mode,
	 * each side's lines lay out on their own; in Unified mode, so do unified
	 * rows. Positions are in document coordinates; a row or line count gives
	 * where they end.
	 */
	- (CGFloat) rowY:(size_t)row;
	- (CGFloat) lineY:(size_t)line side:(NSUInteger)side;
	- (CGFloat) unifiedY:(size_t)row;
	/* The row or line at y: -1 above the first, or the count below the last. */
	- (NSInteger) rowAtY:(CGFloat)y;
	- (NSInteger) lineAtY:(CGFloat)y side:(NSUInteger)side;
	- (NSInteger) unifiedRowAtY:(CGFloat)y;
	/* The rows or lines from first up to last that overlap top to bottom. */
	- (void) rowsFrom:(CGFloat)top to:(CGFloat)bottom first:(size_t*)first last:(size_t*)last;
	- (void) linesFrom:(CGFloat)top to:(CGFloat)bottom side:(NSUInteger)side first:(size_t*)first last:(size_t*)last;
	- (void) unifiedRowsFrom:(CGFloat)top to:(CGFloat)bottom first:(size_t*)first last:(size_t*)last;
	/* Where the current mode's rows end. */
	- (CGFloat) contentBottom;
	/* Call block with each line of a line's text as laid out: several when it wraps. */
	- (void) enumerateLinesOfText:(NSString*)text block:(void (^)(CTLineRef line, CFRange range, NSUInteger index))block;
	/* A pane's scroll view changed size. */
	- (void) paneDidResize:(DiffPaneView*)pane;

	/* How far a side is scrolled down. */
	- (CGFloat) verticalOffset:(NSUInteger)side;
	/*
	 * In Fluid mode, how far down a side's own layout is from the shared one,
	 * so that a line at y in it shows at y - shift in the side's document; 0 in
	 * Blocks mode.
	 */
	- (CGFloat) shift:(NSUInteger)side;
	/* Scroll for a wheel over a side's pane or gutter, in Fluid mode: NO otherwise, for its scroll view to. */
	- (BOOL) scrollWheel:(NSEvent*)event side:(NSUInteger)side;
	/* A side's scroll view. */
	- (NSScrollView*) scrollViewOfSide:(NSUInteger)side;
	/* The lines a hunk covers on a side. */
	- (void) hunk:(DtHunk)hunk side:(NSUInteger)side start:(uint32_t*)start end:(uint32_t*)end;
	- (BOOL) rowInCurrentHunk:(size_t)row;
	- (BOOL) lineInCurrentHunk:(size_t)line side:(NSUInteger)side;
	/*
	 * Whether a side has no lines, as for an added or deleted file. Its hunks
	 * aren't outlined, nor joined to the other side's.
	 */
	- (BOOL) sideIsEmpty:(NSUInteger)side;
	/* Outline the hunks in dirty, drawn offset up, with bands filling them if bands is set. */
	- (void) drawHunksInRect:(NSRect)dirty offset:(CGFloat)offset bands:(BOOL)bands;
	/* In Fluid mode, outline a side's hunks in dirty, its own layout drawn offset up. */
	- (void) drawSideHunks:(NSUInteger)side inRect:(NSRect)dirty offset:(CGFloat)offset;
	- (void) selectHunkAtRow:(size_t)row;
	- (void) selectHunkAtLine:(size_t)line side:(NSUInteger)side;

	/* In Unified mode, the side and line a row shows: side A's for an unchanged line. */
	- (BOOL) unifiedRow:(size_t)row side:(NSUInteger*)side line:(size_t*)line;
	- (BOOL) unifiedRowInCurrentHunk:(size_t)row;
	/* Whether a row starts a run of changed lines of the same kind, from the same side. */
	- (BOOL) unifiedGroupStartsAtRow:(size_t)row;
	/* Outline the runs of changed lines in the rows from first up to last, drawn offset up. */
	- (void) drawUnifiedGroupsFrom:(size_t)first to:(size_t)last inRect:(NSRect)dirty offset:(CGFloat)offset;
	- (void) selectHunkAtUnifiedRow:(size_t)row;
	/* While the current hunk is flashing, light up its part of a side in dirty, drawn offset up. */
	- (void) drawFlashForSide:(NSUInteger)side inRect:(NSRect)dirty offset:(CGFloat)offset;
	- (void) paneDidSelect:(DiffPaneView*)pane;
	/* The file shown on a side, or nil. */
	- (NSURL*) fileURLForSide:(NSUInteger)side;
@end
