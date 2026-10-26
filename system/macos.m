#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>

#include <math.h>
#include <os/log.h>

#include "diffotron.h"
#include "macos-request.h"

/*
 * The macOS front end: an NSDocument app where each document is a comparison of
 * two files or folders, shown in a window with the changed files in a sidebar
 * and the diff of the selected file beside it.
 */

static NSString* const kComparisonType = @"Comparison";

/* User defaults: the DiffView mode new windows start in, and whether they wrap lines. */
static NSString* const kDiffModeDefault = @"DiffMode";
static NSString* const kWrapLinesDefault = @"WrapLines";
/* User defaults: the frame of the comparison window last moved or resized, where new ones open. */
static NSString* const kWindowFrameDefault = @"WindowFrame";
/* How far a new window is moved off a window already where it would open. */
static const CGFloat kCascadeOffset = 22;

/*
 * Labels whose text may be too long hold their width below the sidebar's
 * holding priority, so they truncate instead of making it narrower.
 */
static const NSLayoutPriority kSidebarHoldingPriority = NSLayoutPriorityDefaultLow + 10;
static const NSLayoutPriority kSqueezablePriority = NSLayoutPriorityDefaultLow;

/* The number of compared sides; a merge will add a base and a result. */
static const NSUInteger kSideCount = 2;
static const uint32_t kTabWidth = 4;
static const CGFloat kHeaderHeight = 36;
static const CGFloat kBottomBarHeight = 32;

static NSString* dt_string(DtStr s) {
	NSString* string = [[NSString alloc] initWithBytes:s.ptr length:s.len encoding:NSUTF8StringEncoding];
	return string ? string : @"";
}

/* See with `log stream --predicate 'subsystem == "com.srgpqt.diff-o-tron"'`. */
static os_log_t open_log(void) {
	static os_log_t log = NULL;
	if (!log) log = os_log_create("com.srgpqt.diff-o-tron", "open");
	return log;
}

static void post_request_notification(NSString* name, NSString* token) {
	os_log(open_log(), "Posting %{public}@ for %{public}@", name, token);
	[[NSDistributedNotificationCenter defaultCenter] postNotificationName:name object:token userInfo:nil deliverImmediately:YES];
}

/*
 * Since macOS 14, views don't clip their drawing to their bounds by default,
 * and drawRect: can be asked to draw outside them.
 */
static void clip_to_bounds(NSView* view) {
	if (@available(macOS 14.0, *)) view.clipsToBounds = YES;
}

static void add_subviews(NSView* parent, NSArray<NSView*>* views) {
	for (NSView* view in views) {
		view.translatesAutoresizingMaskIntoConstraints = NO;
		[parent addSubview:view];
	}
}

#pragma mark - Colors

static NSColor* rgb(uint32_t hex) {
	return [NSColor
		colorWithSRGBRed:(CGFloat)((hex >> 16) & 0xff) / 255.0
		green:(CGFloat)((hex >> 8) & 0xff) / 255.0
		blue:(CGFloat)(hex & 0xff) / 255.0
		alpha:1.0];
}

