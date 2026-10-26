/*
 * The macOS front end: an NSDocument app where each document is a comparison of
 * two files or folders, shown in a window with the changed files in a sidebar
 * and the diff of the selected file beside it.
 */

#import "AppDelegate.h"

int main(int argc, const char * argv[]) {
	@autoreleasepool {
		return [AppDelegate start];
	}
}
