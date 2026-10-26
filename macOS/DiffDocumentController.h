#import <Cocoa/Cocoa.h>

@class DiffDocument;

/* Opens comparisons: from the Open panel, the Finder, the Dock, or the diffotron command. */
@interface DiffDocumentController : NSDocumentController
	/* Open files opened together, such as the diffotron command's request and its files. */
	- (void) openFilesAtURLs:(NSArray<NSURL*>*)urls;
	- (DiffDocument*) openComparisonWithURLs:(NSArray<NSURL*>*)urls labels:(NSArray<NSString*>*)labels;
@end