static NSColor* dynamic_color(uint32_t light, uint32_t dark) {
	NSColor* lightColor = rgb(light);
	NSColor* darkColor = rgb(dark);
	return [NSColor colorWithName:nil dynamicProvider:^NSColor* (NSAppearance* appearance) {
		NSAppearanceName name = [appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
		return [name isEqualToString:NSAppearanceNameDarkAqua] ? darkColor : lightColor;
	}];
}

/* Indexed by DtLine.kind. */
static NSColor* g_line_colors[4];
/* For the lines of the current hunk. */
static NSColor* g_current_line_colors[4];
static NSColor* g_emphasis_colors[4];
static NSColor* g_edge_colors[4];
static NSColor* g_filler_color;
static NSColor* g_middle_color;

static void init_colors(void) {
	g_line_colors[DT_LINE_CHANGED] = dynamic_color(0xECE8FD, 0x37324F);
	g_line_colors[DT_LINE_REMOVED] = dynamic_color(0xFCE6E6, 0x432729);
	g_line_colors[DT_LINE_ADDED] = dynamic_color(0xE3F5DC, 0x253A26);
	g_current_line_colors[DT_LINE_CHANGED] = dynamic_color(0xDED7FB, 0x433C62);
	g_current_line_colors[DT_LINE_REMOVED] = dynamic_color(0xF8D5D5, 0x552F32);
	g_current_line_colors[DT_LINE_ADDED] = dynamic_color(0xD2EDC8, 0x2D4830);
	g_emphasis_colors[DT_LINE_CHANGED] = dynamic_color(0xC6BAF6, 0x5D50A0);
	g_emphasis_colors[DT_LINE_REMOVED] = dynamic_color(0xF1B3B3, 0x7A3C43);
	g_emphasis_colors[DT_LINE_ADDED] = dynamic_color(0xB2E2A0, 0x3D6E40);
	g_edge_colors[DT_LINE_CHANGED] = dynamic_color(0x9A8AE8, 0x7D6BD6);
	g_edge_colors[DT_LINE_REMOVED] = dynamic_color(0xE08080, 0xB0545C);
	g_edge_colors[DT_LINE_ADDED] = dynamic_color(0x7CC46A, 0x4F9A55);
	g_filler_color = dynamic_color(0xF4F4F6, 0x262628);
	g_middle_color = dynamic_color(0xF7F7F9, 0x232325);
}

/* The background of a changed line, or the band joining a hunk across sides. */
static NSColor* line_color(uint8_t kind, BOOL inCurrentHunk) {
	return inCurrentHunk ? g_current_line_colors[kind] : g_line_colors[kind];
}

static uint8_t hunk_kind(DtHunk hunk) {
	if (hunk.a_start == hunk.a_end) return DT_LINE_ADDED;
	if (hunk.b_start == hunk.b_end) return DT_LINE_REMOVED;
	return DT_LINE_CHANGED;
}

static NSString* status_symbol(uint8_t status) {
	switch (status) {
		case DT_STATUS_MODIFIED: return @"triangle";
		case DT_STATUS_ADDED: return @"plus";
		case DT_STATUS_REMOVED: return @"minus";
		default: return @"equal";
	}
}

static NSString* status_name(uint8_t status) {
	switch (status) {
		case DT_STATUS_MODIFIED: return @"Modified";
		case DT_STATUS_ADDED: return @"Added";
		case DT_STATUS_REMOVED: return @"Removed";
		default: return @"Unchanged";
	}
}

static NSColor* status_color(uint8_t status) {
	switch (status) {
		case DT_STATUS_MODIFIED: return [NSColor systemPurpleColor];
		case DT_STATUS_ADDED: return [NSColor systemGreenColor];
		case DT_STATUS_REMOVED: return [NSColor systemRedColor];
		default: return [NSColor tertiaryLabelColor];
	}
}

#pragma mark - Interfaces

/* DiffView.mode */
enum {
	kDiffModeBlocks = 0, /* the sides' lines aligned, with filler where a side has none */
	kDiffModeFluid = 1,  /* each side's lines together, with connectors joining the changes */
	kDiffModeUnified = 2, /* one column of lines, the changed ones from either side */
};

/* Draws a file diff as side-by-side panes. */
@interface DiffView : NSView
	/* Owned: freed when replaced. */
	@property (nonatomic) DtFileDiff* diff;
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
@end

/* Shows where a drag will drop; transparent to the mouse. */
@interface DropHighlightView : NSView
	/* -1 for none, a side, or kSideCount for all sides. */
	@property (nonatomic) NSInteger side;
@end

@class DiffWindowController;

/* Accepts files and folders dropped onto either half of it. */
@interface DropView : NSView
	@property (nonatomic, weak) DiffWindowController* controller;
	@property (nonatomic, weak) DropHighlightView* highlightView;
@end

@interface SidebarItem : NSObject
	@property (nonatomic) BOOL isGroup;
	@property (nonatomic, copy) NSString* title;
	@property (nonatomic) size_t entry;
	@property (nonatomic) uint8_t status;
@end

@interface DiffWindowController : NSWindowController <NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate>
	- (void) documentDidChange;
	/* side is a side, or kSideCount to replace all sides. */
	- (void) dropURLs:(NSArray<NSURL*>*)urls side:(NSInteger)side;
@end

/* A comparison of the files or folders at its URLs. Never saved. */
@interface DiffDocument : NSDocument
	@property (nonatomic, readonly) DtComparison* comparison;
	@property (nonatomic, readonly) BOOL comparing;
	/* Incremented whenever the comparison is replaced. */
	@property (nonatomic, readonly) NSUInteger generation;
	/* Posted with kClosedNotification when the document closes. */
	@property (nonatomic, copy) NSString* closeToken;
	- (NSURL*) urlForSide:(NSUInteger)side;
	/* Shown instead of a side's name, such as the repository path from git difftool; nil for none. */
	- (NSString*) labelForSide:(NSUInteger)side;
	/* The side's label, or else its file name. */
	- (NSString*) nameForSide:(NSUInteger)side;
	- (void) setURL:(NSURL*)url forSide:(NSUInteger)side;
	/* Sets the sides from the first URLs. */
	- (void) setURLs:(NSArray<NSURL*>*)urls;
	/* Sets the sides and their labels (empty strings for none) from the first of each. */
	- (void) setURLs:(NSArray<NSURL*>*)urls labels:(NSArray<NSString*>*)labels;
	- (BOOL) isEmpty;
@end

@interface DiffDocumentController : NSDocumentController
	/* Open files opened together, such as the diffotron command's request and its files. */
	- (void) openFilesAtURLs:(NSArray<NSURL*>*)urls;
	- (DiffDocument*) openComparisonWithURLs:(NSArray<NSURL*>*)urls labels:(NSArray<NSString*>*)labels;
@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

#pragma mark - DiffView

/*
 * A DiffView lays out, for each side, a gutter of line numbers and a scroll
 * view with that side's text, with connectors between the sides. Each side
 * scrolls sideways on its own, and up and down together with the others.
 */

static const CGFloat kTopPadding = 4;
static const CGFloat kMiddleWidth = 40;
static const CGFloat kGutterPadding = 8;
static const CGFloat kTextPadding = 8;
static const CGFloat kUnifiedLetterWidth = 14;

/* A caret position in one side's text: a line, and a UTF-16 offset into it. */
typedef struct {
	NSInteger line;
	NSUInteger index;
} TextPosition;

static const TextPosition kNoPosition = {-1, 0};

static BOOL position_before(TextPosition a, TextPosition b) {
	return a.line < b.line || (a.line == b.line && a.index < b.index);
}

static BOOL position_equal(TextPosition a, TextPosition b) {
	return a.line == b.line && a.index == b.index;
}

static NSUInteger min_index(NSUInteger a, NSUInteger b) {
	return a < b ? a : b;
}

/*
 * A layout of rows of varying heights, as CGFloats: where each row starts in
 * document coordinates, and after the last, where they end.
 */

static size_t tops_count(NSData* tops) {
	size_t entries = tops.length / sizeof(CGFloat);
	return entries > 0 ? entries - 1 : 0;
}

/* Where a row starts, or for the row count, where the rows end. */
static CGFloat tops_at(NSData* tops, size_t row) {
	const CGFloat* values = tops.bytes;
	size_t entries = tops.length / sizeof(CGFloat);
	if (entries == 0) return kTopPadding;
	return values[row < entries ? row : entries - 1];
}

/* The row at y: -1 above the first row, or the row count below the last. */
static NSInteger tops_index(NSData* tops, CGFloat y) {
	const CGFloat* values = tops.bytes;
	size_t entries = tops.length / sizeof(CGFloat);
	if (entries < 2 || y < values[0]) return -1;
	/* The first entry after y. */
	size_t low = 0;
	size_t high = entries;
	while (low < high) {
		size_t middle = low + (high - low) / 2;
		if (values[middle] <= y) {
			low = middle + 1;
		} else {
			high = middle;
		}
	}
	return (NSInteger)low - 1;
}

/* The rows from first up to last that overlap top to bottom. */
static void tops_range(NSData* tops, CGFloat top, CGFloat bottom, size_t* first, size_t* last) {
	size_t count = tops_count(tops);
	NSInteger firstIndex = tops_index(tops, top);
	NSInteger lastIndex = tops_index(tops, bottom);
	*first = firstIndex < 0 ? 0 : (size_t)firstIndex;
	*last = lastIndex < 0 ? 0 : min_index((size_t)lastIndex + 1, count);
}

/*
 * A place in the layout kept at the same place on the screen while it changes:
 * a fraction of the way down a row, screenY down from the top of the view.
 */
typedef struct {
	size_t row;
	CGFloat fraction;
	CGFloat screenY;
	BOOL valid;
} ScrollAnchor;

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
	/* The lines a hunk covers on a side. */
	- (void) hunk:(DtHunk)hunk side:(NSUInteger)side start:(uint32_t*)start end:(uint32_t*)end;
	- (BOOL) rowInCurrentHunk:(size_t)row;
	- (BOOL) lineInCurrentHunk:(size_t)line side:(NSUInteger)side;
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
	- (void) paneDidSelect:(DiffPaneView*)pane;
	/* The file shown on a side, or nil. */
	- (NSURL*) fileURLForSide:(NSUInteger)side;
@end

/* One side's text, in its own scroll view. */
@interface DiffPaneView : NSView
	@property (nonatomic, readonly) NSUInteger side;
	- (instancetype) initWithOwner:(DiffView*)owner side:(NSUInteger)side;
	- (void) diffDidChange;
	- (void) modeDidChange;
	- (void) relayout;
	- (void) clearSelection;
@end

/* One side's line numbers, which stay put when the side scrolls sideways. */
@interface DiffGutterView : NSView
	- (instancetype) initWithOwner:(DiffView*)owner side:(NSUInteger)side;
@end

/* The gap after a side, joining its hunks to the next side's. */
@interface DiffConnectorView : NSView
	- (instancetype) initWithOwner:(DiffView*)owner side:(NSUInteger)side;
@end

@implementation DiffView {
	NSArray<NSScrollView*>* _scrolls;
	NSArray<DiffPaneView*>* _panes;
	NSArray<DiffGutterView*>* _gutters;
	NSArray<DiffConnectorView*>* _connectors;
	size_t _maxLines;
	BOOL _syncingScroll;

	/* The layout: see tops_at. */
	NSMutableData* _rowTops;
	NSArray<NSMutableData*>* _lineTops;
	NSMutableData* _unifiedTops;
	/*
	 * For Fluid mode, per side, pairs of CGFloats: positions in the shared layout,
	 * the rows', and the same positions in the side's own. Between them, one maps
	 * linearly to the other.
	 */
	NSArray<NSMutableData*>* _anchors;
	/* The width lines are wrapped to, or 0 when they aren't. */
	CGFloat _wrapWidth;
	BOOL _layingOut;
}

+ (void) initialize {
	if (self == [DiffView class]) init_colors();
}

- (instancetype) initWithFrame:(NSRect)frame {
	if ((self = [super initWithFrame:frame])) {
		clip_to_bounds(self);
		_currentHunk = -1;
		NSMutableArray* scrolls = [NSMutableArray array];
		NSMutableArray* panes = [NSMutableArray array];
		NSMutableArray* gutters = [NSMutableArray array];
		NSMutableArray* connectors = [NSMutableArray array];
		for (NSUInteger side = 0; side < kSideCount; side++) {
			DiffPaneView* pane = [[DiffPaneView alloc] initWithOwner:self side:side];
			NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
			/* One vertical scroller, at the far right, for all the sides. */
			scroll.hasVerticalScroller = side + 1 == kSideCount;
			scroll.hasHorizontalScroller = YES;
			scroll.autohidesScrollers = YES;
			scroll.backgroundColor = [NSColor textBackgroundColor];
			scroll.documentView = pane;
			scroll.contentView.postsBoundsChangedNotifications = YES;
			[[NSNotificationCenter defaultCenter]
				addObserver:self
				selector:@selector(clipViewBoundsDidChange:)
				name:NSViewBoundsDidChangeNotification
				object:scroll.contentView];

			DiffGutterView* gutter = [[DiffGutterView alloc] initWithOwner:self side:side];
			[self addSubview:gutter];
			[self addSubview:scroll];
			[scrolls addObject:scroll];
			[panes addObject:pane];
			[gutters addObject:gutter];
			if (side + 1 < kSideCount) {
				DiffConnectorView* connector = [[DiffConnectorView alloc] initWithOwner:self side:side];
				[self addSubview:connector];
				[connectors addObject:connector];
			}
		}
		_scrolls = scrolls;
		_panes = panes;
		_gutters = gutters;
		_connectors = connectors;
		self.fontSize = 12;
	}
	return self;
}

- (void) dealloc {
	dt_file_diff_free(_diff);
}

- (BOOL) isFlipped { return YES; }

- (void) setFrameSize:(NSSize)size {
	[super setFrameSize:size];
	[self layoutSides];
}

- (void) layout {
	[super layout];
	[self layoutSides];
}

/* Each side gets an equal share of the width, after the connectors between them. */
- (void) layoutSides {
	NSRect bounds = self.bounds;
	if (_mode == kDiffModeUnified) {
		/* Side A's views show both sides; the others are hidden. */
		CGFloat gutter = fmin(2 * _unifiedColumnWidth, NSWidth(bounds));
		_gutters[0].frame = NSMakeRect(0, 0, gutter, NSHeight(bounds));
		_scrolls[0].frame = NSMakeRect(gutter, 0, NSWidth(bounds) - gutter, NSHeight(bounds));
		return;
	}
	CGFloat share = floor((NSWidth(bounds) - (CGFloat)(kSideCount - 1) * kMiddleWidth) / (CGFloat)kSideCount);
	CGFloat x = 0;
	for (NSUInteger side = 0; side < kSideCount; side++) {
		CGFloat width = side + 1 == kSideCount ? NSWidth(bounds) - x : share;
		CGFloat gutter = fmin(_gutterWidth, width);
		_gutters[side].frame = NSMakeRect(x, 0, gutter, NSHeight(bounds));
		_scrolls[side].frame = NSMakeRect(x + gutter, 0, width - gutter, NSHeight(bounds));
		x += width;
		if (side < _connectors.count) {
			_connectors[side].frame = NSMakeRect(x, 0, kMiddleWidth, NSHeight(bounds));
			x += kMiddleWidth;
		}
	}
}

- (void) redrawAll {
	for (NSView* view in _panes) [view setNeedsDisplay:YES];
	for (NSView* view in _gutters) [view setNeedsDisplay:YES];
	for (NSView* view in _connectors) [view setNeedsDisplay:YES];
}

- (void) setDiff:(DtFileDiff*)diff {
	if (diff == _diff) return;
	dt_file_diff_free(_diff);
	_diff = diff;
	_currentHunk = diff && dt_file_diff_hunk_count(diff) > 0 ? 0 : -1;
	_maxLines = 0;
	_maxColumns = 0;
	for (NSUInteger side = 0; diff && side < kSideCount; side++) {
		size_t count = dt_file_diff_line_count(diff, (uint8_t)side);
		if (count > _maxLines) _maxLines = count;
		for (size_t i = 0; i < count; i++) {
			uint32_t columns = dt_file_diff_line(diff, (uint8_t)side, i).columns;
			if (columns > _maxColumns) _maxColumns = columns;
		}
	}
	[self updateGutterWidth];
	[self layoutLines];
	for (DiffPaneView* pane in _panes) [pane diffDidChange];
	[self redrawAll];
}

- (void) setFontSize:(CGFloat)fontSize {
	_fontSize = fontSize;
	_font = [NSFont monospacedSystemFontOfSize:fontSize weight:NSFontWeightRegular];
	NSLayoutManager* layoutManager = [[NSLayoutManager alloc] init];
	_fontLineHeight = [layoutManager defaultLineHeightForFont:_font];
	_lineHeight = ceil(_fontLineHeight * 1.3);
	_textInset = floor((_lineHeight - _fontLineHeight) / 2);
	_charWidth = [@"0" sizeWithAttributes:@{NSFontAttributeName: _font}].width;

	NSArray* tabStops = @[];
	CFArrayRef tabStopsRef = (__bridge CFArrayRef)tabStops;
	CGFloat tabInterval = _charWidth * kTabWidth;
	CTParagraphStyleSetting settings[] = {
		{kCTParagraphStyleSpecifierTabStops, sizeof tabStopsRef, &tabStopsRef},
		{kCTParagraphStyleSpecifierDefaultTabInterval, sizeof tabInterval, &tabInterval},
	};
	id paragraph = CFBridgingRelease(CTParagraphStyleCreate(settings, sizeof settings / sizeof settings[0]));
	_textAttributes = @{
		(__bridge NSString*)kCTFontAttributeName: _font,
		(__bridge NSString*)kCTParagraphStyleAttributeName: paragraph,
		(__bridge NSString*)kCTForegroundColorFromContextAttributeName: @YES
	};
	NSFont* numberFont = [NSFont monospacedDigitSystemFontOfSize:fontSize weight:NSFontWeightRegular];
	_numberAttributes = @{
		NSFontAttributeName: numberFont,
		NSForegroundColorAttributeName: [NSColor secondaryLabelColor]
	};

	[self updateGutterWidth];
	[self relayoutLines];
}

- (void) updateGutterWidth {
	int digits = 3;
	for (size_t n = _maxLines; n >= 1000; n /= 10) digits++;
	CGFloat digitWidth = [@"0" sizeWithAttributes:_numberAttributes].width;
	_gutterWidth = ceil(digits * digitWidth + 2 * kGutterPadding);
	/* Room for the side's letter before the line number. */
	_unifiedColumnWidth = _gutterWidth + kUnifiedLetterWidth;
	[self layoutSides];
}

- (void) setWrapsLines:(BOOL)wrapsLines {
	if (wrapsLines == _wrapsLines) return;
	_wrapsLines = wrapsLines;
	[self relayoutLines];
}

- (void) setCurrentHunk:(NSInteger)currentHunk {
	_currentHunk = currentHunk;
	[self redrawAll];
}

#pragma mark Layout

/* The width to wrap lines to: that of the narrowest side showing, or 0 when not wrapping. */
- (CGFloat) currentWrapWidth {
	if (!_wrapsLines) return 0;
	NSUInteger sides = _mode == kDiffModeUnified ? 1 : kSideCount;
	CGFloat width = CGFLOAT_MAX;
	for (NSUInteger side = 0; side < sides; side++) width = fmin(width, _scrolls[side].contentSize.width);
	/* At least a few characters, while the views are still being sized. */
	return fmax(width - 2 * kTextPadding, 8 * _charWidth);
}

/* Lay out the lines again, keeping what's in view where it is. */
- (void) relayoutLines {
	ScrollAnchor anchor = [self scrollAnchor];
	[self layoutLines];
	for (DiffPaneView* pane in _panes) [pane relayout];
	[self restoreScrollAnchor:anchor];
	[self redrawAll];
}

/* Where the current mode's row starts in the shared layout. */
- (CGFloat) layoutY:(size_t)row {
	return _mode == kDiffModeUnified ? [self unifiedY:row] : [self rowY:row];
}

/*
 * What to keep in place on the screen while the layout changes: the current
 * hunk if it's in view, or else the point in the middle of the view.
 */
- (ScrollAnchor) scrollAnchor {
	ScrollAnchor anchor = {0, 0, 0, NO};
	if (!_diff) return anchor;
	BOOL unified = _mode == kDiffModeUnified;
	NSRect visible = _scrolls[0].contentView.bounds;

	if (_currentHunk >= 0 && (size_t)_currentHunk < dt_file_diff_hunk_count(_diff)) {
		DtHunk hunk = dt_file_diff_hunk(_diff, (size_t)_currentHunk);
		size_t start = unified ? hunk.unified_start : hunk.row_start;
		size_t end = unified ? hunk.unified_end : hunk.row_end;
		CGFloat top = [self layoutY:start];
		if ([self layoutY:end] > NSMinY(visible) && top < NSMaxY(visible)) {
			return (ScrollAnchor){start, 0, top - NSMinY(visible), YES};
		}
	}

	size_t count = unified ? dt_file_diff_unified_count(_diff) : dt_file_diff_row_count(_diff);
	if (count == 0) return anchor;
	CGFloat y = NSMidY(visible);
	NSInteger row = unified ? [self unifiedRowAtY:y] : [self rowAtY:y];
	size_t index = row < 0 ? 0 : min_index((size_t)row, count - 1);
	CGFloat top = [self layoutY:index];
	CGFloat height = [self layoutY:index + 1] - top;
	CGFloat fraction = height > 0 ? fmin(fmax((y - top) / height, 0), 1) : 0;
	return (ScrollAnchor){index, fraction, y - NSMinY(visible), YES};
}

- (void) restoreScrollAnchor:(ScrollAnchor)anchor {
	if (!anchor.valid) return;
	CGFloat top = [self layoutY:anchor.row];
	CGFloat height = [self layoutY:anchor.row + 1] - top;
	CGFloat y = top + anchor.fraction * height - anchor.screenY;
	DiffPaneView* pane = _panes[0];
	[pane scrollPoint:NSMakePoint(NSMinX(pane.visibleRect), fmax(0, y))];
}

- (void) paneDidResize:(DiffPaneView*)pane {
	if (_layingOut) return;
	_layingOut = YES;
	if (_wrapsLines && fabs([self currentWrapWidth] - _wrapWidth) >= 0.5) {
		[self relayoutLines];
	} else {
		[pane relayout];
	}
	_layingOut = NO;
}

- (void) enumerateLinesOfText:(NSString*)text block:(void (^)(CTLineRef line, CFRange range, NSUInteger index))block {
	NSAttributedString* string = [[NSAttributedString alloc] initWithString:text attributes:_textAttributes];
	CFAttributedStringRef cfString = (__bridge CFAttributedStringRef)string;
	CFIndex length = (CFIndex)text.length;
	if (_wrapWidth <= 0 || length == 0) {
		CTLineRef line = CTLineCreateWithAttributedString(cfString);
		block(line, CFRangeMake(0, length), 0);
		CFRelease(line);
		return;
	}

	CTTypesetterRef typesetter = CTTypesetterCreateWithAttributedString(cfString);
	CFIndex start = 0;
	NSUInteger index = 0;
	while (start < length) {
		CFIndex count = CTTypesetterSuggestLineBreak(typesetter, start, _wrapWidth);
		if (count <= 0) count = length - start;
		CFRange range = CFRangeMake(start, count);
		CTLineRef line = CTTypesetterCreateLine(typesetter, range);
		block(line, range, index++);
		CFRelease(line);
		start += count;
	}
	CFRelease(typesetter);
}

/* How tall a side's line is: a line height, or several when it wraps. */
- (CGFloat) heightOfLine:(size_t)index side:(NSUInteger)side {
	if (_wrapWidth <= 0) return _lineHeight;
	DtLine line = dt_file_diff_line(_diff, (uint8_t)side, index);
	/* Most lines fit; only measure those that might not. */
	if (((CGFloat)line.columns + 1) * _charWidth <= _wrapWidth) return _lineHeight;

	NSAttributedString* string = [[NSAttributedString alloc] initWithString:dt_string(line.text) attributes:_textAttributes];
	CTTypesetterRef typesetter = CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)string);
	CFIndex length = (CFIndex)string.length;
	CFIndex start = 0;
	NSUInteger count = 0;
	while (start < length) {
		CFIndex next = CTTypesetterSuggestLineBreak(typesetter, start, _wrapWidth);
		start += next > 0 ? next : length - start;
		count++;
	}
	CFRelease(typesetter);
	return (CGFloat)(count > 0 ? count : 1) * _lineHeight;
}

static NSMutableData* new_tops(size_t count) {
	NSMutableData* tops = [NSMutableData dataWithLength:(count + 1) * sizeof(CGFloat)];
	((CGFloat*)tops.mutableBytes)[0] = kTopPadding;
	return tops;
}

/* Lay out every line for the current mode's wrap width. */
- (void) layoutLines {
	_wrapWidth = [self currentWrapWidth];
	size_t rows = _diff ? dt_file_diff_row_count(_diff) : 0;
	size_t unifiedRows = _diff ? dt_file_diff_unified_count(_diff) : 0;

	NSMutableArray<NSMutableData*>* lineTops = [NSMutableArray array];
	for (NSUInteger side = 0; side < kSideCount; side++) {
		size_t count = _diff ? dt_file_diff_line_count(_diff, (uint8_t)side) : 0;
		NSMutableData* tops = new_tops(count);
		CGFloat* values = tops.mutableBytes;
		for (size_t i = 0; i < count; i++) values[i + 1] = values[i] + [self heightOfLine:i side:side];
		[lineTops addObject:tops];
	}
	_lineTops = lineTops;

	_rowTops = new_tops(rows);
	CGFloat* rowValues = _rowTops.mutableBytes;
	for (size_t row = 0; row < rows; row++) {
		CGFloat height = 0;
		for (NSUInteger side = 0; side < kSideCount; side++) {
			int32_t line = dt_file_diff_row_line(_diff, row, (uint8_t)side);
			if (line >= 0) height = fmax(height, [self lineY:(size_t)line + 1 side:side] - [self lineY:(size_t)line side:side]);
		}
		rowValues[row + 1] = rowValues[row] + height;
	}

	_unifiedTops = new_tops(unifiedRows);
	CGFloat* unifiedValues = _unifiedTops.mutableBytes;
	for (size_t row = 0; row < unifiedRows; row++) {
		NSUInteger side = 0;
		size_t line = 0;
		CGFloat height = _lineHeight;
		if ([self unifiedRow:row side:&side line:&line]) height = [self lineY:line + 1 side:side] - [self lineY:line side:side];
		unifiedValues[row + 1] = unifiedValues[row] + height;
	}

	/* Anchors at the start of each row between hunks, and of each hunk, then at the end. */
	NSMutableArray<NSMutableData*>* anchors = [NSMutableArray array];
	size_t hunkCount = _diff ? dt_file_diff_hunk_count(_diff) : 0;
	for (NSUInteger side = 0; side < kSideCount; side++) {
		NSMutableData* pairs = [NSMutableData data];
		size_t hunkIndex = 0;
		for (size_t row = 0; row < rows;) {
			CGFloat pair[2] = {[self rowY:row], 0};
			if (hunkIndex < hunkCount && dt_file_diff_hunk(_diff, hunkIndex).row_start == row) {
				DtHunk hunk = dt_file_diff_hunk(_diff, hunkIndex++);
				uint32_t start, end;
				[self hunk:hunk side:side start:&start end:&end];
				pair[1] = [self lineY:start side:side];
				row = hunk.row_end;
			} else {
				int32_t line = dt_file_diff_row_line(_diff, row, (uint8_t)side);
				pair[1] = [self lineY:line < 0 ? 0 : (size_t)line side:side];
				row++;
			}
			[pairs appendBytes:pair length:sizeof pair];
		}
		size_t lines = _diff ? dt_file_diff_line_count(_diff, (uint8_t)side) : 0;
		CGFloat end[2] = {[self rowY:rows], [self lineY:lines side:side]};
		[pairs appendBytes:end length:sizeof end];
		[anchors addObject:pairs];
	}
	_anchors = anchors;
}

