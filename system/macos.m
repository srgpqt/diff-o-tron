#import <Cocoa/Cocoa.h>

#include <math.h>

#include "diffotron.h"

/*
 * The macOS front end: an NSDocument app where each document is a comparison of
 * two files or folders, shown in a window with the changed files in a sidebar
 * and the diff of the selected file beside it.
 */

static NSString* const kComparisonType = @"Comparison";

/* The number of compared sides; a merge will add a base and a result. */
static const NSUInteger kSideCount = 2;
static const uint32_t kTabWidth = 4;
static const CGFloat kHeaderHeight = 36;
static const CGFloat kBottomBarHeight = 32;

static NSString* dt_string(DtStr s) {
	NSString* string = [[NSString alloc] initWithBytes:s.ptr length:s.len encoding:NSUTF8StringEncoding];
	return string ? string : @"";
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
static NSColor* g_emphasis_colors[4];
static NSColor* g_edge_colors[4];
static NSColor* g_filler_color;
static NSColor* g_middle_color;
static NSColor* g_current_color;

static void init_colors(void) {
	g_line_colors[DT_LINE_CHANGED] = dynamic_color(0xECE8FD, 0x37324F);
	g_line_colors[DT_LINE_REMOVED] = dynamic_color(0xFCE6E6, 0x432729);
	g_line_colors[DT_LINE_ADDED] = dynamic_color(0xE3F5DC, 0x253A26);
	g_emphasis_colors[DT_LINE_CHANGED] = dynamic_color(0xCDC3F8, 0x55488F);
	g_emphasis_colors[DT_LINE_REMOVED] = dynamic_color(0xF5BDBD, 0x74393F);
	g_emphasis_colors[DT_LINE_ADDED] = dynamic_color(0xB9E6A8, 0x37663A);
	g_edge_colors[DT_LINE_CHANGED] = dynamic_color(0x9A8AE8, 0x7D6BD6);
	g_edge_colors[DT_LINE_REMOVED] = dynamic_color(0xE08080, 0xB0545C);
	g_edge_colors[DT_LINE_ADDED] = dynamic_color(0x7CC46A, 0x4F9A55);
	g_filler_color = dynamic_color(0xF4F4F6, 0x262628);
	g_middle_color = dynamic_color(0xF7F7F9, 0x232325);
	g_current_color = dynamic_color(0x8D7BEA, 0x6E5CCB);
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

/* Draws a file diff as aligned side-by-side panes. */
@interface DiffView : NSView
	/* Owned: freed when replaced. */
	@property (nonatomic) DtFileDiff* diff;
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
	- (NSURL*) urlForSide:(NSUInteger)side;
	- (void) setURL:(NSURL*)url forSide:(NSUInteger)side;
	/* Sets the sides from the first URLs. */
	- (void) setURLs:(NSArray<NSURL*>*)urls;
	- (BOOL) isEmpty;
@end

@interface DiffDocumentController : NSDocumentController
	- (void) openComparisonWithURLs:(NSArray<NSURL*>*)urls;
@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

#pragma mark - DiffView

static const CGFloat kTopPadding = 4;
static const CGFloat kMiddleWidth = 40;
static const CGFloat kGutterPadding = 8;
static const CGFloat kTextPadding = 8;

@implementation DiffView {
	NSFont* _font;
	NSDictionary* _textAttributes;
	NSDictionary* _numberAttributes;
	NSDictionary* _currentNumberAttributes;
	CGFloat _lineHeight;
	CGFloat _textInset;
	CGFloat _charWidth;
	CGFloat _gutterWidth;
	uint32_t _maxColumns;
	size_t _maxLines;
}

+ (void) initialize {
	if (self == [DiffView class]) init_colors();
}

- (instancetype) initWithFrame:(NSRect)frame {
	if ((self = [super initWithFrame:frame])) {
		_currentHunk = -1;
		self.fontSize = 12;
	}
	return self;
}

- (void) dealloc {
	dt_file_diff_free(_diff);
}

- (BOOL) isFlipped { return YES; }
- (BOOL) isOpaque { return YES; }
- (BOOL) acceptsFirstResponder { return YES; }

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

- (void) clipViewFrameDidChange:(NSNotification*)notification {
	[self relayout];
}

- (void) setDiff:(DtFileDiff*)diff {
	if (diff == _diff) return;
	dt_file_diff_free(_diff);
	_diff = diff;
	_currentHunk = diff && dt_file_diff_hunk_count(diff) > 0 ? 0 : -1;

	_maxColumns = 0;
	_maxLines = 0;
	for (NSUInteger side = 0; diff && side < kSideCount; side++) {
		size_t count = dt_file_diff_line_count(diff, (uint8_t)side);
		if (count > _maxLines) _maxLines = count;
		for (size_t i = 0; i < count; i++) {
			uint32_t columns = dt_file_diff_line(diff, (uint8_t)side, i).columns;
			if (columns > _maxColumns) _maxColumns = columns;
		}
	}

	[self relayout];
	[self scrollPoint:NSZeroPoint];
	[self setNeedsDisplay:YES];
}

- (void) setFontSize:(CGFloat)fontSize {
	_fontSize = fontSize;
	_font = [NSFont monospacedSystemFontOfSize:fontSize weight:NSFontWeightRegular];
	NSLayoutManager* layoutManager = [[NSLayoutManager alloc] init];
	CGFloat fontLineHeight = [layoutManager defaultLineHeightForFont:_font];
	_lineHeight = ceil(fontLineHeight * 1.3);
	_textInset = floor((_lineHeight - fontLineHeight) / 2);
	_charWidth = [@"0" sizeWithAttributes:@{NSFontAttributeName: _font}].width;

	NSMutableParagraphStyle* paragraph = [[NSMutableParagraphStyle alloc] init];
	paragraph.tabStops = @[];
	paragraph.defaultTabInterval = _charWidth * kTabWidth;
	paragraph.lineBreakMode = NSLineBreakByClipping;
	_textAttributes = @{
		NSFontAttributeName: _font,
		NSForegroundColorAttributeName: [NSColor textColor],
		NSParagraphStyleAttributeName: paragraph
	};
	NSFont* numberFont = [NSFont monospacedDigitSystemFontOfSize:fontSize weight:NSFontWeightRegular];
	_numberAttributes = @{
		NSFontAttributeName: numberFont,
		NSForegroundColorAttributeName: [NSColor secondaryLabelColor]
	};
	_currentNumberAttributes = @{
		NSFontAttributeName: numberFont,
		NSForegroundColorAttributeName: [NSColor whiteColor]
	};

	[self relayout];
	[self setNeedsDisplay:YES];
}

- (void) setCurrentHunk:(NSInteger)currentHunk {
	_currentHunk = currentHunk;
	[self setNeedsDisplay:YES];
}

/* Size the view to fit its rows and its widest line, and at least fill the scroll view. */
- (void) relayout {
	NSSize visible = self.enclosingScrollView ? self.enclosingScrollView.contentSize : self.frame.size;
	size_t rows = _diff ? dt_file_diff_row_count(_diff) : 0;

	int digits = 3;
	for (size_t n = _maxLines; n >= 1000; n /= 10) digits++;
	CGFloat digitWidth = [@"0" sizeWithAttributes:_numberAttributes].width;
	_gutterWidth = ceil(digits * digitWidth + 2 * kGutterPadding);

	CGFloat pane = _gutterWidth + 2 * kTextPadding + (CGFloat)_maxColumns * _charWidth;
	CGFloat width = fmax(visible.width, (CGFloat)kSideCount * pane + (CGFloat)(kSideCount - 1) * kMiddleWidth);
	CGFloat height = fmax(visible.height, 2 * kTopPadding + (CGFloat)rows * _lineHeight);
	[self setFrameSize:NSMakeSize(floor(width), ceil(height))];
	[self setNeedsDisplay:YES];
}

- (CGFloat) paneWidth {
	return floor((NSWidth(self.bounds) - (CGFloat)(kSideCount - 1) * kMiddleWidth) / (CGFloat)kSideCount);
}

- (CGFloat) paneX:(NSUInteger)side {
	return (CGFloat)side * ([self paneWidth] + kMiddleWidth);
}

- (CGFloat) rowY:(size_t)row {
	return kTopPadding + (CGFloat)row * _lineHeight;
}

- (void) drawRect:(NSRect)dirty {
	[[NSColor textBackgroundColor] setFill];
	NSRectFill(dirty);
	if (!_diff) return;

	CGFloat paneWidth = [self paneWidth];
	for (NSUInteger side = 0; side + 1 < kSideCount; side++) {
		[g_middle_color setFill];
		NSRect middle = NSMakeRect([self paneX:side] + paneWidth, 0, kMiddleWidth, NSHeight(self.bounds));
		NSRectFill(NSIntersectionRect(middle, dirty));
	}

	size_t rowCount = dt_file_diff_row_count(_diff);
	size_t hunkCount = dt_file_diff_hunk_count(_diff);
	CGFloat firstY = NSMinY(dirty) - kTopPadding;
	size_t first = firstY > 0 ? (size_t)floor(firstY / _lineHeight) : 0;
	size_t last = (size_t)fmax(0, ceil((NSMaxY(dirty) - kTopPadding) / _lineHeight));
	if (last > rowCount) last = rowCount;

	DtHunk current = {0};
	BOOL hasCurrent = _currentHunk >= 0 && (size_t)_currentHunk < hunkCount;
	if (hasCurrent) current = dt_file_diff_hunk(_diff, (size_t)_currentHunk);

	for (size_t row = first; row < last; row++) {
		BOOL inCurrent = hasCurrent && row >= current.row_start && row < current.row_end;
		for (NSUInteger side = 0; side < kSideCount; side++) {
			int32_t lineIndex = dt_file_diff_row_line(_diff, row, (uint8_t)side);
			NSRect frame = NSMakeRect([self paneX:side], [self rowY:row], paneWidth, _lineHeight);
			[self drawLine:lineIndex side:side frame:frame current:inCurrent];
		}
	}

	/* Hunk outlines, and bands joining the panes across the middle gutters. */
	for (size_t i = 0; i < hunkCount; i++) {
		DtHunk hunk = dt_file_diff_hunk(_diff, i);
		CGFloat top = [self rowY:hunk.row_start];
		CGFloat bottom = [self rowY:hunk.row_end];
		if (bottom < NSMinY(dirty) - 1 || top > NSMaxY(dirty) + 1) continue;
		uint8_t kind = hunk_kind(hunk);
		[g_line_colors[kind] setFill];
		for (NSUInteger side = 0; side + 1 < kSideCount; side++) {
			NSRectFill(NSMakeRect([self paneX:side] + paneWidth, top, kMiddleWidth, bottom - top));
		}
		[g_edge_colors[kind] setFill];
		NSRectFill(NSMakeRect(0, top, NSWidth(self.bounds), 1));
		NSRectFill(NSMakeRect(0, bottom - 1, NSWidth(self.bounds), 1));
	}
}

- (void) drawLine:(int32_t)lineIndex side:(NSUInteger)side frame:(NSRect)frame current:(BOOL)current {
	if (lineIndex < 0) {
		[g_filler_color setFill];
		NSRectFill(frame);
		return;
	}

	DtLine line = dt_file_diff_line(_diff, (uint8_t)side, (size_t)lineIndex);
	BOOL changed = line.kind != DT_LINE_EQUAL && line.kind < 4;
	if (changed) {
		[g_line_colors[line.kind] setFill];
		NSRectFill(frame);
	}

	NSRect gutter = NSMakeRect(NSMinX(frame), NSMinY(frame), _gutterWidth, NSHeight(frame));
	if (current && changed) {
		[g_current_color setFill];
		NSRectFill(gutter);
	}
	NSDictionary* numberAttributes = current && changed ? _currentNumberAttributes : _numberAttributes;
	NSString* number = [NSString stringWithFormat:@"%ld", (long)lineIndex + 1];
	NSSize numberSize = [number sizeWithAttributes:numberAttributes];
	NSPoint numberPoint = NSMakePoint(NSMaxX(gutter) - kGutterPadding - numberSize.width, NSMinY(frame) + _textInset);
	[number drawAtPoint:numberPoint withAttributes:numberAttributes];

	NSString* text = dt_string(line.text);
	if (text.length == 0) return;
	NSMutableAttributedString* string = [[NSMutableAttributedString alloc] initWithString:text attributes:_textAttributes];
	for (uint32_t i = 0; changed && i < line.span_count; i++) {
		DtSpan span = line.spans[i];
		if (span.start16 >= span.end16 || span.end16 > text.length) continue;
		[string
			addAttribute:NSBackgroundColorAttributeName
			value:g_emphasis_colors[line.kind]
			range:NSMakeRange(span.start16, span.end16 - span.start16)];
	}

	NSRect textFrame = NSMakeRect(
		NSMaxX(gutter) + kTextPadding, NSMinY(frame),
		NSWidth(frame) - _gutterWidth - kTextPadding, NSHeight(frame));
	[NSGraphicsContext saveGraphicsState];
	NSRectClip(textFrame);
	[string drawAtPoint:NSMakePoint(NSMinX(textFrame), NSMinY(frame) + _textInset)];
	[NSGraphicsContext restoreGraphicsState];
}

- (void) mouseDown:(NSEvent*)event {
	[self.window makeFirstResponder:self];
	if (!_diff) return;
	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	if (point.y < kTopPadding) return;
	size_t row = (size_t)floor((point.y - kTopPadding) / _lineHeight);
	size_t count = dt_file_diff_hunk_count(_diff);
	for (size_t i = 0; i < count; i++) {
		DtHunk hunk = dt_file_diff_hunk(_diff, i);
		if (row >= hunk.row_start && row < hunk.row_end) {
			self.currentHunk = (NSInteger)i;
			if (_currentHunkChanged) _currentHunkChanged();
			return;
		}
	}
}

/* Scroll the current hunk to a third of the way down, unless it's already in view. */
- (void) scrollToCurrentHunk {
	if (!_diff || _currentHunk < 0 || (size_t)_currentHunk >= dt_file_diff_hunk_count(_diff)) return;
	DtHunk hunk = dt_file_diff_hunk(_diff, (size_t)_currentHunk);
	CGFloat top = [self rowY:hunk.row_start];
	CGFloat bottom = [self rowY:hunk.row_end];
	NSRect visible = self.visibleRect;
	if (top >= NSMinY(visible) && bottom <= NSMaxY(visible)) return;
	CGFloat y = fmax(0, top - floor(NSHeight(visible) / 3));
	[self scrollPoint:NSMakePoint(NSMinX(visible), y)];
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
	NSScrollView* diffScroll = [[NSScrollView alloc] init];
	diffScroll.hasVerticalScroller = YES;
	diffScroll.hasHorizontalScroller = YES;
	diffScroll.autohidesScrollers = YES;
	diffScroll.documentView = _diffView;

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
	NSStackView* bar = [[NSStackView alloc] init];
	bar.edgeInsets = NSEdgeInsetsMake(0, 12, 0, 12);
	[bar addView:_whitespaceCheckbox inGravity:NSStackViewGravityLeading];
	[bar addView:_changeLabel inGravity:NSStackViewGravityTrailing];
	[bar addView:_previousButton inGravity:NSStackViewGravityTrailing];
	[bar addView:_nextButton inGravity:NSStackViewGravityTrailing];

	_highlight = [[DropHighlightView alloc] initWithFrame:NSZeroRect];
	detail.highlightView = _highlight;

	add_subviews(detail, @[titles[0], titles[1], topSeparator, diffScroll, _message, bottomSeparator, bar, _highlight]);
	[NSLayoutConstraint activateConstraints:@[
		/* Each title over its pane, as DiffView lays them out when not scrolled sideways. */
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

		[diffScroll.topAnchor constraintEqualToAnchor:topSeparator.bottomAnchor],
		[diffScroll.leadingAnchor constraintEqualToAnchor:detail.leadingAnchor],
		[diffScroll.trailingAnchor constraintEqualToAnchor:detail.trailingAnchor],
		[diffScroll.bottomAnchor constraintEqualToAnchor:bottomSeparator.topAnchor],

		[_message.centerXAnchor constraintEqualToAnchor:diffScroll.centerXAnchor],
		[_message.centerYAnchor constraintEqualToAnchor:diffScroll.centerYAnchor],
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
	window.initialFirstResponder = _table;

	[self updateChangeLabel];
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
	DtComparison* cmp = [self diffDocument].comparison;
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
			if (path.length == 0) {
				name = @"Not present";
			} else if (dir.length > 0) {
				dir = [dir stringByReplacingOccurrencesOfString:@"/" withString:@" › "];
				name = [NSString stringWithFormat:@"%@ › %@", dir, path.lastPathComponent];
			} else {
				name = path.lastPathComponent;
			}
		} else {
			NSURL* url = [doc urlForSide:side];
			if (url) name = url.lastPathComponent;
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
	[_diffView scrollToCurrentHunk];
}

- (BOOL) validateMenuItem:(NSMenuItem*)menuItem {
	SEL action = menuItem.action;
	if (action == @selector(toggleIgnoreWhitespace:)) {
		menuItem.state = _ignoreWhitespace ? NSControlStateValueOn : NSControlStateValueOff;
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
}

- (instancetype) init {
	if ((self = [super init])) {
		_urls = [NSMutableArray array];
		for (NSUInteger side = 0; side < kSideCount; side++) [_urls addObject:[NSNull null]];
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

- (NSString*) displayName {
	NSURL* a = [self urlForSide:0];
	NSURL* b = [self urlForSide:1];
	if (a && b) {
		if ([a.lastPathComponent isEqualToString:b.lastPathComponent]) return a.lastPathComponent;
		return [NSString stringWithFormat:@"%@ ↔ %@", a.lastPathComponent, b.lastPathComponent];
	}
	if (a || b) return (a ? a : b).lastPathComponent;
	return @"New Comparison";
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
	[self urlsDidChange];
}

- (void) setURLs:(NSArray<NSURL*>*)urls {
	for (NSUInteger side = 0; side < kSideCount && side < urls.count; side++) _urls[side] = path_url(urls[side]);
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

@implementation DiffDocumentController

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
		if (result == NSModalResponseOK) [self openComparisonWithURLs:panel.URLs];
	}];
}

/* Compare the URLs in the frontmost window if it's empty, or else in a new one. */
- (void) openComparisonWithURLs:(NSArray<NSURL*>*)urls {
	if (urls.count == 0) return;
	DiffDocument* doc = nil;
	NSDocument* current = self.currentDocument;
	if ([current isKindOfClass:[DiffDocument class]] && [(DiffDocument*)current isEmpty]) {
		doc = (DiffDocument*)current;
	} else {
		NSError* error = nil;
		doc = [self openUntitledDocumentAndDisplay:YES error:&error];
		if (!doc) {
			if (error) [self presentError:error];
			return;
		}
	}
	[doc setURLs:urls];
	[doc showWindows];
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
		[appMenu addItem:_(@"About Diff-o-tron", @selector(orderFrontStandardAboutPanel:), @"")];
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
		[viewMenu addItem:with_modifiers(_(@"Previous Change", @selector(previousChange:), up), command)];
		[viewMenu addItem:with_modifiers(_(@"Next Change", @selector(nextChange:), down), command)];
		[viewMenu addItem:[NSMenuItem separatorItem]];
		[viewMenu addItem:_(@"Increase Text Size", @selector(increaseTextSize:), @"+")];
		[viewMenu addItem:_(@"Decrease Text Size", @selector(decreaseTextSize:), @"-")];
		[viewMenu addItem:[NSMenuItem separatorItem]];
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

/* Files and folders opened from the Finder, the Dock, or `open -a`. */
- (void) application:(NSApplication*)application openURLs:(NSArray<NSURL*>*)urls {
	[g_document_controller openComparisonWithURLs:urls];
}

- (BOOL) applicationShouldOpenUntitledFile:(NSApplication*)sender {
	return YES;
}

- (BOOL) applicationOpenUntitledFile:(NSApplication*)sender {
	[g_document_controller newDocument:nil];
	return YES;
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
