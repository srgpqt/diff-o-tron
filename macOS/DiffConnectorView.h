#import <Cocoa/Cocoa.h>

@class DiffView;

/* The gap after a side, joining its hunks to the next side's. */
@interface DiffConnectorView : NSView
	- (instancetype) initWithOwner:(DiffView*)owner side:(NSUInteger)side;
@end
