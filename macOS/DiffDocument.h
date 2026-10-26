#import "Common.h"

/* The document type of comparisons. */
static NSString* const kComparisonType = @"Comparison";

/* A comparison of the files or folders at its URLs. Never saved. */
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
@end
