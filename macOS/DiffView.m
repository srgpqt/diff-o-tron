#import "DiffView+Private.h"

#import "DiffConnectorView.h"
#import "DiffGutterView.h"
#import "DiffPaneView.h"

#include <math.h>

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
NSColor* g_line_colors[4];
/* For the lines of the current hunk. */
NSColor* g_current_line_colors[4];
NSColor* g_emphasis_colors[4];
NSColor* g_edge_colors[4];
NSColor* g_filler_color;
NSColor* g_middle_color;

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
NSColor* line_color(uint8_t kind, BOOL inCurrentHunk) {
	return inCurrentHunk ? g_current_line_colors[kind] : g_line_colors[kind];
}

uint8_t hunk_kind(DtHunk hunk) {
	if (hunk.a_start == hunk.a_end) return DT_LINE_ADDED;
	if (hunk.b_start == hunk.b_end) return DT_LINE_REMOVED;
	return DT_LINE_CHANGED;
}

static const NSTimeInterval kFlashDuration = 0.4;

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

	/* How lit up the current hunk is, from 1 when it starts flashing down to 0. */
	CGFloat _flash;
	NSTimer* _flashTimer;
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
	[self setDiff:diff keepingPosition:NO];
}

- (void) setDiff:(DtFileDiff*)diff keepingPosition:(BOOL)keep {
	if (diff == _diff) return;
	ScrollAnchor anchor = keep ? [self scrollAnchor] : (ScrollAnchor){0, 0, 0, NO};
	/* Where the current hunk starts, in the current mode's rows, to find the nearest hunk in the new diff. */
	NSInteger hunkRow = -1;
	if (keep && _diff && _currentHunk >= 0 && (size_t)_currentHunk < dt_file_diff_hunk_count(_diff)) {
		DtHunk hunk = dt_file_diff_hunk(_diff, (size_t)_currentHunk);
		hunkRow = _mode == kDiffModeUnified ? hunk.unified_start : hunk.row_start;
	}

	dt_file_diff_free(_diff);
	_diff = diff;
	[_flashTimer invalidate];
	_flashTimer = nil;
	_flash = 0;
	_currentHunk = diff && dt_file_diff_hunk_count(diff) > 0 ? 0 : -1;
	if (hunkRow >= 0 && _currentHunk >= 0) {
		/* The first hunk that doesn't end before it, or else the last. */
		size_t count = dt_file_diff_hunk_count(diff);
		_currentHunk = (NSInteger)count - 1;
		for (size_t i = 0; i < count; i++) {
			DtHunk hunk = dt_file_diff_hunk(diff, i);
			if ((NSInteger)(_mode == kDiffModeUnified ? hunk.unified_end : hunk.row_end) > hunkRow) {
				_currentHunk = (NSInteger)i;
				break;
			}
		}
	}
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
	for (DiffPaneView* pane in _panes) [pane diffDidChange:!keep];
	[self restoreScrollAnchor:anchor];
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

- (BOOL) sideIsEmpty:(NSUInteger)side {
	return !_diff || dt_file_diff_line_count(_diff, (uint8_t)side) == 0;
}

- (void) drawSideHunks:(NSUInteger)side inRect:(NSRect)dirty offset:(CGFloat)offset {
	if ([self sideIsEmpty:side]) return;
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

- (void) flashCurrentHunk {
	[_flashTimer invalidate];
	NSTimeInterval start = [NSProcessInfo processInfo].systemUptime;
	_flash = 1;
	__weak DiffView* weakSelf = self;
	_flashTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer* timer) {
		DiffView* view = weakSelf;
		if (!view) {
			[timer invalidate];
			return;
		}
		/* Fading out fast, then slowly. */
		CGFloat elapsed = (CGFloat)(([NSProcessInfo processInfo].systemUptime - start) / kFlashDuration);
		view->_flash = elapsed < 1 ? (1 - elapsed) * (1 - elapsed) : 0;
		if (elapsed >= 1) {
			[timer invalidate];
			view->_flashTimer = nil;
		}
		[view redrawAll];
	}];
	[self redrawAll];
}

- (void) drawFlashForSide:(NSUInteger)side inRect:(NSRect)dirty offset:(CGFloat)offset {
	if (_flash <= 0 || !_diff || _currentHunk < 0 || (size_t)_currentHunk >= dt_file_diff_hunk_count(_diff)) return;
	if (_mode != kDiffModeUnified && [self sideIsEmpty:side]) return;
	DtHunk hunk = dt_file_diff_hunk(_diff, (size_t)_currentHunk);
	CGFloat top, bottom;
	if (_mode == kDiffModeUnified) {
		top = [self unifiedY:hunk.unified_start];
		bottom = [self unifiedY:hunk.unified_end];
	} else if (_mode == kDiffModeFluid) {
		uint32_t start, end;
		[self hunk:hunk side:side start:&start end:&end];
		top = [self lineY:start side:side];
		bottom = [self lineY:end side:side];
	} else {
		top = [self rowY:hunk.row_start];
		bottom = [self rowY:hunk.row_end];
	}
	top -= offset;
	bottom -= offset;
	/* A hunk with no lines on this side lights up the line where they'd be. */
	if (bottom - top < 2) {
		top -= 1;
		bottom = top + 2;
	}
	NSRect rect = NSIntersectionRect(NSMakeRect(NSMinX(dirty), top, NSWidth(dirty), bottom - top), dirty);
	if (NSIsEmptyRect(rect)) return;
	[[[NSColor controlAccentColor] colorWithAlphaComponent:0.35 * _flash] setFill];
	NSRectFillUsingOperation(rect, NSCompositingOperationSourceOver);
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
