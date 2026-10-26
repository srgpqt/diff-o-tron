#import "DropHighlightView.h"

#import "Common.h"

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
