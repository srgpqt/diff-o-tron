#import "DiffConnectorView.h"

#import "DiffView+Private.h"

#include <math.h>

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
	/* Nothing to join to a side with no lines. */
	if ([owner sideIsEmpty:_side] || [owner sideIsEmpty:_side + 1]) return;
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
