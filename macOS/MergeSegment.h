#import <Cocoa/Cocoa.h>

/* A chunk of a merge in the merged result: where its text is as the text is edited, and its versions. */
@interface MergeSegment : NSObject
	@property (nonatomic) NSRange range;
	/* DtMergeChunk.kind */
	@property (nonatomic) uint8_t kind;
	/* The change it is, or -1 if it's unchanged. */
	@property (nonatomic) NSInteger hunk;
	/* Its text in each version, indexed by DT_VERSION_*. */
	@property (nonatomic, copy) NSArray<NSString*>* versions;
@end
