/*
 * How the diffotron command (system/macos-cli.m) asks the app (system/macos.m)
 * to compare files.
 *
 * The sandboxed app can only read files that Launch Services opens with it, so
 * the command opens a request file together with the files to compare. The
 * request is a property list naming the paths, and a token identifying it in the
 * distributed notifications the app posts when it opens and closes the comparison.
 */

static NSString* const kRequestExtension = @"diffotron-request";

/* Request keys */
static NSString* const kRequestPaths = @"paths";   /* array of 2 absolute paths */
static NSString* const kRequestLabels = @"labels"; /* array of 2 strings, empty for none */
static NSString* const kRequestToken = @"token";   /* string */
static NSString* const kRequestWait = @"wait";     /* boolean: post kClosedNotification */

/* Posted with the request's token as the object. */
static NSString* const kOpenedNotification = @"com.srgpqt.diff-o-tron.opened";
static NSString* const kClosedNotification = @"com.srgpqt.diff-o-tron.closed";
