/* What the macOS front end's files share: the core library, and small helpers. */

#import <Cocoa/Cocoa.h>

#include <os/log.h>

#include "diffotron.h"

/* The number of compared sides. */
static const NSUInteger kSideCount = 2;
/* The most sides a diff has: a merge's base, A and B. */
static const NSUInteger kMaxSides = DT_MAX_SIDES;
static const uint32_t kTabWidth = 4;

NSString* dt_string(DtStr s);

/* See with `log stream --predicate 'subsystem == "com.srgpqt.diff-o-tron"'`. */
os_log_t open_log(void);

/* Post a distributed notification for the diffotron command: see request.h. */
void post_request_notification(NSString* name, NSString* token);

/*
 * Since macOS 14, views don't clip their drawing to their bounds by default,
 * and drawRect: can be asked to draw outside them.
 */
void clip_to_bounds(NSView* view);

/* Add subviews laid out with constraints. */
void add_subviews(NSView* parent, NSArray<NSView*>* views);

BOOL is_directory(NSURL* url);
