#import <Cocoa/Cocoa.h>

@class DiffView;

/* One side's line numbers, which stay put when the side scrolls sideways. */
@interface DiffGutterView : NSView
	- (instancetype) initWithOwner:(DiffView*)owner side:(NSUInteger)side;
@end
