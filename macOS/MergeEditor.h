#import "Common.h"

/*
 * A merge's merged result, in a text view: tells the core's DtMergeResult of
 * each edit, which keeps track of where each change is, colors the changes,
 * replaces them with versions of them, and saves the result.
 */
@interface MergeEditor : NSObject <NSTextStorageDelegate>
	- (instancetype) initWithTextView:(NSTextView*)textView;
	/* Start the text over with the merged result of a merge, as it starts, or with none for NULL. */
	- (void) loadMerge:(DtFileDiff*)merge;
	/* The change shown as current, or -1. */
	@property (nonatomic) NSInteger currentHunk;
	/* The change whose text a location is in, or -1. */
	- (NSInteger) hunkAtLocation:(NSUInteger)location;
	/* Whether a change is a conflict still unresolved: one with git's conflict markers in it. */
	- (BOOL) hunkHasConflictMarkers:(NSInteger)hunk;
	/* How many changes are conflicts still unresolved, counted as the changes are colored. */
	@property (nonatomic, readonly) NSUInteger conflictCount;
	/* Called when conflictCount changes. */
	@property (nonatomic, copy) void (^conflictCountChanged)(void);
	- (void) scrollToHunk:(NSInteger)hunk;
	/* Undoably replace a change's text with versions of it (DT_VERSION_*), one after another. */
	- (void) replaceHunk:(NSInteger)hunk withVersions:(NSArray<NSNumber*>*)versions actionName:(NSString*)name;
	/* Whether a line of the text starts with git's conflict marker, as an unresolved conflict's does. */
	@property (nonatomic, readonly) BOOL hasConflictMarkers;
	/* Write the text to a file, in place, as the file was: in its encoding, with its line breaks. */
	- (BOOL) saveToURL:(NSURL*)url error:(NSError**)error;
@end
