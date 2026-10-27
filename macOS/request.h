/*
 * How the diffotron command (macOS/cli.m) asks the app (macOS/DiffDocumentController.m)
 * to compare or merge files.
 *
 * The sandboxed app can only read files that Launch Services opens with it, so
 * the command opens a request file together with the files to compare. The
 * request is a property list naming the paths, and a token identifying it in the
 * distributed notifications the app posts when it opens and closes the comparison.
 */

static NSString* const kRequestExtension = @"diffotron-request";

/* Request keys */
static NSString* const kRequestPaths = @"paths";   /* array of absolute paths: 2 to compare, or a merge's base, A and B */
static NSString* const kRequestOutput = @"output"; /* for a merge, the absolute path to save the merged result to */
static NSString* const kRequestLabels = @"labels"; /* array of 2 strings, empty for none */
static NSString* const kRequestToken = @"token";   /* string */
static NSString* const kRequestWait = @"wait";     /* boolean: post kClosedNotification */

/* Posted with the request's token as the object. */
static NSString* const kOpenedNotification = @"com.srgpqt.diff-o-tron.opened";
static NSString* const kClosedNotification = @"com.srgpqt.diff-o-tron.closed";
/* Posted when a merge is saved with no conflict markers left. */
static NSString* const kMergedNotification = @"com.srgpqt.diff-o-tron.merged";
/* Posted when a merge is saved with conflict markers left. */
static NSString* const kUnresolvedNotification = @"com.srgpqt.diff-o-tron.unresolved";
