#import "DiffGutterView.h"

#import "DiffView+Private.h"

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
		[owner drawFlashForSide:_side inRect:dirty offset:offset];
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
		[owner drawFlashForSide:_side inRect:dirty offset:offset];
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
	if (![owner sideIsEmpty:_side]) [owner drawHunksInRect:dirty offset:offset bands:NO];
	[owner drawFlashForSide:_side inRect:dirty offset:offset];
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
