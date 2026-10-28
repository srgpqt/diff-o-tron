#import "Common.h"

@class MergeEditor;

/* The document type of comparisons. */
static NSString* const kComparisonType = @"Comparison";

/* A comparison of the files or folders at its URLs, never saved; or a merge of two files, saved to a third. */
@interface DiffDocument : NSDocument
	@property (nonatomic, readonly) DtComparison* comparison;
	@property (nonatomic, readonly) BOOL comparing;
	/* Incremented whenever the comparison is replaced. */
	@property (nonatomic, readonly) NSUInteger generation;
	/* Whether the comparison was last replaced by reloading the same files, after they changed. */
	@property (nonatomic, readonly) BOOL reloaded;
	/* Posted with kClosedNotification when the document closes. */
	@property (nonatomic, copy) NSString* closeToken;
	- (NSURL*) urlForSide:(NSUInteger)side;
	/* Shown instead of a side's name, such as the repository path from git difftool; nil for none. */
	- (NSString*) labelForSide:(NSUInteger)side;
	/* The side's label, or else its file name. */
	- (NSString*) nameForSide:(NSUInteger)side;
	- (void) setURL:(NSURL*)url forSide:(NSUInteger)side;
	/* Sets the sides from the first URLs. */
	- (void) setURLs:(NSArray<NSURL*>*)urls;
	/* Sets the sides and their labels (empty strings for none) from the first of each. */
	- (void) setURLs:(NSArray<NSURL*>*)urls labels:(NSArray<NSString*>*)labels;
	- (BOOL) isEmpty;

	/*
	 * A merge of A and B, the document's sides, against their base, saved to the
	 * output file. Its window shows the base, A and B, and the merged result.
	 */
	@property (nonatomic, readonly) BOOL isMerge;
	@property (nonatomic, readonly) NSURL* baseURL;
	/* The base's label, or nil for none. */
	@property (nonatomic, readonly) NSString* baseLabel;
	@property (nonatomic, readonly) NSURL* outputURL;
	/* labels: the base's, A's and B's, empty strings for none. */
	- (void) setMergeBase:(NSURL*)base a:(NSURL*)a b:(NSURL*)b output:(NSURL*)output labels:(NSArray<NSString*>*)labels;
	/* The merged result to save, from the window that edits it; nil while there's none. */
	@property (nonatomic, weak) MergeEditor* mergeEditor;
	/* Write the merged result to the output file, and tell the diffotron command whether it has conflicts left. */
	- (BOOL) saveMerge:(NSError**)error;
@end
