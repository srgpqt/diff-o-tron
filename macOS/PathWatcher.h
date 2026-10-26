#import <Cocoa/Cocoa.h>

/* How long to gather changes on disk for before reloading. */
static const NSTimeInterval kReloadDelay = 0.3;

/* Calls a block when a file, or anything in a folder, changes on disk. */
@interface PathWatcher : NSObject
	- (instancetype) initWithURL:(NSURL*)url handler:(void (^)(void))handler;
	- (void) stop;
@end