- (CGFloat) rowY:(size_t)row {
	return tops_at(_rowTops, row);
}

- (CGFloat) lineY:(size_t)line side:(NSUInteger)side {
	return tops_at(_lineTops[side], line);
}

- (CGFloat) unifiedY:(size_t)row {
	return tops_at(_unifiedTops, row);
}

- (NSInteger) rowAtY:(CGFloat)y {
	return tops_index(_rowTops, y);
}

- (NSInteger) lineAtY:(CGFloat)y side:(NSUInteger)side {
	return tops_index(_lineTops[side], y);
}

- (NSInteger) unifiedRowAtY:(CGFloat)y {
	return tops_index(_unifiedTops, y);
}

- (void) rowsFrom:(CGFloat)top to:(CGFloat)bottom first:(size_t*)first last:(size_t*)last {
	tops_range(_rowTops, top, bottom, first, last);
}

- (void) linesFrom:(CGFloat)top to:(CGFloat)bottom side:(NSUInteger)side first:(size_t*)first last:(size_t*)last {
	tops_range(_lineTops[side], top, bottom, first, last);
}

- (void) unifiedRowsFrom:(CGFloat)top to:(CGFloat)bottom first:(size_t*)first last:(size_t*)last {
	tops_range(_unifiedTops, top, bottom, first, last);
}

- (CGFloat) contentBottom {
	NSData* tops = _mode == kDiffModeUnified ? _unifiedTops : _rowTops;
	return tops_at(tops, tops_count(tops)) + kTopPadding;
}

- (CGFloat) verticalOffset:(NSUInteger)side {
	return _scrolls[side].contentView.bounds.origin.y;
}

- (void) hunk:(DtHunk)hunk side:(NSUInteger)side start:(uint32_t*)start end:(uint32_t*)end {
	*start = side == 0 ? hunk.a_start : hunk.b_start;
	*end = side == 0 ? hunk.a_end : hunk.b_end;
}

/*
 * Map a position in the shared layout, the Blocks layout's rows, to a side's own
 * layout: one to one between hunks, and stretched or squeezed across each one.
 */
- (CGFloat) sidePosition:(CGFloat)position side:(NSUInteger)side {
	NSData* anchors = _anchors[side];
	const CGFloat* values = anchors.bytes;
	size_t count = anchors.length / (2 * sizeof(CGFloat));
	if (count == 0) return position;

	/* The last anchor at or before the position. */
	size_t low = 0;
	size_t high = count;
	while (low < high) {
		size_t middle = low + (high - low) / 2;
		if (values[2 * middle] <= position) {
			low = middle + 1;
		} else {
			high = middle;
		}
	}
	if (low == 0) return position - values[0] + values[1];

	size_t i = low - 1;
	CGFloat t0 = values[2 * i];
	CGFloat v0 = values[2 * i + 1];
	if (i + 1 >= count) return v0 + (position - t0);
	CGFloat t1 = values[2 * i + 2];
	CGFloat v1 = values[2 * i + 3];
	if (t1 <= t0) return v1;
	return v0 + (position - t0) * (v1 - v0) / (t1 - t0);
}

- (CGFloat) shift:(NSUInteger)side {
	if (_mode != kDiffModeFluid || !_diff) return 0;
	NSRect visible = _scrolls[side].contentView.bounds;
	/*
	 * Line the sides up at a point that moves from the top of the view to the
	 * bottom as it scrolls down, so that they start and end together.
	 */
	CGFloat range = NSHeight(_panes[side].frame) - NSHeight(visible);
	CGFloat fraction = range > 0 ? fmin(fmax(NSMinY(visible) / range, 0), 1) : 0;
	CGFloat anchor = NSMinY(visible) + fraction * NSHeight(visible);
	return [self sidePosition:anchor side:side] - anchor;
}

- (BOOL) rowInCurrentHunk:(size_t)row {
	if (!_diff || _currentHunk < 0 || (size_t)_currentHunk >= dt_file_diff_hunk_count(_diff)) return NO;
	DtHunk hunk = dt_file_diff_hunk(_diff, (size_t)_currentHunk);
	return row >= hunk.row_start && row < hunk.row_end;
}

- (BOOL) lineInCurrentHunk:(size_t)line side:(NSUInteger)side {
	if (!_diff || _currentHunk < 0 || (size_t)_currentHunk >= dt_file_diff_hunk_count(_diff)) return NO;
	uint32_t start, end;
	[self hunk:dt_file_diff_hunk(_diff, (size_t)_currentHunk) side:side start:&start end:&end];
	return line >= start && line < end;
}

- (void) drawHunksInRect:(NSRect)dirty offset:(CGFloat)offset bands:(BOOL)bands {
	if (!_diff) return;
	size_t count = dt_file_diff_hunk_count(_diff);
	for (size_t i = 0; i < count; i++) {
		DtHunk hunk = dt_file_diff_hunk(_diff, i);
		CGFloat top = [self rowY:hunk.row_start] - offset;
		CGFloat bottom = [self rowY:hunk.row_end] - offset;
		if (bottom < NSMinY(dirty) - 1 || top > NSMaxY(dirty) + 1) continue;
		uint8_t kind = hunk_kind(hunk);
		if (bands) {
			[line_color(kind, (NSInteger)i == _currentHunk) setFill];
			NSRectFill(NSMakeRect(NSMinX(dirty), top, NSWidth(dirty), bottom - top));
		}
		[g_edge_colors[kind] setFill];
		/* Where the hunk before ends, its bottom edge is this one's top. */
		if (i == 0 || dt_file_diff_hunk(_diff, i - 1).row_end != hunk.row_start) {
			NSRectFill(NSMakeRect(NSMinX(dirty), top, NSWidth(dirty), 1));
		}
		NSRectFill(NSMakeRect(NSMinX(dirty), bottom - 1, NSWidth(dirty), 1));
	}
}

- (void) drawSideHunks:(NSUInteger)side inRect:(NSRect)dirty offset:(CGFloat)offset {
	if (!_diff) return;
	size_t count = dt_file_diff_hunk_count(_diff);
	for (size_t i = 0; i < count; i++) {
		DtHunk hunk = dt_file_diff_hunk(_diff, i);
		uint32_t start, end;
		[self hunk:hunk side:side start:&start end:&end];
		CGFloat top = [self lineY:start side:side] - offset;
		CGFloat bottom = [self lineY:end side:side] - offset;
		if (bottom < NSMinY(dirty) - 1 || top > NSMaxY(dirty) + 1) continue;
		/*
		 * A hunk with no lines on this side is a single line where they'd be.
		 * Where the hunk before ends, its bottom edge is this one's top.
		 */
		uint32_t previousStart = 0, previousEnd = UINT32_MAX;
		if (i > 0) [self hunk:dt_file_diff_hunk(_diff, i - 1) side:side start:&previousStart end:&previousEnd];
		[g_edge_colors[hunk_kind(hunk)] setFill];
		if (previousEnd != start) NSRectFill(NSMakeRect(NSMinX(dirty), top, NSWidth(dirty), 1));
		if (bottom - top >= 2) NSRectFill(NSMakeRect(NSMinX(dirty), bottom - 1, NSWidth(dirty), 1));
	}
}

/* Scroll every side up and down with whichever one scrolled. */
- (void) clipViewBoundsDidChange:(NSNotification*)notification {
	NSClipView* source = notification.object;
	if (!_syncingScroll) {
		_syncingScroll = YES;
		CGFloat y = source.bounds.origin.y;
		for (NSScrollView* scroll in _scrolls) {
			NSClipView* clip = scroll.contentView;
			if (clip == source || fabs(clip.bounds.origin.y - y) < 0.5) continue;
			[clip setBoundsOrigin:NSMakePoint(clip.bounds.origin.x, y)];
			[scroll reflectScrolledClipView:clip];
		}
		_syncingScroll = NO;
	}
	/* In Fluid mode, the sides' layouts shift as they scroll. */
	if (_mode == kDiffModeFluid) {
		for (NSView* view in _panes) [view setNeedsDisplay:YES];
	}
	for (NSView* view in _gutters) [view setNeedsDisplay:YES];
	for (NSView* view in _connectors) [view setNeedsDisplay:YES];
}

- (void) setMode:(NSInteger)mode {
	if (mode == _mode) return;
	_mode = mode;
	BOOL unified = mode == kDiffModeUnified;
	for (NSUInteger side = 1; side < kSideCount; side++) {
		_gutters[side].hidden = unified;
		_scrolls[side].hidden = unified;
	}
	for (NSView* view in _connectors) view.hidden = unified;
	_scrolls[0].hasVerticalScroller = unified || kSideCount == 1;
	[self layoutSides];
	/* Unified mode is wider, so lines wrap differently. */
	[self layoutLines];
	for (DiffPaneView* pane in _panes) [pane modeDidChange];
	[self redrawAll];
	[self scrollToCurrentHunk];
}

- (BOOL) unifiedRow:(size_t)row side:(NSUInteger*)side line:(size_t*)line {
	for (NSUInteger s = 0; _diff && s < kSideCount; s++) {
		int32_t index = dt_file_diff_unified_line(_diff, row, (uint8_t)s);
		if (index >= 0) {
			*side = s;
			*line = (size_t)index;
			return YES;
		}
	}
	return NO;
}

- (BOOL) unifiedRowInCurrentHunk:(size_t)row {
	if (!_diff || _currentHunk < 0 || (size_t)_currentHunk >= dt_file_diff_hunk_count(_diff)) return NO;
	DtHunk hunk = dt_file_diff_hunk(_diff, (size_t)_currentHunk);
	return row >= hunk.unified_start && row < hunk.unified_end;
}

/* Which run of changed lines a row is in: a number for its side and kind, or -1 if it's unchanged. */
- (NSInteger) unifiedGroupOfRow:(size_t)row {
	if (!_diff || row >= dt_file_diff_unified_count(_diff)) return -1;
	if (dt_file_diff_unified_line(_diff, row, DT_SIDE_A) >= 0 && dt_file_diff_unified_line(_diff, row, DT_SIDE_B) >= 0) {
		return -1;
	}
	NSUInteger side;
	size_t line;
	if (![self unifiedRow:row side:&side line:&line]) return -1;
	return (NSInteger)(side * 4 + dt_file_diff_line(_diff, (uint8_t)side, line).kind);
}

- (BOOL) unifiedGroupStartsAtRow:(size_t)row {
	NSInteger group = [self unifiedGroupOfRow:row];
	return group >= 0 && (row == 0 || [self unifiedGroupOfRow:row - 1] != group);
}

- (void) drawUnifiedGroupsFrom:(size_t)first to:(size_t)last inRect:(NSRect)dirty offset:(CGFloat)offset {
	for (size_t row = first; row < last; row++) {
		NSInteger group = [self unifiedGroupOfRow:row];
		if (group < 0) continue;
		[g_edge_colors[group % 4] setFill];
		if ([self unifiedGroupStartsAtRow:row]) {
			NSRectFill(NSMakeRect(NSMinX(dirty), [self unifiedY:row] - offset, NSWidth(dirty), 1));
		}
		if ([self unifiedGroupOfRow:row + 1] != group) {
			NSRectFill(NSMakeRect(NSMinX(dirty), [self unifiedY:row + 1] - offset - 1, NSWidth(dirty), 1));
		}
	}
}

- (void) selectHunkAtUnifiedRow:(size_t)row {
	size_t count = _diff ? dt_file_diff_hunk_count(_diff) : 0;
	for (size_t i = 0; i < count; i++) {
		DtHunk hunk = dt_file_diff_hunk(_diff, i);
		if (row >= hunk.unified_start && row < hunk.unified_end) {
			self.currentHunk = (NSInteger)i;
			if (_currentHunkChanged) _currentHunkChanged();
			return;
		}
	}
}

- (void) selectHunkAtRow:(size_t)row {
	size_t count = _diff ? dt_file_diff_hunk_count(_diff) : 0;
	for (size_t i = 0; i < count; i++) {
		DtHunk hunk = dt_file_diff_hunk(_diff, i);
		if (row >= hunk.row_start && row < hunk.row_end) {
			self.currentHunk = (NSInteger)i;
			if (_currentHunkChanged) _currentHunkChanged();
			return;
		}
	}
}

- (void) selectHunkAtLine:(size_t)line side:(NSUInteger)side {
	size_t count = _diff ? dt_file_diff_hunk_count(_diff) : 0;
	for (size_t i = 0; i < count; i++) {
		uint32_t start, end;
		[self hunk:dt_file_diff_hunk(_diff, i) side:side start:&start end:&end];
		if (line >= start && line < end) {
			self.currentHunk = (NSInteger)i;
			if (_currentHunkChanged) _currentHunkChanged();
			return;
		}
	}
}

- (NSURL*) fileURLForSide:(NSUInteger)side {
	id url = side < _fileURLs.count ? _fileURLs[side] : nil;
	return [url isKindOfClass:[NSURL class]] ? url : nil;
}

/* Only one side has a selection at a time. */
- (void) paneDidSelect:(DiffPaneView*)selected {
	for (DiffPaneView* pane in _panes) {
		if (pane != selected) [pane clearSelection];
	}
}

