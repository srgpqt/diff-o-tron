#import <Cocoa/Cocoa.h>

/* A row of the sidebar: a file, or a group header for the files of a folder. */
@interface SidebarItem : NSObject
	@property (nonatomic) BOOL isGroup;
	@property (nonatomic, copy) NSString* title;
	@property (nonatomic) size_t entry;
	/* The entry's path, to find it again in a reloaded comparison. */
	@property (nonatomic, copy) NSString* path;
	@property (nonatomic) uint8_t status;
@end
