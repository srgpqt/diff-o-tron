#import "Common.h"

/*
 * A merge's merged result, in a text view: keeps track of where each chunk of
 * the merge is as the text is edited, colors the changes, and replaces them
 * with versions of them.
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
	- (void) scrollToHunk:(NSInteger)hunk;
	/* Undoably replace a change's text with versions of it (DT_VERSION_*), one after another. */
	- (void) replaceHunk:(NSInteger)hunk withVersions:(NSArray<NSNumber*>*)versions actionName:(NSString*)name;
@end

/* Whether a line starts with git's conflict marker, as an unresolved conflict's does. */
BOOL has_conflict_markers(NSString* text);