/* Scroll the current hunk to a third of the way down, unless it's already in view. */
- (void) scrollToCurrentHunk {
	if (!_diff || _currentHunk < 0 || (size_t)_currentHunk >= dt_file_diff_hunk_count(_diff)) return;
	DtHunk hunk = dt_file_diff_hunk(_diff, (size_t)_currentHunk);
	BOOL unified = _mode == kDiffModeUnified;
	CGFloat top = unified ? [self unifiedY:hunk.unified_start] : [self rowY:hunk.row_start];
	CGFloat bottom = unified ? [self unifiedY:hunk.unified_end] : [self rowY:hunk.row_end];
	DiffPaneView* pane = _panes[0];
	NSRect visible = pane.visibleRect;
	if (top >= NSMinY(visible) && bottom <= NSMaxY(visible)) return;
	CGFloat y = fmax(0, top - floor(NSHeight(visible) / 3));
	[pane scrollPoint:NSMakePoint(NSMinX(visible), y)];
}

@end

@implementation DiffGutterView {
	__weak DiffView* _owner;
	NSUInteger _side;
}

- (instancetype) initWithOwner:(DiffView*)owner side:(NSUInteger)side {
	if ((self = [super initWithFrame:NSZeroRect])) {
		clip_to_bounds(self);
		_owner = owner;
		_side = side;
	}
	return self;
}

- (BOOL) isFlipped { return YES; }
- (BOOL) isOpaque { return YES; }

- (void) drawRect:(NSRect)dirtyRect {
	NSRect dirty = NSIntersectionRect(dirtyRect, self.bounds);
	[[NSColor textBackgroundColor] setFill];
	NSRectFill(dirty);
	DiffView* owner = _owner;
	DtFileDiff* diff = owner.diff;
	if (!diff) return;

	CGFloat width = NSWidth(self.bounds);
	size_t first, last;
	if (owner.mode == kDiffModeUnified) {
		/* A column of line numbers for each side, each run of changed lines marked with its side's letter. */
		CGFloat offset = [owner verticalOffset:_side];
		CGFloat column = owner.unifiedColumnWidth;
		[owner unifiedRowsFrom:NSMinY(dirty) + offset to:NSMaxY(dirty) + offset first:&first last:&last];
		for (size_t row = first; row < last; row++) {
			BOOL current = [owner unifiedRowInCurrentHunk:row];
			BOOL groupStart = [owner unifiedGroupStartsAtRow:row];
			CGFloat top = [owner unifiedY:row] - offset;
			CGFloat height = [owner unifiedY:row + 1] - offset - top;
			for (NSUInteger side = 0; side < kSideCount; side++) {
				int32_t line = dt_file_diff_unified_line(diff, row, (uint8_t)side);
				if (line < 0) continue;
				NSRect frame = NSMakeRect((CGFloat)side * column, top, column, height);
				[self drawLine:line side:side frame:frame current:current];
				if (groupStart) {
					NSString* letter = side == 0 ? @"A" : @"B";
					NSPoint point = NSMakePoint(NSMinX(frame) + 4, NSMinY(frame) + owner.textInset);
					[letter drawAtPoint:point withAttributes:owner.numberAttributes];
				}
			}
		}
		[owner drawUnifiedGroupsFrom:first to:last inRect:dirty offset:offset];
		return;
	}

	if (owner.mode == kDiffModeFluid) {
		CGFloat offset = [owner verticalOffset:_side] + [owner shift:_side];
		[owner linesFrom:NSMinY(dirty) + offset to:NSMaxY(dirty) + offset side:_side first:&first last:&last];
		for (size_t line = first; line < last; line++) {
			CGFloat top = [owner lineY:line side:_side] - offset;
			NSRect frame = NSMakeRect(0, top, width, [owner lineY:line + 1 side:_side] - offset - top);
			[self drawLine:(int32_t)line side:_side frame:frame current:[owner lineInCurrentHunk:line side:_side]];
		}
		[owner drawSideHunks:_side inRect:dirty offset:offset];
		return;
	}

	CGFloat offset = [owner verticalOffset:_side];
	[owner rowsFrom:NSMinY(dirty) + offset to:NSMaxY(dirty) + offset first:&first last:&last];
	for (size_t row = first; row < last; row++) {
		CGFloat top = [owner rowY:row] - offset;
		NSRect frame = NSMakeRect(0, top, width, [owner rowY:row + 1] - offset - top);
		int32_t line = dt_file_diff_row_line(diff, row, (uint8_t)_side);
		[self drawLine:line side:_side frame:frame current:[owner rowInCurrentHunk:row]];
	}
	[owner drawHunksInRect:dirty offset:offset bands:NO];
}

/* A line's number, at the top of its frame, or filler for none, on the line's background. */
- (void) drawLine:(int32_t)lineIndex side:(NSUInteger)side frame:(NSRect)frame current:(BOOL)inCurrentHunk {
	if (lineIndex < 0) {
		[g_filler_color setFill];
		NSRectFill(frame);
		return;
	}

	DiffView* owner = _owner;
	DtLine line = dt_file_diff_line(owner.diff, (uint8_t)side, (size_t)lineIndex);
	if (line.kind != DT_LINE_EQUAL && line.kind < 4) {
		[line_color(line.kind, inCurrentHunk) setFill];
		NSRectFill(frame);
	}
	NSDictionary* attributes = owner.numberAttributes;
	NSString* number = [NSString stringWithFormat:@"%ld", (long)lineIndex + 1];
	NSSize size = [number sizeWithAttributes:attributes];
	NSPoint point = NSMakePoint(NSMaxX(frame) - kGutterPadding - size.width, NSMinY(frame) + owner.textInset);
	[number drawAtPoint:point withAttributes:attributes];
}

@end

@implementation DiffConnectorView {
	__weak DiffView* _owner;
	NSUInteger _side;
}

- (instancetype) initWithOwner:(DiffView*)owner side:(NSUInteger)side {
	if ((self = [super initWithFrame:NSZeroRect])) {
		clip_to_bounds(self);
		_owner = owner;
		_side = side;
	}
	return self;
}

- (BOOL) isFlipped { return YES; }
- (BOOL) isOpaque { return YES; }

- (void) drawRect:(NSRect)dirtyRect {
	NSRect dirty = NSIntersectionRect(dirtyRect, self.bounds);
	[g_middle_color setFill];
	NSRectFill(dirty);
	DiffView* owner = _owner;
	if (owner.mode != kDiffModeFluid) {
		[owner drawHunksInRect:dirty offset:[owner verticalOffset:_side] bands:YES];
		return;
	}

	/* Join each hunk on the side before to the same hunk on the side after. */
	DtFileDiff* diff = owner.diff;
	size_t count = diff ? dt_file_diff_hunk_count(diff) : 0;
	NSUInteger next = _side + 1;
	CGFloat offset = [owner verticalOffset:_side] + [owner shift:_side];
	CGFloat nextOffset = [owner verticalOffset:next] + [owner shift:next];
	CGFloat width = NSWidth(self.bounds);
	for (size_t i = 0; i < count; i++) {
		DtHunk hunk = dt_file_diff_hunk(diff, i);
		uint32_t start, end, nextStart, nextEnd;
		[owner hunk:hunk side:_side start:&start end:&end];
		[owner hunk:hunk side:next start:&nextStart end:&nextEnd];
		CGFloat top = [owner lineY:start side:_side] - offset;
		CGFloat bottom = [owner lineY:end side:_side] - offset;
		CGFloat nextTop = [owner lineY:nextStart side:next] - nextOffset;
		CGFloat nextBottom = [owner lineY:nextEnd side:next] - nextOffset;
		if (fmax(bottom, nextBottom) < NSMinY(dirty) - 1 || fmin(top, nextTop) > NSMaxY(dirty) + 1) continue;

		uint8_t kind = hunk_kind(hunk);
		NSBezierPath* band = [NSBezierPath bezierPath];
		[band moveToPoint:NSMakePoint(0, top)];
		[band lineToPoint:NSMakePoint(width, nextTop)];
		[band lineToPoint:NSMakePoint(width, nextBottom)];
		[band lineToPoint:NSMakePoint(0, bottom)];
		[band closePath];
		[line_color(kind, (NSInteger)i == owner.currentHunk) setFill];
		[band fill];

		/* Edges along the hunks' outlines: the top's first pixel row, the bottom's last. */
		NSBezierPath* edges = [NSBezierPath bezierPath];
		edges.lineWidth = 1;
		[edges moveToPoint:NSMakePoint(0, top + 0.5)];
		[edges lineToPoint:NSMakePoint(width, nextTop + 0.5)];
		[edges moveToPoint:NSMakePoint(0, fmax(top, bottom - 1) + 0.5)];
		[edges lineToPoint:NSMakePoint(width, fmax(nextTop, nextBottom - 1) + 0.5)];
		[g_edge_colors[kind] setStroke];
		[edges stroke];
	}
}

@end

@implementation DiffPaneView {
	__weak DiffView* _owner;
	uint32_t _maxColumns;
	/* The selection, from _anchor where it started to _head, or none when _anchor.line < 0. */
	TextPosition _anchor;
	TextPosition _head;
	/* The file the context menu is for, or nil. */
	NSURL* _menuFile;
}

- (instancetype) initWithOwner:(DiffView*)owner side:(NSUInteger)side {
	if ((self = [super initWithFrame:NSZeroRect])) {
		clip_to_bounds(self);
		_owner = owner;
		_side = side;
		_anchor = kNoPosition;
		_head = kNoPosition;
	}
	return self;
}

- (BOOL) isFlipped { return YES; }
- (BOOL) isOpaque { return YES; }
- (BOOL) acceptsFirstResponder { return YES; }

/* In Fluid mode, what's drawn depends on where the pane is scrolled to, so it can't be drawn ahead. */
+ (BOOL) isCompatibleWithResponsiveScrolling {
	return NO;
}

- (BOOL) becomeFirstResponder {
	[self setNeedsDisplay:YES];
	return YES;
}

- (BOOL) resignFirstResponder {
	[self setNeedsDisplay:YES];
	return YES;
}

- (void) viewDidMoveToSuperview {
	[super viewDidMoveToSuperview];
	NSClipView* clip = self.enclosingScrollView.contentView;
	if (!clip) return;
	clip.postsFrameChangedNotifications = YES;
	[[NSNotificationCenter defaultCenter]
		addObserver:self
		selector:@selector(clipViewFrameDidChange:)
		name:NSViewFrameDidChangeNotification
		object:clip];
}

- (void) viewDidMoveToWindow {
	[super viewDidMoveToWindow];
	if (!self.window) return;
	/* The selection is drawn dimmed while the window isn't key. */
	NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
	[center addObserver:self selector:@selector(windowKeyDidChange:) name:NSWindowDidBecomeKeyNotification object:self.window];
	[center addObserver:self selector:@selector(windowKeyDidChange:) name:NSWindowDidResignKeyNotification object:self.window];
}

- (void) clipViewFrameDidChange:(NSNotification*)notification {
	[_owner paneDidResize:self];
}

- (void) windowKeyDidChange:(NSNotification*)notification {
	if ([self hasSelection]) [self setNeedsDisplay:YES];
}

- (void) diffDidChange {
	DtFileDiff* diff = _owner.diff;
	_anchor = kNoPosition;
	_head = kNoPosition;
	_maxColumns = 0;
	size_t count = diff ? dt_file_diff_line_count(diff, (uint8_t)_side) : 0;
	for (size_t i = 0; i < count; i++) {
		uint32_t columns = dt_file_diff_line(diff, (uint8_t)_side, i).columns;
		if (columns > _maxColumns) _maxColumns = columns;
	}
	[self relayout];
	[self scrollPoint:NSZeroPoint];
	[self setNeedsDisplay:YES];
}

/* Selections are of a mode's lines, which another mode lays out differently. */
- (void) modeDidChange {
	[self clearSelection];
	[self relayout];
}

/* Size the view to fit its rows and, unless they wrap, its widest line, and at least fill the scroll view. */
- (void) relayout {
	DiffView* owner = _owner;
	NSSize visible = self.enclosingScrollView ? self.enclosingScrollView.contentSize : self.frame.size;
	uint32_t columns = owner.mode == kDiffModeUnified ? owner.maxColumns : _maxColumns;
	CGFloat width = visible.width;
	if (!owner.wrapsLines) width = fmax(width, 2 * kTextPadding + (CGFloat)columns * owner.charWidth);
	CGFloat height = fmax(visible.height, owner.contentBottom);
	[self setFrameSize:NSMakeSize(ceil(width), ceil(height))];
	[self.window invalidateCursorRectsForView:self];
	[self setNeedsDisplay:YES];
}

- (void) resetCursorRects {
	[self addCursorRect:self.bounds cursor:[NSCursor IBeamCursor]];
}

#pragma mark Text

/* The lines the pane shows and selects: its side's, or in Unified mode, the unified rows. */
- (size_t) lineCount {
	DtFileDiff* diff = _owner.diff;
	if (!diff) return 0;
	if (_owner.mode == kDiffModeUnified) return dt_file_diff_unified_count(diff);
	return dt_file_diff_line_count(diff, (uint8_t)_side);
}

- (NSString*) textOfLine:(NSInteger)line {
	DiffView* owner = _owner;
	DtFileDiff* diff = owner.diff;
	if (!diff || line < 0) return @"";
	NSUInteger side = _side;
	size_t index = (size_t)line;
	if (owner.mode == kDiffModeUnified && ![owner unifiedRow:(size_t)line side:&side line:&index]) return @"";
	return dt_string(dt_file_diff_line(diff, (uint8_t)side, index).text);
}

#pragma mark Drawing

- (void) drawRect:(NSRect)dirtyRect {
	NSRect dirty = NSIntersectionRect(dirtyRect, self.bounds);
	[[NSColor textBackgroundColor] setFill];
	NSRectFill(dirty);
	DiffView* owner = _owner;
	if (!owner.diff) return;

	size_t first, last;
	CGFloat width = NSWidth(self.bounds);
	if (owner.mode == kDiffModeUnified) {
		[owner unifiedRowsFrom:NSMinY(dirty) to:NSMaxY(dirty) first:&first last:&last];
		for (size_t row = first; row < last; row++) {
			NSUInteger side;
			size_t line;
			if (![owner unifiedRow:row side:&side line:&line]) continue;
			CGFloat top = [owner unifiedY:row];
			NSRect frame = NSMakeRect(0, top, width, [owner unifiedY:row + 1] - top);
			BOOL current = [owner unifiedRowInCurrentHunk:row];
			[self drawLine:(int32_t)line side:side selectionLine:(NSInteger)row frame:frame current:current];
		}
		[owner drawUnifiedGroupsFrom:first to:last inRect:dirty offset:0];
		return;
	}

	if (owner.mode == kDiffModeFluid) {
		CGFloat shift = [owner shift:_side];
		[owner linesFrom:NSMinY(dirty) + shift to:NSMaxY(dirty) + shift side:_side first:&first last:&last];
		for (size_t line = first; line < last; line++) {
			CGFloat top = [owner lineY:line side:_side] - shift;
			NSRect frame = NSMakeRect(0, top, width, [owner lineY:line + 1 side:_side] - shift - top);
			BOOL current = [owner lineInCurrentHunk:line side:_side];
			[self drawLine:(int32_t)line side:_side selectionLine:(NSInteger)line frame:frame current:current];
		}
		[owner drawSideHunks:_side inRect:dirty offset:shift];
		return;
	}

	[owner rowsFrom:NSMinY(dirty) to:NSMaxY(dirty) first:&first last:&last];
	for (size_t row = first; row < last; row++) {
		CGFloat top = [owner rowY:row];
		NSRect frame = NSMakeRect(0, top, width, [owner rowY:row + 1] - top);
		int32_t line = dt_file_diff_row_line(owner.diff, row, (uint8_t)_side);
		[self drawLine:line side:_side selectionLine:line frame:frame current:[owner rowInCurrentHunk:row]];
	}
	[owner drawHunksInRect:dirty offset:0 bands:NO];
}

