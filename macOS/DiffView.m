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

NSColor* g_line_colors[kKindCount];
NSColor* g_current_line_colors[kKindCount];
NSColor* g_emphasis_colors[kKindCount];
NSColor* g_edge_colors[kKindCount];
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
	g_line_colors[DT_LINE_CONFLICT] = dynamic_color(0xFFEBD6, 0x4A3320);
	g_current_line_colors[DT_LINE_CONFLICT] = dynamic_color(0xFCDCBC, 0x5A3D22);
	g_emphasis_colors[DT_LINE_CONFLICT] = dynamic_color(0xF7C08C, 0x7A5130);
	g_edge_colors[DT_LINE_CONFLICT] = dynamic_color(0xF0A050, 0xC07830);
	g_filler_color = dynamic_color(0xF4F4F6, 0x262628);
	g_middle_color = dynamic_color(0xF7F7F9, 0x232325);
}

/* The background of a changed line, or the band joining a hunk across sides. */
NSColor* line_color(uint8_t kind, BOOL inCurrentHunk) {
	return inCurrentHunk ? g_current_line_colors[kind] : g_line_colors[kind];
}


static const NSTimeInterval kFlashDuration = 0.4;

@implementation DiffView {
	NSArray<NSScrollView*>* _scrolls;
	NSArray<DiffPaneView*>* _panes;
	NSArray<DiffGutterView*>* _gutters;
	NSArray<DiffConnectorView*>* _connectors;
	size_t _maxLines;
	BOOL _syncingScroll;

	/* Where the lines and rows are, and Fluid mode's scrolling. Never NULL. */
	DtLayout* _layout;
	/* The width lines are wrapped to, or 0 when they aren't. */
	CGFloat _wrapWidth;
	BOOL _layingOut;

	/* How lit up the current hunk is, from 1 when it starts flashing down to 0. */
	CGFloat _flash;
	NSTimer* _flashTimer;

	/* Set while scrolling for the wheel, so as not to take that as scrolling the shared layout. */
	BOOL _wheeling;
	/* While the sides glide into line in Fluid mode, gliding them a frame at a time. */
	NSTimer* _glideTimer;
	NSTimeInterval _glideTime;
}

+ (void) initialize {
	if (self == [DiffView class]) init_colors();
}

- (instancetype) initWithFrame:(NSRect)frame {
	if ((self = [super initWithFrame:frame])) {
		clip_to_bounds(self);
		_currentHunk = -1;
		_layout = dt_layout_new(NULL, NULL, kTopPadding, 0);
		NSMutableArray* scrolls = [NSMutableArray array];
		NSMutableArray* panes = [NSMutableArray array];
		NSMutableArray* gutters = [NSMutableArray array];
		NSMutableArray* connectors = [NSMutableArray array];
		_sideCount = kSideCount;
		/* Views for as many sides as a diff can have; those it doesn't are hidden. */
		for (NSUInteger side = 0; side < kMaxSides; side++) {
			DiffPaneView* pane = [[DiffPaneView alloc] initWithOwner:self side:side];
			NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
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
			if (side + 1 < kMaxSides) {
				DiffConnectorView* connector = [[DiffConnectorView alloc] initWithOwner:self side:side];
				[self addSubview:connector];
				[connectors addObject:connector];
			}
		}
		_scrolls = scrolls;
		_panes = panes;
		_gutters = gutters;
		_connectors = connectors;
		[self updateSideViews];
		self.fontSize = kDefaultFontSize;
	}
	return self;
}

/* Show the views of the sides there are: just side A's in Unified mode, which shows both. */
- (void) updateSideViews {
	NSUInteger shown = _mode == kDiffModeUnified ? 1 : _sideCount;
	for (NSUInteger side = 0; side < kMaxSides; side++) {
		_gutters[side].hidden = side >= shown;
		_scrolls[side].hidden = side >= shown;
		/* One vertical scroller, at the far right, for all the sides. */
		_scrolls[side].hasVerticalScroller = side + 1 == shown;
	}
	for (NSUInteger side = 0; side < _connectors.count; side++) _connectors[side].hidden = side + 1 >= shown;
	[self layoutSides];
}

