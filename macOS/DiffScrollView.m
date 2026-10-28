#import "DiffScrollView.h"

#import "DiffView+Private.h"

@implementation DiffScrollView {
	__weak DiffView* _owner;
	NSUInteger _side;
}

- (instancetype) initWithOwner:(DiffView*)owner side:(NSUInteger)side {
	if ((self = [super initWithFrame:NSZeroRect])) {
		_owner = owner;
		_side = side;
	}
	return self;
}

- (void) scrollWheel:(NSEvent*)event {
	if (![_owner scrollWheel:event side:_side]) [super scrollWheel:event];
}

@end
