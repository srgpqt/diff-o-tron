#import "DropView.h"

#import "Common.h"
#import "DiffWindowController.h"
#import "DropHighlightView.h"

#include <math.h>

static NSArray<NSURL*>* dragged_file_urls(id<NSDraggingInfo> info) {
	NSArray* urls = [info.draggingPasteboard
		readObjectsForClasses:@[[NSURL class]]
		options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
	return urls ? urls : @[];
}

@implementation DropView

/* The side a drag would replace: the half under it, or all sides when dragging several items. */
- (NSInteger) sideForDrag:(id<NSDraggingInfo>)info {
	NSUInteger count = dragged_file_urls(info).count;
	if (count == 0) return -1;
	if (count >= kSideCount) return (NSInteger)kSideCount;
	NSPoint point = [self convertPoint:info.draggingLocation fromView:nil];
	NSInteger side = (NSInteger)floor(point.x / (NSWidth(self.bounds) / (CGFloat)kSideCount));
	if (side < 0) side = 0;
	if (side >= (NSInteger)kSideCount) side = (NSInteger)kSideCount - 1;
	return side;
}

- (NSDragOperation) updateDrag:(id<NSDraggingInfo>)info {
	NSInteger side = [self sideForDrag:info];
	self.highlightView.side = side;
	return side < 0 ? NSDragOperationNone : NSDragOperationGeneric;
}

- (NSDragOperation) draggingEntered:(id<NSDraggingInfo>)info {
	return [self updateDrag:info];
}

- (NSDragOperation) draggingUpdated:(id<NSDraggingInfo>)info {
	return [self updateDrag:info];
}

- (void) draggingExited:(id<NSDraggingInfo>)info {
	self.highlightView.side = -1;
}

- (BOOL) performDragOperation:(id<NSDraggingInfo>)info {
	NSInteger side = [self sideForDrag:info];
	self.highlightView.side = -1;
	if (side < 0) return NO;
	[self.controller dropURLs:dragged_file_urls(info) side:side];
	return YES;
}

@end
