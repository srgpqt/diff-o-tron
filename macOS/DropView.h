#import <Cocoa/Cocoa.h>

@class DiffWindowController;
@class DropHighlightView;

/* Accepts files and folders dropped onto either half of it. */
@interface DropView : NSView
	@property (nonatomic, weak) DiffWindowController* controller;
	@property (nonatomic, weak) DropHighlightView* highlightView;
@end
