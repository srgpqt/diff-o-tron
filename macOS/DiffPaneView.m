#import "DiffPaneView.h"

#import "DiffView+Private.h"

#include <math.h>

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

- (void) diffDidChange:(BOOL)scrollToTop {
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
	if (scrollToTop) [self scrollPoint:NSZeroPoint];
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
		[owner drawFlashForSide:_side inRect:dirty offset:0];
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
		[owner drawFlashForSide:_side inRect:dirty offset:shift];
		return;
	}

	[owner rowsFrom:NSMinY(dirty) to:NSMaxY(dirty) first:&first last:&last];
	for (size_t row = first; row < last; row++) {
		CGFloat top = [owner rowY:row];
		NSRect frame = NSMakeRect(0, top, width, [owner rowY:row + 1] - top);
		int32_t line = dt_file_diff_row_line(owner.diff, row, (uint8_t)_side);
		[self drawLine:line side:_side selectionLine:line frame:frame current:[owner rowInCurrentHunk:row]];
	}
	if (![owner sideIsEmpty:_side]) [owner drawHunksInRect:dirty offset:0 bands:NO];
	[owner drawFlashForSide:_side inRect:dirty offset:0];
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
	BOOL changed = line.kind != DT_LINE_EQUAL && line.kind < kKindCount;
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
