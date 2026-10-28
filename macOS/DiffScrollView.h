#import <Cocoa/Cocoa.h>

@class DiffView;

/*
 * One side's scroll view, which in Fluid mode leaves its wheel's scrolling to its
 * DiffView. AppKit sends a trackpad gesture's scrolling, its momentum too, to the
 * scroll view it started in, rather than through the view under the pointer.
 */
@interface DiffScrollView : NSScrollView
	- (instancetype) initWithOwner:(DiffView*)owner side:(NSUInteger)side;
@end
