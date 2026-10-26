#import <Cocoa/Cocoa.h>

/* Shows where a drag will drop; transparent to the mouse. */
@interface DropHighlightView : NSView
	/* -1 for none, a side, or kSideCount for all sides. */
	@property (nonatomic) NSInteger side;
@end