/*
 * A side's line, from the top of frame, or filler for none. A wrapped line
 * takes several lines. selectionLine is where the selection has it.
 */
- (void) drawLine:(int32_t)lineIndex side:(NSUInteger)side selectionLine:(NSInteger)selectionLine frame:(NSRect)frame current:(BOOL)inCurrentHunk {
	if (lineIndex < 0) {
		[g_filler_color setFill];
		NSRectFill(frame);
		return;
	}

	DiffView* owner = _owner;
	DtLine line = dt_file_diff_line(owner.diff, (uint8_t)side, (size_t)lineIndex);
	BOOL changed = line.kind != DT_LINE_EQUAL && line.kind < 4;
	if (changed) {
		[line_color(line.kind, inCurrentHunk) setFill];
		NSRectFill(frame);
	}

	NSString* text = dt_string(line.text);
	NSUInteger length = text.length;
	CGFloat textX = kTextPadding;
	CGFloat lineHeight = owner.lineHeight;
	NSUInteger from = 0, to = 0;
	BOOL throughEnd = NO;
	BOOL selected = [self selectionInLine:selectionLine from:&from to:&to throughEnd:&throughEnd];
	BOOL active = self.window.isKeyWindow && self.window.firstResponder == self;
	NSColor* selectionColor = active ? [NSColor selectedTextBackgroundColor] : [NSColor unemphasizedSelectedTextBackgroundColor];
	CGContextRef context = [NSGraphicsContext currentContext].CGContext;

	[NSGraphicsContext saveGraphicsState];
	NSRectClip(frame);
	[owner enumerateLinesOfText:text block:^(CTLineRef ctLine, CFRange range, NSUInteger index) {
		NSUInteger start = (NSUInteger)range.location;
		NSUInteger end = start + (NSUInteger)range.length;
		BOOL last = end >= length;
		CGFloat y = NSMinY(frame) + (CGFloat)index * lineHeight;

		for (uint32_t i = 0; changed && i < line.span_count; i++) {
			DtSpan span = line.spans[i];
			NSUInteger spanStart = span.start16 > start ? span.start16 : start;
			NSUInteger spanEnd = min_index(span.end16, end);
			if (spanStart >= spanEnd || span.end16 > length) continue;
			CGFloat x0 = textX + CTLineGetOffsetForStringIndex(ctLine, (CFIndex)spanStart, NULL);
			CGFloat x1 = textX + CTLineGetOffsetForStringIndex(ctLine, (CFIndex)spanEnd, NULL);
			[g_emphasis_colors[line.kind] setFill];
			NSRectFill(NSMakeRect(x0, y + owner.textInset, x1 - x0, owner.fontLineHeight));
		}

		/*
		 * The selection on this line of the text: through to the edge where it
		 * goes on past it, onto the next line or past the line break.
		 */
		if (selected && (last ? from <= end : from < end && to > start)) {
			NSUInteger selectionStart = from > start ? from : start;
			BOOL toEdge = last ? throughEnd : to > end;
			CGFloat x0 = textX + CTLineGetOffsetForStringIndex(ctLine, (CFIndex)selectionStart, NULL);
			CGFloat x1 = toEdge ? NSMaxX(frame) : textX + CTLineGetOffsetForStringIndex(ctLine, (CFIndex)min_index(to, end), NULL);
			if (x1 > x0) {
				[selectionColor setFill];
				NSRectFill(NSMakeRect(x0, y, x1 - x0, lineHeight));
			}
		}

		[[NSColor textColor] setFill];
		/* Core Text draws upside down in a flipped view unless its text matrix flips it back. */
		CGContextSetTextMatrix(context, CGAffineTransformMakeScale(1, -1));
		CGContextSetTextPosition(context, textX, y + owner.textInset + owner.font.ascender);
		CTLineDraw(ctLine, context);
	}];
	[NSGraphicsContext restoreGraphicsState];
}

#pragma mark Selection

- (BOOL) hasSelection {
	return _anchor.line >= 0 && !position_equal(_anchor, _head);
}

- (void) clearSelection {
	if (_anchor.line < 0) return;
	_anchor = kNoPosition;
	_head = kNoPosition;
	[self setNeedsDisplay:YES];
}

/* The selection's start and end, in order. */
- (void) selectionStart:(TextPosition*)start end:(TextPosition*)end {
	BOOL forward = position_before(_anchor, _head);
	*start = forward ? _anchor : _head;
	*end = forward ? _head : _anchor;
}

/* The selected part of a line, and whether the selection continues past its end. */
- (BOOL) selectionInLine:(NSInteger)line from:(NSUInteger*)from to:(NSUInteger*)to throughEnd:(BOOL*)throughEnd {
	if (![self hasSelection]) return NO;
	TextPosition start, end;
	[self selectionStart:&start end:&end];
	if (line < start.line || line > end.line) return NO;
	*from = line == start.line ? start.index : 0;
	*to = line == end.line ? end.index : NSUIntegerMax;
	*throughEnd = line < end.line;
	return YES;
}

- (NSString*) selectedText {
	if (![self hasSelection]) return @"";
	TextPosition start, end;
	[self selectionStart:&start end:&end];
	NSMutableString* text = [NSMutableString string];
	for (NSInteger line = start.line; line <= end.line; line++) {
		NSString* lineText = [self textOfLine:line];
		NSUInteger from = line == start.line ? min_index(start.index, lineText.length) : 0;
		NSUInteger to = line == end.line ? min_index(end.index, lineText.length) : lineText.length;
		if (to > from) [text appendString:[lineText substringWithRange:NSMakeRange(from, to - from)]];
		if (line < end.line) [text appendString:@"\n"];
	}
	return text;
}

- (void) selectFrom:(TextPosition)anchor to:(TextPosition)head {
	_anchor = anchor;
	_head = head;
	[_owner paneDidSelect:self];
	[self setNeedsDisplay:YES];
}

/* The index in a line's text nearest x, on the wrapped line dy down from its top. */
- (NSUInteger) indexInText:(NSString*)text atX:(CGFloat)x dy:(CGFloat)dy {
	NSUInteger wanted = dy > 0 ? (NSUInteger)floor(dy / _owner.lineHeight) : 0;
	__block NSUInteger result = text.length;
	[_owner enumerateLinesOfText:text block:^(CTLineRef ctLine, CFRange range, NSUInteger index) {
		if (index != wanted) return;
		CFIndex found = x > 0 ? CTLineGetStringIndexForPosition(ctLine, CGPointMake(x, 0)) : kCFNotFound;
		result = found < 0 ? (NSUInteger)range.location : (NSUInteger)found;
	}];
	return min_index(result, text.length);
}

/* The caret position nearest a point. */
- (TextPosition) positionAtPoint:(NSPoint)point {
	DiffView* owner = _owner;
	DtFileDiff* diff = owner.diff;
	if (!diff) return kNoPosition;
	size_t lines = [self lineCount];
	if (lines == 0) return kNoPosition;
	NSInteger lastLine = (NSInteger)lines - 1;
	TextPosition start = {0, 0};
	TextPosition end = {lastLine, [self textOfLine:lastLine].length};

	NSInteger line;
	CGFloat top;
	if (owner.mode == kDiffModeUnified) {
		NSInteger row = [owner unifiedRowAtY:point.y];
		if (row < 0) return start;
		if (row > lastLine) return end;
		line = row;
		top = [owner unifiedY:(size_t)row];
	} else if (owner.mode == kDiffModeFluid) {
		CGFloat shift = [owner shift:_side];
		line = [owner lineAtY:point.y + shift side:_side];
		if (line < 0) return start;
		if (line > lastLine) return end;
		top = [owner lineY:(size_t)line side:_side] - shift;
	} else {
		size_t rows = dt_file_diff_row_count(diff);
		NSInteger row = [owner rowAtY:point.y];
		if (row < 0) return start;
		if ((size_t)row >= rows) return end;
		line = dt_file_diff_row_line(diff, (size_t)row, (uint8_t)_side);
		top = [owner rowY:(size_t)row];
		if (line < 0) {
			/* A filler row: the end of the line before it, or else the start of the line after. */
			for (size_t r = (size_t)row; r-- > 0;) {
				int32_t before = dt_file_diff_row_line(diff, r, (uint8_t)_side);
				if (before >= 0) return (TextPosition){before, [self textOfLine:before].length};
			}
			for (size_t r = (size_t)row + 1; r < rows; r++) {
				int32_t after = dt_file_diff_row_line(diff, r, (uint8_t)_side);
				if (after >= 0) return (TextPosition){after, 0};
			}
			return kNoPosition;
		}
	}

	NSString* text = [self textOfLine:line];
	return (TextPosition){line, [self indexInText:text atX:point.x - kTextPadding dy:point.y - top]};
}

- (void) mouseDown:(NSEvent*)event {
	[self.window makeFirstResponder:self];
	DiffView* owner = _owner;
	DtFileDiff* diff = owner.diff;
	if (!diff) return;
	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	if (owner.mode == kDiffModeFluid) {
		NSInteger line = [owner lineAtY:point.y + [owner shift:_side] side:_side];
		if (line >= 0) [owner selectHunkAtLine:(size_t)line side:_side];
	} else if (owner.mode == kDiffModeUnified) {
		NSInteger row = [owner unifiedRowAtY:point.y];
		if (row >= 0) [owner selectHunkAtUnifiedRow:(size_t)row];
	} else {
		NSInteger row = [owner rowAtY:point.y];
		if (row >= 0) [owner selectHunkAtRow:(size_t)row];
	}

	BOOL extend = (event.modifierFlags & NSEventModifierFlagShift) && _anchor.line >= 0;
	TextPosition position = [self positionAtPoint:point];
	if (position.line < 0) {
		[self clearSelection];
		return;
	}

	if (extend) {
		[self selectFrom:_anchor to:position];
	} else if (event.clickCount == 2) {
		NSString* text = [self textOfLine:position.line];
		NSRange word = NSMakeRange(position.index, 0);
		if (text.length > 0) {
			NSAttributedString* string = [[NSAttributedString alloc] initWithString:text];
			word = [string doubleClickAtIndex:min_index(position.index, text.length - 1)];
		}
		TextPosition start = {position.line, word.location};
		TextPosition end = {position.line, NSMaxRange(word)};
		[self selectFrom:start to:end];
	} else if (event.clickCount >= 3) {
		/* The whole line, through its line break when there's a next line. */
		TextPosition start = {position.line, 0};
		TextPosition end = {position.line, [self textOfLine:position.line].length};
		if ((size_t)position.line + 1 < [self lineCount]) {
			end = (TextPosition){position.line + 1, 0};
		}
		[self selectFrom:start to:end];
	} else {
		[self selectFrom:position to:position];
	}

	[self trackSelectionFrom:event];
}

/* Extend the selection until the mouse is released, scrolling while it's outside the view. */
- (void) trackSelectionFrom:(NSEvent*)event {
	NSEvent* drag = event;
	[NSEvent startPeriodicEventsAfterDelay:0.1 withPeriod:0.05];
	for (;;) {
		NSEvent* next = [self.window
			nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp | NSEventMaskPeriodic];
		if (next.type == NSEventTypeLeftMouseUp) break;
		if (next.type == NSEventTypeLeftMouseDragged) drag = next;
		if (drag == event) continue;
		[self autoscroll:drag];
		NSPoint point = [self convertPoint:drag.locationInWindow fromView:nil];
		TextPosition position = [self positionAtPoint:point];
		if (position.line >= 0 && !position_equal(position, _head)) [self selectFrom:_anchor to:position];
	}
	[NSEvent stopPeriodicEvents];
}

- (IBAction) copy:(id)sender {
	if (![self hasSelection]) return;
	NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
	[pasteboard clearContents];
	[pasteboard setString:[self selectedText] forType:NSPasteboardTypeString];
}

- (IBAction) selectAll:(id)sender {
	size_t lines = [self lineCount];
	if (lines == 0) return;
	NSInteger lastLine = (NSInteger)lines - 1;
	TextPosition start = {0, 0};
	TextPosition end = {lastLine, [self textOfLine:lastLine].length};
	[self selectFrom:start to:end];
}

- (BOOL) validateMenuItem:(NSMenuItem*)menuItem {
	SEL action = menuItem.action;
	if (action == @selector(copy:)) return [self hasSelection];
	if (action == @selector(selectAll:)) return _owner.diff != NULL;
	if (action == @selector(openWithApplication:) || action == @selector(revealInFinder:) || action == @selector(copyPath:)) {
		return _menuFile != nil;
	}
	return YES;
}

#pragma mark Context menu

/* The side of the file at a point: the pane's, or in Unified mode, the line's, B for an unchanged one. */
- (NSUInteger) sideAtPoint:(NSPoint)point {
	DiffView* owner = _owner;
	if (owner.mode != kDiffModeUnified) return _side;
	NSInteger row = [owner unifiedRowAtY:point.y];
	if (row < 0 || (size_t)row >= dt_file_diff_unified_count(owner.diff)) return DT_SIDE_B;
	return dt_file_diff_unified_line(owner.diff, (size_t)row, DT_SIDE_B) >= 0 ? DT_SIDE_B : DT_SIDE_A;
}

static NSMenuItem* menu_item(NSString* title, SEL action, id target) {
	NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
	item.target = target;
	return item;
}

