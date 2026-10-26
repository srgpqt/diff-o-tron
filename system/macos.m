#import <Cocoa/Cocoa.h>

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
	@property (strong, nonatomic) NSWindow *mainWindow;
@end

static AppDelegate* _app_delegate = NULL;

@implementation AppDelegate

+ (int) start {
	NSApplication* app = [NSApplication sharedApplication];
	[app setActivationPolicy:NSApplicationActivationPolicyRegular];
	[NSApp activateIgnoringOtherApps:YES];

	_app_delegate = [[AppDelegate alloc] init];
	if (!_app_delegate) return 1;

	app.delegate = _app_delegate;

	NSMenu* mainMenu = [[NSMenu alloc] init];
	[app setMainMenu:mainMenu];

	#define _(t,a,k) [[NSMenuItem alloc] initWithTitle:t action:a keyEquivalent:k]

	/* App menu */ {
		NSMenuItem* appMenuItem = _(@"Diff-o-tron", NULL, @"");
		[mainMenu addItem:appMenuItem];

		NSMenu* appMenu = [[NSMenu alloc] initWithTitle:@"Diff-o-tron"];
		[appMenuItem setSubmenu:appMenu];

		[appMenu addItem:_(@"About Diff-o-tron", @selector(orderFrontStandardAboutPanel:), @"")];
		[appMenu addItem:[NSMenuItem separatorItem]];

		[appMenu addItem:[NSMenuItem separatorItem]];
		[appMenu addItem:_(@"Hide Diff-o-tron", @selector(hide:), @"h")];

		NSMenuItem* hideOthersMenuItem = _(@"Hide Others", @selector(hideOtherApplications:), @"h");
		[hideOthersMenuItem setKeyEquivalentModifierMask:NSEventModifierFlagCommand|NSEventModifierFlagOption];
		[appMenu addItem:hideOthersMenuItem];

		[appMenu addItem:[NSMenuItem separatorItem]];
		[appMenu addItem:_(@"Quit Diff-o-tron", @selector(terminate:), @"q")];
	}

	/* Edit menu */ {
		NSMenuItem* editMenuItem = _(@"Edit", NULL, @"");
		[mainMenu addItem:editMenuItem];

		NSMenu* editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
		[editMenuItem setSubmenu:editMenu];

		[editMenu addItem:_(@"Undo", @selector(undo:), @"z")];
		[editMenu addItem:_(@"Redo", @selector(redo:), @"Z")];
		[editMenu addItem:[NSMenuItem separatorItem]];
		[editMenu addItem:_(@"Cut", @selector(cut:), @"x")];
		[editMenu addItem:_(@"Copy", @selector(copy:), @"c")];
		[editMenu addItem:_(@"Paste", @selector(paste:), @"v")];
		[editMenu addItem:_(@"Delete", @selector(delete:), @"")];
		[editMenu addItem:_(@"Select All", @selector(selectAll:), @"a")];
	}

	/* Window menu */ {
		NSMenuItem* windowMenuItem = _(@"Window", NULL, @"");
		[mainMenu addItem:windowMenuItem];

		NSMenu* windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
		[windowMenuItem setSubmenu:windowMenu];
		[app setWindowsMenu:windowMenu];
		[windowMenu addItem:_(@"Minimize", @selector(performMiniaturize:), @"m")];
		[windowMenu addItem:_(@"Zoom", @selector(performZoom:), @"")];
		NSMenuItem* toggleFullScreenMenuItem = _(@"Enter Full Screen", @selector(toggleFullScreen:), @"f");
		[windowMenu addItem:toggleFullScreenMenuItem];
	}

	/* Help menu */ {
		NSMenuItem* helpMenuItem = _(@"Help", NULL, @"");
		[mainMenu addItem:helpMenuItem];

		NSMenu* helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
		[helpMenuItem setSubmenu:helpMenu];
		[app setHelpMenu:helpMenu];
		[helpMenu addItem:_(@"Diff-o-tron Help", @selector(showHelp:), @"?")];
	}

	NSWindow *window = [[NSWindow alloc]
		initWithContentRect: CGRectMake(100, 123, 1024, 768)
		styleMask: (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
		backing: NSBackingStoreBuffered
		defer: NO
	];

	window.delegate = _app_delegate;
	_app_delegate.mainWindow = window;

	[app run];

	return EXIT_SUCCESS;
}

- (void) applicationWillFinishLaunching:(NSNotification *)aNotification {
	[_mainWindow makeKeyAndOrderFront:nil];
}

- (BOOL) applicationSupportsSecureRestorableState:(NSApplication *)app {
	return YES; // Keeps macOS 12+ happy.
}

@end

int main(int argc, const char * argv[]) {
	@autoreleasepool {
		return [AppDelegate start];
	}
}