- (void) dealloc {
	[_glideTimer invalidate];
	dt_layout_free(_layout);
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
	CGFloat share = floor((NSWidth(bounds) - (CGFloat)(_sideCount - 1) * kMiddleWidth) / (CGFloat)_sideCount);
	CGFloat x = 0;
	for (NSUInteger side = 0; side < _sideCount; side++) {
		CGFloat width = side + 1 == _sideCount ? NSWidth(bounds) - x : share;
		CGFloat gutter = fmin(_gutterWidth, width);
		_gutters[side].frame = NSMakeRect(x, 0, gutter, NSHeight(bounds));
		_scrolls[side].frame = NSMakeRect(x + gutter, 0, width - gutter, NSHeight(bounds));
		x += width;
		if (side + 1 < _sideCount) {
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
	DtScrollAnchor anchor = keep ? [self scrollAnchor] : (DtScrollAnchor){0, 0, 0, false};
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
	_sideCount = diff ? dt_file_diff_side_count(diff) : kSideCount;
	[self updateSideViews];
	_maxLines = 0;
	_maxColumns = 0;
	for (NSUInteger side = 0; diff && side < _sideCount; side++) {
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
	NSUInteger sides = _mode == kDiffModeUnified ? 1 : _sideCount;
	CGFloat width = CGFLOAT_MAX;
	for (NSUInteger side = 0; side < sides; side++) width = fmin(width, _scrolls[side].contentSize.width);
	/* At least a few characters, while the views are still being sized. */
	return fmax(width - 2 * kTextPadding, 8 * _charWidth);
}

/* Lay out the lines again, keeping what's in view where it is. */
- (void) relayoutLines {
	DtScrollAnchor anchor = [self scrollAnchor];
	[self layoutLines];
	for (DiffPaneView* pane in _panes) [pane relayout];
	[self restoreScrollAnchor:anchor];
	[self redrawAll];
}

/*
 * What to keep in place on the screen while the layout changes: the current
 * hunk if it's in view, or else the point in the middle of the view.
 */
- (DtScrollAnchor) scrollAnchor {
	NSRect visible = _scrolls[0].contentView.bounds;
	return dt_layout_anchor(_layout, [self modeTable], _currentHunk, NSMinY(visible), NSHeight(visible));
}

- (void) restoreScrollAnchor:(DtScrollAnchor)anchor {
	if (!anchor.valid) return;
	DiffPaneView* pane = _panes[0];
	[pane scrollPoint:NSMakePoint(NSMinX(pane.visibleRect), dt_layout_anchor_top(_layout, [self modeTable], anchor))];
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

/* Lay out every line for the current mode's wrap width. */
- (void) layoutLines {
	[self stopGliding];
	_wrapWidth = [self currentWrapWidth];
	/* How tall each line is, for every side views can show: those the diff hasn't, none. */
	size_t counts[DT_MAX_SIDES];
	size_t total = 0;
	for (NSUInteger side = 0; side < kMaxSides; side++) {
		counts[side] = _diff ? dt_file_diff_line_count(_diff, (uint8_t)side) : 0;
		total += counts[side];
	}
	double* heights = malloc((total > 0 ? total : 1) * sizeof(double));
	if (!heights) abort();
	const double* lineHeights[DT_MAX_SIDES];
	double* next = heights;
	for (NSUInteger side = 0; side < kMaxSides; side++) {
		for (size_t i = 0; i < counts[side]; i++) next[i] = [self heightOfLine:i side:side];
		lineHeights[side] = next;
		next += counts[side];
	}
	dt_layout_free(_layout);
	_layout = dt_layout_new(_diff, lineHeights, kTopPadding, _lineHeight);
	free(heights);
}

- (CGFloat) rowY:(size_t)row {
	return dt_layout_y(_layout, DT_TABLE_ROWS, row);
}

- (CGFloat) lineY:(size_t)line side:(NSUInteger)side {
	return dt_layout_y(_layout, (uint8_t)side, line);
}

- (CGFloat) unifiedY:(size_t)row {
	return dt_layout_y(_layout, DT_TABLE_UNIFIED, row);
}

- (NSInteger) rowAtY:(CGFloat)y {
	return dt_layout_index_at(_layout, DT_TABLE_ROWS, y);
}

- (NSInteger) lineAtY:(CGFloat)y side:(NSUInteger)side {
	return dt_layout_index_at(_layout, (uint8_t)side, y);
}

- (NSInteger) unifiedRowAtY:(CGFloat)y {
	return dt_layout_index_at(_layout, DT_TABLE_UNIFIED, y);
}

- (void) rowsFrom:(CGFloat)top to:(CGFloat)bottom first:(size_t*)first last:(size_t*)last {
	dt_layout_range(_layout, DT_TABLE_ROWS, top, bottom, first, last);
}

- (void) linesFrom:(CGFloat)top to:(CGFloat)bottom side:(NSUInteger)side first:(size_t*)first last:(size_t*)last {
	dt_layout_range(_layout, (uint8_t)side, top, bottom, first, last);
}

- (void) unifiedRowsFrom:(CGFloat)top to:(CGFloat)bottom first:(size_t*)first last:(size_t*)last {
	dt_layout_range(_layout, DT_TABLE_UNIFIED, top, bottom, first, last);
}

/* The layout's table of the current mode's rows. */
- (uint8_t) modeTable {
	return _mode == kDiffModeUnified ? DT_TABLE_UNIFIED : DT_TABLE_ROWS;
}

- (CGFloat) contentBottom {
	return dt_layout_bottom(_layout, [self modeTable]);
}

- (CGFloat) verticalOffset:(NSUInteger)side {
	return _scrolls[side].contentView.bounds.origin.y;
}

- (void) hunk:(DtHunk)hunk side:(NSUInteger)side start:(uint32_t*)start end:(uint32_t*)end {
	*start = side < kMaxSides ? hunk.start[side] : 0;
	*end = side < kMaxSides ? hunk.end[side] : 0;
}

- (CGFloat) shift:(NSUInteger)side {
	if (_mode != kDiffModeFluid || !_diff) return 0;
	CGFloat y = [self verticalOffset:side];
	return dt_layout_fluid_top(_layout, (uint8_t)side, y, NSHeight(_scrolls[side].contentView.bounds)) - y;
}

/*
 * Scroll for a wheel over a side. In Fluid mode, the side's own layout moves with
 * the wheel, and the other sides keep up with it; otherwise every side scrolls the same.
 */
- (void) scrollWheel:(NSEvent*)event side:(NSUInteger)side {
	NSScrollView* scroll = _scrolls[side];
	if (_mode != kDiffModeFluid || !_diff || side >= _sideCount) {
		[scroll scrollWheel:event];
		return;
	}
	CGFloat dx = event.scrollingDeltaX;
	CGFloat dy = event.scrollingDeltaY;
	if (!event.hasPreciseScrollingDeltas) {
		dx *= _lineHeight;
		dy *= _lineHeight;
	}
	if (fabs(dx) < 0.01 && fabs(dy) < 0.01) return;

	NSClipView* clip = scroll.contentView;
	NSRect bounds = clip.bounds;
	CGFloat maxX = fmax(NSWidth(_panes[side].frame) - NSWidth(bounds), 0);
	CGFloat x = fmin(fmax(NSMinX(bounds) - dx, 0), maxX);
	CGFloat y = NSMinY(bounds);
	if (fabs(dy) >= 0.01) {
		CGFloat pointer = [_panes[side] convertPoint:event.locationInWindow fromView:nil].y - NSMinY(bounds);
		y = dt_layout_fluid_scroll(_layout, (uint8_t)side, -dy, pointer, y, NSHeight(bounds));
	}
	_wheeling = YES;
	[clip scrollToPoint:NSMakePoint(x, y)];
	[scroll reflectScrolledClipView:clip];
	_wheeling = NO;
	if (dt_layout_fluid_gliding(_layout)) [self startGliding];
	[self redrawAll];
	/* Show the scroller, as scrolling does. */
	if (event.phase == NSEventPhaseBegan || !event.hasPreciseScrollingDeltas) [_scrolls[_sideCount - 1] flashScrollers];
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
		uint8_t kind = hunk.kind;
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
		[g_edge_colors[hunk.kind] setFill];
		if (previousEnd != start) NSRectFill(NSMakeRect(NSMinX(dirty), top, NSWidth(dirty), 1));
		if (bottom - top >= 2) NSRectFill(NSMakeRect(NSMinX(dirty), bottom - 1, NSWidth(dirty), 1));
	}
}

/* Scroll every side up and down with whichever one scrolled. */
- (void) clipViewBoundsDidChange:(NSNotification*)notification {
	NSClipView* source = notification.object;
	/* Scrolled some other way than by the wheel, as by the scroller: the sides line up with the shared layout again. */
	if (_mode == kDiffModeFluid && !_wheeling) {
		dt_layout_fluid_scrolled(_layout, source.bounds.origin.y, NSHeight(source.bounds));
		if (dt_layout_fluid_gliding(_layout)) [self startGliding];
	}
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
	[self updateSideViews];
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
	[self selectHunk:dt_layout_hunk_at(_layout, DT_TABLE_UNIFIED, row)];
}

- (void) selectHunkAtRow:(size_t)row {
	[self selectHunk:dt_layout_hunk_at(_layout, DT_TABLE_ROWS, row)];
}

- (void) selectHunkAtLine:(size_t)line side:(NSUInteger)side {
	[self selectHunk:dt_layout_hunk_at(_layout, (uint8_t)side, line)];
}

/* Make a hunk clicked current, if it's one. */
- (void) selectHunk:(NSInteger)hunk {
	if (hunk < 0) return;
	self.currentHunk = hunk;
	if (_currentHunkChanged) _currentHunkChanged();
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

/* Glide the sides into line, a frame at a time, until they are. */
- (void) startGliding {
	if (_glideTimer) return;
	_glideTime = [NSProcessInfo processInfo].systemUptime;
	__weak DiffView* weakSelf = self;
	_glideTimer = [NSTimer timerWithTimeInterval:1.0 / 120 repeats:YES block:^(NSTimer* timer) {
		DiffView* view = weakSelf;
		if (view) {
			[view glide];
		} else {
			[timer invalidate];
		}
	}];
	/* Also while the scroller is dragged. */
	[[NSRunLoop currentRunLoop] addTimer:_glideTimer forMode:NSRunLoopCommonModes];
}

- (void) glide {
	NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
	double elapsed = now - _glideTime;
	_glideTime = now;
	if (!dt_layout_fluid_glide(_layout, elapsed)) [self stopGliding];
	for (NSView* view in _panes) [view setNeedsDisplay:YES];
	for (NSView* view in _gutters) [view setNeedsDisplay:YES];
	for (NSView* view in _connectors) [view setNeedsDisplay:YES];
}

/* Stop gliding the sides, as when they're laid out anew, lined up. */
- (void) stopGliding {
	[_glideTimer invalidate];
	_glideTimer = nil;
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
	if (_currentHunk < 0) return;
	DiffPaneView* pane = _panes[0];
	NSRect visible = pane.visibleRect;
	double y = 0;
	if (dt_layout_scroll_to_hunk(_layout, [self modeTable], (size_t)_currentHunk, NSMinY(visible), NSHeight(visible), &y)) {
		[pane scrollPoint:NSMakePoint(NSMinX(visible), y)];
	}
}

@end