- (NSMenu*) menuForEvent:(NSEvent*)event {
	DiffView* owner = _owner;
	if (!owner.diff) return nil;
	NSUInteger side = [self sideAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
	_menuFile = [owner fileURLForSide:side];

	NSMenu* menu = [[NSMenu alloc] initWithTitle:@""];
	NSString* title = side == DT_SIDE_A ? @"File A" : @"File B";
	if (@available(macOS 14.0, *)) {
		[menu addItem:[NSMenuItem sectionHeaderWithTitle:title]];
	} else {
		[menu addItem:menu_item(title, NULL, nil)];
	}
	NSMenuItem* openWith = menu_item(@"Open With", NULL, nil);
	if (_menuFile) openWith.submenu = [self openWithMenuForFile:_menuFile];
	[menu addItem:openWith];
	[menu addItem:menu_item(@"Reveal in Finder", @selector(revealInFinder:), self)];
	[menu addItem:menu_item(@"Copy Path", @selector(copyPath:), self)];
	[menu addItem:[NSMenuItem separatorItem]];
	[menu addItem:menu_item(@"Copy", @selector(copy:), self)];
	if (@available(macOS 13.0, *)) {
		if (_menuFile) {
			[menu addItem:[NSMenuItem separatorItem]];
			[menu addItem:[[NSSharingServicePicker alloc] initWithItems:@[_menuFile]].standardShareMenuItem];
		}
	}
	return menu;
}

/* The apps that can open a file, its default app first. */
- (NSMenu*) openWithMenuForFile:(NSURL*)file {
	NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Open With"];
	NSURL* defaultApp = [[NSWorkspace sharedWorkspace] URLForApplicationToOpenURL:file];
	if (defaultApp) {
		[menu addItem:[self itemOpeningWithApplication:defaultApp suffix:@" (default)"]];
	}

	NSArray<NSURL*>* apps = CFBridgingRelease(LSCopyApplicationURLsForURL((__bridge CFURLRef)file, kLSRolesAll));
	NSMutableArray<NSMenuItem*>* others = [NSMutableArray array];
	NSMutableSet<NSString*>* seen = [NSMutableSet set];
	if (defaultApp.path) [seen addObject:defaultApp.path];
	for (NSURL* app in apps) {
		if (!app.path || [seen containsObject:app.path]) continue;
		[seen addObject:app.path];
		[others addObject:[self itemOpeningWithApplication:app suffix:@""]];
	}
	[others sortUsingComparator:^NSComparisonResult(NSMenuItem* a, NSMenuItem* b) {
		return [a.title localizedStandardCompare:b.title];
	}];
	if (defaultApp && others.count > 0) [menu addItem:[NSMenuItem separatorItem]];
	for (NSMenuItem* item in others) [menu addItem:item];
	return menu;
}

- (NSMenuItem*) itemOpeningWithApplication:(NSURL*)app suffix:(NSString*)suffix {
	NSString* name = [[NSFileManager defaultManager] displayNameAtPath:app.path];
	if ([name.pathExtension isEqualToString:@"app"]) name = name.stringByDeletingPathExtension;
	NSMenuItem* item = menu_item([name stringByAppendingString:suffix], @selector(openWithApplication:), self);
	item.representedObject = app;
	NSImage* icon = [[[NSWorkspace sharedWorkspace] iconForFile:app.path] copy];
	icon.size = NSMakeSize(16, 16);
	item.image = icon;
	return item;
}

- (IBAction) openWithApplication:(NSMenuItem*)sender {
	NSURL* app = sender.representedObject;
	if (!_menuFile || ![app isKindOfClass:[NSURL class]]) return;
	[[NSWorkspace sharedWorkspace]
		openURLs:@[_menuFile]
		withApplicationAtURL:app
		configuration:[NSWorkspaceOpenConfiguration configuration]
		completionHandler:nil];
}

- (IBAction) revealInFinder:(id)sender {
	if (_menuFile) [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[_menuFile]];
}

- (IBAction) copyPath:(id)sender {
	if (!_menuFile) return;
	NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
	[pasteboard clearContents];
	[pasteboard setString:_menuFile.path forType:NSPasteboardTypeString];
}

@end

#pragma mark - Drag and drop

@implementation DropHighlightView

- (instancetype) initWithFrame:(NSRect)frame {
	if ((self = [super initWithFrame:frame])) _side = -1;
	return self;
}

- (void) setSide:(NSInteger)side {
	if (side == _side) return;
	_side = side;
	[self setNeedsDisplay:YES];
}

- (NSView*) hitTest:(NSPoint)point {
	return nil;
}

- (void) drawRect:(NSRect)dirty {
	if (_side < 0) return;
	NSRect rect = self.bounds;
	if ((NSUInteger)_side < kSideCount) {
		rect.size.width = NSWidth(self.bounds) / (CGFloat)kSideCount;
		rect.origin.x = (CGFloat)_side * rect.size.width;
	}
	NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, 6, 6) xRadius:8 yRadius:8];
	[[[NSColor controlAccentColor] colorWithAlphaComponent:0.12] setFill];
	[path fill];
	path.lineWidth = 2;
	[[NSColor controlAccentColor] setStroke];
	[path stroke];
}

@end

static NSArray<NSURL*>* dragged_file_urls(id<NSDraggingInfo> info) {
	NSArray* urls = [info.draggingPasteboard
		readObjectsForClasses:@[[NSURL class]]
		options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
	return urls ? urls : @[];
}

@implementation DropView

/* The side a drag would replace: the half under it, or all sides when dragging several items. */
- (NSInteger) sideForDrag:(id<NSDraggingInfo>)info {
	NSUInteger count = dragged_file_urls(info).count;
	if (count == 0) return -1;
	if (count >= kSideCount) return (NSInteger)kSideCount;
	NSPoint point = [self convertPoint:info.draggingLocation fromView:nil];
	NSInteger side = (NSInteger)floor(point.x / (NSWidth(self.bounds) / (CGFloat)kSideCount));
	if (side < 0) side = 0;
	if (side >= (NSInteger)kSideCount) side = (NSInteger)kSideCount - 1;
	return side;
}

- (NSDragOperation) updateDrag:(id<NSDraggingInfo>)info {
	NSInteger side = [self sideForDrag:info];
	self.highlightView.side = side;
	return side < 0 ? NSDragOperationNone : NSDragOperationGeneric;
}

- (NSDragOperation) draggingEntered:(id<NSDraggingInfo>)info {
	return [self updateDrag:info];
}

- (NSDragOperation) draggingUpdated:(id<NSDraggingInfo>)info {
	return [self updateDrag:info];
}

- (void) draggingExited:(id<NSDraggingInfo>)info {
	self.highlightView.side = -1;
}

- (BOOL) performDragOperation:(id<NSDraggingInfo>)info {
	NSInteger side = [self sideForDrag:info];
	self.highlightView.side = -1;
	if (side < 0) return NO;
	[self.controller dropURLs:dragged_file_urls(info) side:side];
	return YES;
}

@end

#pragma mark - DiffWindowController

@implementation SidebarItem
@end

@implementation DiffWindowController {
	NSSplitViewController* _split;
	NSTableView* _table;
	NSTextField* _sidebarTitle;
	NSProgressIndicator* _spinner;
	NSArray<NSTextField*>* _paneTitles;
	DiffView* _diffView;
	NSTextField* _message;
	NSTextField* _changeLabel;
	NSButton* _previousButton;
	NSButton* _nextButton;
	NSButton* _whitespaceCheckbox;
	NSSegmentedControl* _modeControl;
	DropHighlightView* _highlight;

	NSMutableArray<SidebarItem*>* _items;
	NSUInteger _shownGeneration;
	NSInteger _shownEntry;
	/* Shown instead of the diff, such as for binary files. */
	NSString* _fileMessage;
	BOOL _ignoreWhitespace;
}

- (instancetype) init {
	NSWindow* window = [[NSWindow alloc]
		initWithContentRect:NSMakeRect(0, 0, 1200, 780)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
		backing:NSBackingStoreBuffered
		defer:YES];
	if ((self = [super initWithWindow:window])) {
		_items = [NSMutableArray array];
		_shownGeneration = NSUIntegerMax;
		_shownEntry = -1;
		window.delegate = self;
		window.restorable = NO;
		window.tabbingIdentifier = kComparisonType;
		window.minSize = NSMakeSize(640, 400);
		[self buildViews];
	}
	return self;
}

- (NSView*) buildSidebar {
	_sidebarTitle = [NSTextField labelWithString:@""];
	_sidebarTitle.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
	_sidebarTitle.lineBreakMode = NSLineBreakByTruncatingTail;
	[_sidebarTitle setContentCompressionResistancePriority:kSqueezablePriority forOrientation:NSLayoutConstraintOrientationHorizontal];

	_spinner = [[NSProgressIndicator alloc] init];
	_spinner.style = NSProgressIndicatorStyleSpinning;
	_spinner.controlSize = NSControlSizeSmall;
	_spinner.displayedWhenStopped = NO;

	NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:@"file"];
	column.resizingMask = NSTableColumnAutoresizingMask;
	_table = [[NSTableView alloc] init];
	[_table addTableColumn:column];
	_table.headerView = nil;
	_table.style = NSTableViewStyleSourceList;
	_table.rowHeight = 24;
	_table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
	_table.dataSource = self;
	_table.delegate = self;

	NSScrollView* tableScroll = [[NSScrollView alloc] init];
	tableScroll.documentView = _table;
	tableScroll.hasVerticalScroller = YES;
	tableScroll.autohidesScrollers = YES;
	tableScroll.drawsBackground = NO;

	NSView* sidebar = [[NSView alloc] init];
	add_subviews(sidebar, @[_sidebarTitle, _spinner, tableScroll]);
	[NSLayoutConstraint activateConstraints:@[
		[_sidebarTitle.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor constant:16],
		[_sidebarTitle.centerYAnchor constraintEqualToAnchor:sidebar.topAnchor constant:kHeaderHeight / 2],
		[_spinner.leadingAnchor constraintEqualToAnchor:_sidebarTitle.trailingAnchor constant:6],
		[_spinner.centerYAnchor constraintEqualToAnchor:_sidebarTitle.centerYAnchor],
		[_spinner.trailingAnchor constraintLessThanOrEqualToAnchor:sidebar.trailingAnchor constant:-12],
		[tableScroll.topAnchor constraintEqualToAnchor:sidebar.topAnchor constant:kHeaderHeight],
		[tableScroll.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor],
		[tableScroll.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor],
		[tableScroll.bottomAnchor constraintEqualToAnchor:sidebar.bottomAnchor]
	]];
	return sidebar;
}

- (NSView*) buildDetail {
	DropView* detail = [[DropView alloc] init];
	detail.controller = self;
	[detail registerForDraggedTypes:@[NSPasteboardTypeFileURL]];

	NSMutableArray<NSTextField*>* titles = [NSMutableArray array];
	for (NSUInteger side = 0; side < kSideCount; side++) {
		NSTextField* title = [NSTextField labelWithString:@""];
		title.lineBreakMode = NSLineBreakByTruncatingMiddle;
		/* Truncate a long name rather than push the sidebar narrower. */
		[title setContentCompressionResistancePriority:kSqueezablePriority forOrientation:NSLayoutConstraintOrientationHorizontal];
		[titles addObject:title];
	}
	_paneTitles = titles;

	NSBox* topSeparator = [[NSBox alloc] init];
	topSeparator.boxType = NSBoxSeparator;
	NSBox* bottomSeparator = [[NSBox alloc] init];
	bottomSeparator.boxType = NSBoxSeparator;

	_diffView = [[DiffView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
	__weak DiffWindowController* weakSelf = self;
	_diffView.currentHunkChanged = ^(void) {
		[weakSelf updateChangeLabel];
	};
	NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
	NSInteger mode = [defaults objectForKey:kDiffModeDefault] ? [defaults integerForKey:kDiffModeDefault] : kDiffModeFluid;
	_diffView.mode = mode >= kDiffModeBlocks && mode <= kDiffModeUnified ? mode : kDiffModeFluid;
	_diffView.wrapsLines = [defaults objectForKey:kWrapLinesDefault] ? [defaults boolForKey:kWrapLinesDefault] : YES;

	_message = [NSTextField wrappingLabelWithString:@""];
	_message.alignment = NSTextAlignmentCenter;
	_message.textColor = [NSColor secondaryLabelColor];
	_message.font = [NSFont systemFontOfSize:15];

	_whitespaceCheckbox = [NSButton checkboxWithTitle:@"Ignore whitespace" target:self action:@selector(toggleIgnoreWhitespace:)];
	_changeLabel = [NSTextField labelWithString:@""];
	_changeLabel.textColor = [NSColor secondaryLabelColor];
	_previousButton = [NSButton
		buttonWithImage:[NSImage imageWithSystemSymbolName:@"chevron.up" accessibilityDescription:@"Previous Change"]
		target:self
		action:@selector(previousChange:)];
	_nextButton = [NSButton
		buttonWithImage:[NSImage imageWithSystemSymbolName:@"chevron.down" accessibilityDescription:@"Next Change"]
		target:self
		action:@selector(nextChange:)];
	/* Segments in the order of the kDiffMode values. */
	_modeControl = [NSSegmentedControl
		segmentedControlWithLabels:@[@"Blocks", @"Fluid", @"Unified"]
		trackingMode:NSSegmentSwitchTrackingSelectOne
		target:self
		action:@selector(modeControlDidChange:)];
	_modeControl.selectedSegment = _diffView.mode;
	NSStackView* bar = [[NSStackView alloc] init];
	bar.edgeInsets = NSEdgeInsetsMake(0, 12, 0, 12);
	bar.spacing = 12;
	[bar addView:_modeControl inGravity:NSStackViewGravityLeading];
	[bar addView:_whitespaceCheckbox inGravity:NSStackViewGravityTrailing];
	[bar addView:_changeLabel inGravity:NSStackViewGravityTrailing];
	[bar addView:_previousButton inGravity:NSStackViewGravityTrailing];
	[bar addView:_nextButton inGravity:NSStackViewGravityTrailing];

	_highlight = [[DropHighlightView alloc] initWithFrame:NSZeroRect];
	detail.highlightView = _highlight;

	add_subviews(detail, @[titles[0], titles[1], topSeparator, _diffView, _message, bottomSeparator, bar, _highlight]);
	[NSLayoutConstraint activateConstraints:@[
		/* Each title over its side, as DiffView lays them out. */
		[titles[0].leadingAnchor constraintEqualToAnchor:detail.leadingAnchor constant:12],
		[titles[0].trailingAnchor constraintLessThanOrEqualToAnchor:detail.centerXAnchor constant:-kMiddleWidth / 2 - 8],
		[titles[0].centerYAnchor constraintEqualToAnchor:detail.topAnchor constant:kHeaderHeight / 2],
		[titles[1].leadingAnchor constraintEqualToAnchor:detail.centerXAnchor constant:kMiddleWidth / 2 + 12],
		[titles[1].trailingAnchor constraintLessThanOrEqualToAnchor:detail.trailingAnchor constant:-12],
		[titles[1].centerYAnchor constraintEqualToAnchor:titles[0].centerYAnchor],

		[topSeparator.topAnchor constraintEqualToAnchor:detail.topAnchor constant:kHeaderHeight],
		[topSeparator.leadingAnchor constraintEqualToAnchor:detail.leadingAnchor],
		[topSeparator.trailingAnchor constraintEqualToAnchor:detail.trailingAnchor],
		[topSeparator.heightAnchor constraintEqualToConstant:1],

		[_diffView.topAnchor constraintEqualToAnchor:topSeparator.bottomAnchor],
		[_diffView.leadingAnchor constraintEqualToAnchor:detail.leadingAnchor],
		[_diffView.trailingAnchor constraintEqualToAnchor:detail.trailingAnchor],
		[_diffView.bottomAnchor constraintEqualToAnchor:bottomSeparator.topAnchor],

		[_message.centerXAnchor constraintEqualToAnchor:_diffView.centerXAnchor],
		[_message.centerYAnchor constraintEqualToAnchor:_diffView.centerYAnchor],
		[_message.widthAnchor constraintLessThanOrEqualToConstant:420],

		[bottomSeparator.leadingAnchor constraintEqualToAnchor:detail.leadingAnchor],
		[bottomSeparator.trailingAnchor constraintEqualToAnchor:detail.trailingAnchor],
		[bottomSeparator.heightAnchor constraintEqualToConstant:1],

		[bar.topAnchor constraintEqualToAnchor:bottomSeparator.bottomAnchor],
		[bar.leadingAnchor constraintEqualToAnchor:detail.leadingAnchor],
		[bar.trailingAnchor constraintEqualToAnchor:detail.trailingAnchor],
		[bar.bottomAnchor constraintEqualToAnchor:detail.bottomAnchor],
		[bar.heightAnchor constraintEqualToConstant:kBottomBarHeight],

		[_highlight.topAnchor constraintEqualToAnchor:detail.topAnchor],
		[_highlight.leadingAnchor constraintEqualToAnchor:detail.leadingAnchor],
		[_highlight.trailingAnchor constraintEqualToAnchor:detail.trailingAnchor],
		[_highlight.bottomAnchor constraintEqualToAnchor:detail.bottomAnchor]
	]];
	return detail;
}

- (void) buildViews {
	NSViewController* sidebarController = [[NSViewController alloc] init];
	sidebarController.view = [self buildSidebar];
	NSViewController* detailController = [[NSViewController alloc] init];
	detailController.view = [self buildDetail];

	NSSplitViewItem* sidebarItem = [NSSplitViewItem sidebarWithViewController:sidebarController];
	sidebarItem.minimumThickness = 180;
	sidebarItem.maximumThickness = 480;
	sidebarItem.canCollapse = YES;
	/* Keep the sidebar's width as the window resizes, and against labels too long for theirs. */
	sidebarItem.holdingPriority = kSidebarHoldingPriority;
	NSSplitViewItem* detailItem = [NSSplitViewItem splitViewItemWithViewController:detailController];
	detailItem.minimumThickness = 400;

	_split = [[NSSplitViewController alloc] init];
	[_split addSplitViewItem:sidebarItem];
	[_split addSplitViewItem:detailItem];

	NSWindow* window = self.window;
	window.contentViewController = _split;
	[window setContentSize:NSMakeSize(1200, 780)];
	[window layoutIfNeeded];
	[_split.splitView setPosition:260 ofDividerAtIndex:0];
	[window center];
	[self restoreWindowFrame];
	window.initialFirstResponder = _table;

	[self updateChangeLabel];
}

/* Open where the last comparison window was, moved off any window already there. */
- (void) restoreWindowFrame {
	NSWindow* window = self.window;
	NSString* frame = [[NSUserDefaults standardUserDefaults] stringForKey:kWindowFrameDefault];
	if (frame) [window setFrameFromString:frame];

	BOOL covered = YES;
	for (int tries = 0; covered && tries < 20; tries++) {
		covered = NO;
		for (NSWindow* other in NSApp.windows) {
			if (other == window || !other.visible || ![other.delegate isKindOfClass:[DiffWindowController class]]) continue;
			if (fabs(NSMinX(other.frame) - NSMinX(window.frame)) < 1 && fabs(NSMaxY(other.frame) - NSMaxY(window.frame)) < 1) {
				covered = YES;
			}
		}
		if (covered) {
			[window setFrameTopLeftPoint:NSMakePoint(NSMinX(window.frame) + kCascadeOffset, NSMaxY(window.frame) - kCascadeOffset)];
		}
	}
}

- (void) saveWindowFrame {
	NSWindow* window = self.window;
	if (!window.visible || (window.styleMask & NSWindowStyleMaskFullScreen)) return;
	[[NSUserDefaults standardUserDefaults] setObject:window.stringWithSavedFrame forKey:kWindowFrameDefault];
}

- (void) windowDidMove:(NSNotification*)notification {
	[self saveWindowFrame];
}

- (void) windowDidResize:(NSNotification*)notification {
	[self saveWindowFrame];
}

#pragma mark Document state

- (DiffDocument*) diffDocument {
	return self.document;
}

- (void) documentDidChange {
	[self synchronizeWindowTitleWithDocumentName];
	DiffDocument* doc = [self diffDocument];
	if (doc.generation != _shownGeneration) {
		_shownGeneration = doc.generation;
		[self reloadItems];
	}
	[self updateSidebarTitle];
	[self updatePaneTitles];
	[self updateMessage];
}

- (void) setDocument:(id)document {
	[super setDocument:document];
	if (document) [self documentDidChange];
}

- (void) reloadItems {
	[_items removeAllObjects];
	DiffDocument* doc = [self diffDocument];
	DtComparison* cmp = doc.comparison;
	size_t count = cmp ? dt_comparison_count(cmp) : 0;
	NSString* lastDir = @"";
	for (size_t i = 0; i < count; i++) {
		DtEntry entry = dt_comparison_entry(cmp, i);
		/* Only list unchanged files when comparing two files. */
		if (entry.status == DT_STATUS_SAME && count > 1) continue;

		NSString* dir = dt_string(entry.dir);
		if (dir.length > 0 && ![dir isEqualToString:lastDir]) {
			SidebarItem* group = [[SidebarItem alloc] init];
			group.isGroup = YES;
			group.title = [dir stringByReplacingOccurrencesOfString:@"/" withString:@" › "];
			[_items addObject:group];
		}
		lastDir = dir;

		SidebarItem* item = [[SidebarItem alloc] init];
		item.title = dt_string(entry.name);
		/* Comparing two files: name them by their labels, when they have them. */
		if (count == 1 && ([doc labelForSide:0] || [doc labelForSide:1])) {
			NSString* a = [doc nameForSide:0];
			NSString* b = [doc nameForSide:1];
			item.title = [a isEqualToString:b] ? a : [NSString stringWithFormat:@"%@ → %@", a, b];
		}
		item.entry = i;
		item.status = entry.status;
		[_items addObject:item];
	}
	[_table reloadData];

	NSInteger first = [self fileRowFrom:-1 step:1];
	if (first >= 0) {
		[_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)first] byExtendingSelection:NO];
		[_table scrollRowToVisible:first];
	}
	[self showSelectedEntry:YES];
}

- (void) updateSidebarTitle {
	DiffDocument* doc = [self diffDocument];
	if (doc.comparing) {
		_sidebarTitle.stringValue = @"Comparing…";
		[_spinner startAnimation:nil];
		return;
	}
	[_spinner stopAnimation:nil];
	if (!doc.comparison) {
		_sidebarTitle.stringValue = @"";
		return;
	}
	NSUInteger changed = 0;
	for (SidebarItem* item in _items) {
		if (!item.isGroup && item.status != DT_STATUS_SAME) changed++;
	}
	_sidebarTitle.stringValue = changed == 1
		? @"1 changed file"
		: [NSString stringWithFormat:@"%lu changed files", (unsigned long)changed];
}

- (void) updatePaneTitles {
	NSArray<NSString*>* letters = @[@"A", @"B"];
	DiffDocument* doc = [self diffDocument];
	DtComparison* cmp = doc.comparison;
	NSDictionary* letterAttributes = @{
		NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
		NSForegroundColorAttributeName: [NSColor secondaryLabelColor]
	};
	NSDictionary* nameAttributes = @{
		NSFontAttributeName: [NSFont systemFontOfSize:13],
		NSForegroundColorAttributeName: [NSColor labelColor]
	};

	for (NSUInteger side = 0; side < kSideCount; side++) {
		NSString* name = @"";
		NSString* path = nil;
		if (cmp && _shownEntry >= 0) {
			DtEntry entry = dt_comparison_entry(cmp, (size_t)_shownEntry);
			path = dt_string(dt_comparison_entry_path(cmp, (size_t)_shownEntry, (uint8_t)side));
			NSString* dir = dt_string(entry.dir);
			NSString* label = [doc labelForSide:side];
			if (path.length == 0) {
				name = @"Not present";
			} else if (label && dt_comparison_count(cmp) == 1 && dir.length == 0) {
				name = label;
			} else if (dir.length > 0) {
				dir = [dir stringByReplacingOccurrencesOfString:@"/" withString:@" › "];
				name = [NSString stringWithFormat:@"%@ › %@", dir, path.lastPathComponent];
			} else {
				name = path.lastPathComponent;
			}
		} else {
			NSURL* url = [doc urlForSide:side];
			if (url) name = [doc nameForSide:side];
			path = url.path;
		}

		NSMutableAttributedString* title = [[NSMutableAttributedString alloc] initWithString:letters[side] attributes:letterAttributes];
		NSString* spacedName = [@"   " stringByAppendingString:name];
		[title appendAttributedString:[[NSAttributedString alloc] initWithString:spacedName attributes:nameAttributes]];
		_paneTitles[side].attributedStringValue = title;
		_paneTitles[side].toolTip = path.length > 0 ? path : nil;
	}
}

- (void) updateMessage {
	DiffDocument* doc = [self diffDocument];
	NSURL* a = [doc urlForSide:0];
	NSURL* b = [doc urlForSide:1];
	NSString* message = nil;
	if (!a && !b) {
		message = @"Drop two files or folders here to compare them, or choose File › Open…";
	} else if (!a || !b) {
		message = [NSString stringWithFormat:@"Drop a file or folder on the %@ to compare it with “%@”.",
			a ? @"right" : @"left", (a ? a : b).lastPathComponent];
	} else if (doc.comparing) {
		message = nil;
	} else if (doc.comparison && dt_comparison_error(doc.comparison).len > 0) {
		message = dt_string(dt_comparison_error(doc.comparison));
	} else if (doc.comparison && _items.count == 0) {
		message = @"There are no differences.";
	} else {
		message = _fileMessage;
	}
	_message.stringValue = message ? message : @"";
	_message.hidden = message == nil;
}

- (void) updateChangeLabel {
	DtFileDiff* diff = _diffView.diff;
	size_t count = diff ? dt_file_diff_hunk_count(diff) : 0;
	NSInteger current = _diffView.currentHunk;
	if (!diff || _fileMessage) {
		_changeLabel.stringValue = @"";
	} else if (count == 0) {
		_changeLabel.stringValue = @"No changes";
	} else {
		_changeLabel.stringValue = [NSString stringWithFormat:@"Change %ld of %lu", (long)current + 1, (unsigned long)count];
	}
	_previousButton.enabled = current > 0;
	_nextButton.enabled = count > 0 && (size_t)(current + 1) < count;
}

#pragma mark Showing files

- (NSInteger) fileRowFrom:(NSInteger)row step:(NSInteger)step {
	for (NSInteger i = row + step; i >= 0 && i < (NSInteger)_items.count; i += step) {
		if (!_items[(NSUInteger)i].isGroup) return i;
	}
	return -1;
}

/* Show the selected file's diff, unless it's already shown and force is NO. */
- (void) showSelectedEntry:(BOOL)force {
	NSInteger row = _table.selectedRow;
	NSInteger entry = -1;
	if (row >= 0 && (NSUInteger)row < _items.count && !_items[(NSUInteger)row].isGroup) {
		entry = (NSInteger)_items[(NSUInteger)row].entry;
	}
	if (entry == _shownEntry && !force) return;

	_shownEntry = entry;
	_fileMessage = nil;
	DtComparison* cmp = [self diffDocument].comparison;
	DtFileDiff* diff = NULL;
	if (entry >= 0 && cmp) {
		DtDiffOptions options = {(uint32_t)(_ignoreWhitespace ? DT_IGNORE_WHITESPACE : 0), kTabWidth};
		diff = dt_file_diff_new(cmp, (size_t)entry, options);
		uint32_t flags = dt_file_diff_flags(diff);
		if (dt_file_diff_error(diff).len > 0) {
			_fileMessage = dt_string(dt_file_diff_error(diff));
		} else if (flags & DT_DIFF_BINARY) {
			_fileMessage = (flags & DT_DIFF_IDENTICAL) ? @"The binary files are identical." : @"The binary files differ.";
		}
	}
	NSMutableArray* files = [NSMutableArray array];
	for (NSUInteger side = 0; side < kSideCount; side++) {
		NSString* path = cmp && entry >= 0 ? dt_string(dt_comparison_entry_path(cmp, (size_t)entry, (uint8_t)side)) : @"";
		[files addObject:path.length > 0 ? (id)[NSURL fileURLWithPath:path] : [NSNull null]];
	}
	_diffView.fileURLs = files;
	_diffView.diff = diff;
	[_diffView scrollToCurrentHunk];

	[self updatePaneTitles];
	[self updateChangeLabel];
	[self updateMessage];
}

- (void) dropURLs:(NSArray<NSURL*>*)urls side:(NSInteger)side {
	DiffDocument* doc = [self diffDocument];
	if (urls.count == 0) return;
	if (side < 0 || (NSUInteger)side >= kSideCount || urls.count > 1) {
		[doc setURLs:urls];
	} else {
		[doc setURL:urls[0] forSide:(NSUInteger)side];
	}
}

#pragma mark Table

- (NSInteger) numberOfRowsInTableView:(NSTableView*)tableView {
	return (NSInteger)_items.count;
}

- (BOOL) tableView:(NSTableView*)tableView isGroupRow:(NSInteger)row {
	return _items[(NSUInteger)row].isGroup;
}

- (BOOL) tableView:(NSTableView*)tableView shouldSelectRow:(NSInteger)row {
	return !_items[(NSUInteger)row].isGroup;
}

- (void) tableViewSelectionDidChange:(NSNotification*)notification {
	[self showSelectedEntry:NO];
}

- (NSView*) tableView:(NSTableView*)tableView viewForTableColumn:(NSTableColumn*)column row:(NSInteger)row {
	SidebarItem* item = _items[(NSUInteger)row];
	if (item.isGroup) {
		NSTextField* label = [tableView makeViewWithIdentifier:@"group" owner:self];
		if (!label) {
			label = [NSTextField labelWithString:@""];
			label.identifier = @"group";
			label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
			label.textColor = [NSColor secondaryLabelColor];
			label.lineBreakMode = NSLineBreakByTruncatingHead;
		}
		label.stringValue = item.title;
		return label;
	}

	NSTableCellView* cell = [tableView makeViewWithIdentifier:@"file" owner:self];
	if (!cell) {
		cell = [[NSTableCellView alloc] init];
		cell.identifier = @"file";
		NSImageView* icon = [[NSImageView alloc] init];
		NSTextField* label = [NSTextField labelWithString:@""];
		label.lineBreakMode = NSLineBreakByTruncatingMiddle;
		add_subviews(cell, @[icon, label]);
		cell.imageView = icon;
		cell.textField = label;
		[NSLayoutConstraint activateConstraints:@[
			[icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
			[icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
			[icon.widthAnchor constraintEqualToConstant:16],
			[icon.heightAnchor constraintEqualToConstant:16],
			[label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:6],
			[label.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-4],
			[label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]
		]];
	}
	cell.textField.stringValue = item.title;
	cell.imageView.image = [NSImage imageWithSystemSymbolName:status_symbol(item.status) accessibilityDescription:status_name(item.status)];
	cell.imageView.contentTintColor = status_color(item.status);
	return cell;
}

#pragma mark Actions

- (IBAction) newWindowForTab:(id)sender {
	NSError* error = nil;
	NSDocument* doc = [[NSDocumentController sharedDocumentController] openUntitledDocumentAndDisplay:NO error:&error];
	if (!doc) {
		if (error) [self presentError:error];
		return;
	}
	[doc makeWindowControllers];
	NSWindow* window = doc.windowControllers.firstObject.window;
	[self.window addTabbedWindow:window ordered:NSWindowAbove];
	[window makeKeyAndOrderFront:nil];
}

- (IBAction) toggleSidebar:(id)sender {
	[_split toggleSidebar:sender];
}

- (IBAction) selectPreviousFile:(id)sender {
	[self selectFileStep:-1];
}

- (IBAction) selectNextFile:(id)sender {
	[self selectFileStep:1];
}

- (void) selectFileStep:(NSInteger)step {
	NSInteger row = [self fileRowFrom:_table.selectedRow step:step];
	if (row < 0) return;
	[_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
	[_table scrollRowToVisible:row];
}

- (IBAction) previousChange:(id)sender {
	[self moveChange:-1];
}

- (IBAction) nextChange:(id)sender {
	[self moveChange:1];
}

- (void) moveChange:(NSInteger)step {
	DtFileDiff* diff = _diffView.diff;
	if (!diff) return;
	NSInteger hunk = _diffView.currentHunk + step;
	if (hunk < 0 || hunk >= (NSInteger)dt_file_diff_hunk_count(diff)) return;
	_diffView.currentHunk = hunk;
	[_diffView scrollToCurrentHunk];
	[self updateChangeLabel];
}

- (IBAction) showBlocks:(id)sender {
	[self setDiffMode:kDiffModeBlocks];
}

- (IBAction) showFluid:(id)sender {
	[self setDiffMode:kDiffModeFluid];
}

- (IBAction) showUnified:(id)sender {
	[self setDiffMode:kDiffModeUnified];
}

- (IBAction) modeControlDidChange:(id)sender {
	[self setDiffMode:_modeControl.selectedSegment];
}

- (void) setDiffMode:(NSInteger)mode {
	_diffView.mode = mode;
	_modeControl.selectedSegment = mode;
	[[NSUserDefaults standardUserDefaults] setInteger:mode forKey:kDiffModeDefault];
}

- (IBAction) toggleWrapLines:(id)sender {
	_diffView.wrapsLines = !_diffView.wrapsLines;
	[[NSUserDefaults standardUserDefaults] setBool:_diffView.wrapsLines forKey:kWrapLinesDefault];
}

- (IBAction) toggleIgnoreWhitespace:(id)sender {
	_ignoreWhitespace = !_ignoreWhitespace;
	_whitespaceCheckbox.state = _ignoreWhitespace ? NSControlStateValueOn : NSControlStateValueOff;
	[self showSelectedEntry:YES];
}

- (IBAction) increaseTextSize:(id)sender {
	[self setTextSize:_diffView.fontSize + 1];
}

- (IBAction) decreaseTextSize:(id)sender {
	[self setTextSize:_diffView.fontSize - 1];
}

- (void) setTextSize:(CGFloat)size {
	if (size < 8 || size > 36) return;
	_diffView.fontSize = size;
}

- (BOOL) validateMenuItem:(NSMenuItem*)menuItem {
	SEL action = menuItem.action;
	if (action == @selector(toggleIgnoreWhitespace:)) {
		menuItem.state = _ignoreWhitespace ? NSControlStateValueOn : NSControlStateValueOff;
	} else if (action == @selector(toggleWrapLines:)) {
		menuItem.state = _diffView.wrapsLines ? NSControlStateValueOn : NSControlStateValueOff;
	} else if (action == @selector(showBlocks:)) {
		menuItem.state = _diffView.mode == kDiffModeBlocks ? NSControlStateValueOn : NSControlStateValueOff;
	} else if (action == @selector(showFluid:)) {
		menuItem.state = _diffView.mode == kDiffModeFluid ? NSControlStateValueOn : NSControlStateValueOff;
	} else if (action == @selector(showUnified:)) {
		menuItem.state = _diffView.mode == kDiffModeUnified ? NSControlStateValueOn : NSControlStateValueOff;
	} else if (action == @selector(previousChange:)) {
		return _previousButton.enabled;
	} else if (action == @selector(nextChange:)) {
		return _nextButton.enabled;
	} else if (action == @selector(selectPreviousFile:)) {
		return [self fileRowFrom:_table.selectedRow step:-1] >= 0;
	} else if (action == @selector(selectNextFile:)) {
		return [self fileRowFrom:_table.selectedRow step:1] >= 0;
	} else if (action == @selector(increaseTextSize:)) {
		return _diffView.fontSize < 36;
	} else if (action == @selector(decreaseTextSize:)) {
		return _diffView.fontSize > 8;
	}
	return YES;
}

@end

#pragma mark - DiffDocument

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
	dt_comparison_free(_comparison);
}

+ (BOOL) autosavesInPlace {
	return NO;
}

- (void) makeWindowControllers {
	[self addWindowController:[[DiffWindowController alloc] init]];
}

- (void) close {
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

/* Start comparing in the background once every side is set. */
- (void) urlsDidChange {
	_generation++;
	dt_comparison_free(_comparison);
	_comparison = NULL;

	NSURL* a = [self urlForSide:0];
	NSURL* b = [self urlForSide:1];
	_comparing = a && b;
	if (_comparing) {
		NSUInteger generation = _generation;
		NSString* pathA = a.path;
		NSString* pathB = b.path;
		__weak DiffDocument* weakSelf = self;
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(void) {
			DtComparison* cmp = dt_comparison_new(pathA.fileSystemRepresentation, pathB.fileSystemRepresentation);
			dispatch_async(dispatch_get_main_queue(), ^(void) {
				DiffDocument* doc = weakSelf;
				if (!doc || doc->_generation != generation) {
					dt_comparison_free(cmp);
					return;
				}
				doc->_generation++;
				doc->_comparison = cmp;
				doc->_comparing = NO;
				[doc notifyWindowControllers];
			});
		});
	}
	[self notifyWindowControllers];
}

- (void) notifyWindowControllers {
	for (NSWindowController* controller in self.windowControllers) {
		if ([controller isKindOfClass:[DiffWindowController class]]) {
			[(DiffWindowController*)controller documentDidChange];
		}
	}
}

@end

#pragma mark - DiffDocumentController

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

#pragma mark - AppDelegate

static DiffDocumentController* g_document_controller = NULL;
static AppDelegate* g_app_delegate = NULL;

#define _(t,a,k) [[NSMenuItem alloc] initWithTitle:t action:a keyEquivalent:k]

static NSMenuItem* with_modifiers(NSMenuItem* item, NSEventModifierFlags modifiers) {
	item.keyEquivalentModifierMask = modifiers;
	return item;
}

static NSString* key_string(unichar c) {
	return [NSString stringWithCharacters:&c length:1];
}

static NSMenu* add_menu(NSMenu* mainMenu, NSString* title) {
	NSMenuItem* item = _(title, NULL, @"");
	[mainMenu addItem:item];
	NSMenu* menu = [[NSMenu alloc] initWithTitle:title];
	[item setSubmenu:menu];
	return menu;
}

static void build_main_menu(NSApplication* app) {
	NSMenu* mainMenu = [[NSMenu alloc] init];
	[app setMainMenu:mainMenu];

	NSString* up = key_string(NSUpArrowFunctionKey);
	NSString* down = key_string(NSDownArrowFunctionKey);
	NSEventModifierFlags command = NSEventModifierFlagCommand;
	NSEventModifierFlags shiftCommand = NSEventModifierFlagShift | NSEventModifierFlagCommand;

	/* App menu */ {
		NSMenu* appMenu = add_menu(mainMenu, @"Diff-o-tron");
		[appMenu addItem:_(@"About Diff-o-tron", @selector(showAboutPanel:), @"")];
		[appMenu addItem:[NSMenuItem separatorItem]];
		[appMenu addItem:_(@"Hide Diff-o-tron", @selector(hide:), @"h")];
		[appMenu addItem:with_modifiers(_(@"Hide Others", @selector(hideOtherApplications:), @"h"), NSEventModifierFlagCommand | NSEventModifierFlagOption)];
		[appMenu addItem:_(@"Show All", @selector(unhideAllApplications:), @"")];
		[appMenu addItem:[NSMenuItem separatorItem]];
		[appMenu addItem:_(@"Quit Diff-o-tron", @selector(terminate:), @"q")];
	}

	/* File menu */ {
		NSMenu* fileMenu = add_menu(mainMenu, @"File");
		[fileMenu addItem:_(@"New Window", @selector(newDocument:), @"n")];
		[fileMenu addItem:_(@"New Tab", @selector(newWindowForTab:), @"t")];
		[fileMenu addItem:_(@"Open…", @selector(openDocument:), @"o")];
		[fileMenu addItem:[NSMenuItem separatorItem]];
		[fileMenu addItem:_(@"Close", @selector(performClose:), @"w")];
	}

	/* Edit menu */ {
		NSMenu* editMenu = add_menu(mainMenu, @"Edit");
		[editMenu addItem:_(@"Undo", @selector(undo:), @"z")];
		[editMenu addItem:_(@"Redo", @selector(redo:), @"Z")];
		[editMenu addItem:[NSMenuItem separatorItem]];
		[editMenu addItem:_(@"Cut", @selector(cut:), @"x")];
		[editMenu addItem:_(@"Copy", @selector(copy:), @"c")];
		[editMenu addItem:_(@"Paste", @selector(paste:), @"v")];
		[editMenu addItem:_(@"Delete", @selector(delete:), @"")];
		[editMenu addItem:_(@"Select All", @selector(selectAll:), @"a")];
	}

	/* View menu */ {
		NSMenu* viewMenu = add_menu(mainMenu, @"View");
		[viewMenu addItem:_(@"Toggle Sidebar", @selector(toggleSidebar:), @"/")];
		[viewMenu addItem:with_modifiers(_(@"Enter Full Screen", @selector(toggleFullScreen:), @"f"), NSEventModifierFlagControl | NSEventModifierFlagCommand)];
		[viewMenu addItem:[NSMenuItem separatorItem]];
		[viewMenu addItem:with_modifiers(_(@"Select Previous File", @selector(selectPreviousFile:), up), shiftCommand)];
		[viewMenu addItem:with_modifiers(_(@"Select Next File", @selector(selectNextFile:), down), shiftCommand)];
		[viewMenu addItem:[NSMenuItem separatorItem]];
		[viewMenu addItem:_(@"Blocks", @selector(showBlocks:), @"1")];
		[viewMenu addItem:_(@"Fluid", @selector(showFluid:), @"2")];
		[viewMenu addItem:_(@"Unified", @selector(showUnified:), @"3")];
		[viewMenu addItem:[NSMenuItem separatorItem]];
		[viewMenu addItem:with_modifiers(_(@"Previous Change", @selector(previousChange:), up), command)];
		[viewMenu addItem:with_modifiers(_(@"Next Change", @selector(nextChange:), down), command)];
		[viewMenu addItem:[NSMenuItem separatorItem]];
		[viewMenu addItem:_(@"Increase Text Size", @selector(increaseTextSize:), @"+")];
		[viewMenu addItem:_(@"Decrease Text Size", @selector(decreaseTextSize:), @"-")];
		[viewMenu addItem:[NSMenuItem separatorItem]];
		[viewMenu addItem:with_modifiers(_(@"Wrap Lines", @selector(toggleWrapLines:), @"k"), shiftCommand)];
		[viewMenu addItem:with_modifiers(_(@"Ignore Whitespace", @selector(toggleIgnoreWhitespace:), @"'"), shiftCommand)];
	}

	/* Window menu */ {
		NSMenu* windowMenu = add_menu(mainMenu, @"Window");
		[app setWindowsMenu:windowMenu];
		[windowMenu addItem:_(@"Minimize", @selector(performMiniaturize:), @"m")];
		[windowMenu addItem:_(@"Zoom", @selector(performZoom:), @"")];
		[windowMenu addItem:[NSMenuItem separatorItem]];
		[windowMenu addItem:_(@"Bring All to Front", @selector(arrangeInFront:), @"")];
	}

	/* Help menu */ {
		NSMenu* helpMenu = add_menu(mainMenu, @"Help");
		[app setHelpMenu:helpMenu];
		[helpMenu addItem:_(@"Diff-o-tron Help", @selector(showHelp:), @"?")];
	}
}

@implementation AppDelegate

+ (int) start {
	NSApplication* app = [NSApplication sharedApplication];
	[app setActivationPolicy:NSApplicationActivationPolicyRegular];
	[NSApp activateIgnoringOtherApps:YES];

	/* The first document controller created becomes the shared one. */
	g_document_controller = [[DiffDocumentController alloc] init];

	g_app_delegate = [[AppDelegate alloc] init];
	if (!g_app_delegate) return 1;
	app.delegate = g_app_delegate;

	build_main_menu(app);
	[app run];

	return EXIT_SUCCESS;
}


- (BOOL) applicationShouldOpenUntitledFile:(NSApplication*)sender {
	return YES;
}

- (BOOL) applicationOpenUntitledFile:(NSApplication*)sender {
	[g_document_controller newDocument:nil];
	return YES;
}

/* The standard About panel, with the credits the licenses of the software built in require. */
- (IBAction) showAboutPanel:(id)sender {
	NSMutableDictionary* options = [NSMutableDictionary dictionary];
	NSURL* url = [[NSBundle mainBundle] URLForResource:@"Credits" withExtension:@"html"];
	NSData* data = url ? [NSData dataWithContentsOfURL:url] : nil;
	NSMutableAttributedString* credits = data ? [[NSMutableAttributedString alloc] initWithHTML:data documentAttributes:NULL] : nil;
	if (credits) {
		/* Text from HTML comes in black; follow the appearance instead. */
		[credits addAttribute:NSForegroundColorAttributeName value:[NSColor labelColor] range:NSMakeRange(0, credits.length)];
		options[NSAboutPanelOptionCredits] = credits;
	}
	[NSApp orderFrontStandardAboutPanelWithOptions:options];
}

- (BOOL) applicationSupportsSecureRestorableState:(NSApplication*)application {
	return YES; // Keeps macOS 12+ happy.
}

@end

int main(int argc, const char * argv[]) {
	@autoreleasepool {
		return [AppDelegate start];
	}
}
