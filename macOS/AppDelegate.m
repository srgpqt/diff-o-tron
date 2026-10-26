#import "AppDelegate.h"

#import "DiffDocumentController.h"

static DiffDocumentController* g_document_controller = NULL;
static AppDelegate* g_app_delegate = NULL;

#define _(t,a,k) [[NSMenuItem alloc] initWithTitle:t action:a keyEquivalent:k]

static NSMenuItem* with_modifiers(NSMenuItem* item, NSEventModifierFlags modifiers) {
	item.keyEquivalentModifierMask = modifiers;
	return item;
}

static NSString* key_string(unichar c) {
	return [NSString stringWithCharacters:&c length:1];
}

static NSMenu* add_menu(NSMenu* mainMenu, NSString* title) {
	NSMenuItem* item = _(title, NULL, @"");
	[mainMenu addItem:item];
	NSMenu* menu = [[NSMenu alloc] initWithTitle:title];
	[item setSubmenu:menu];
	return menu;
}

static void build_main_menu(NSApplication* app) {
	NSMenu* mainMenu = [[NSMenu alloc] init];
	[app setMainMenu:mainMenu];

	NSString* up = key_string(NSUpArrowFunctionKey);
	NSString* down = key_string(NSDownArrowFunctionKey);
	NSEventModifierFlags command = NSEventModifierFlagCommand;
	NSEventModifierFlags shiftCommand = NSEventModifierFlagShift | NSEventModifierFlagCommand;

	/* App menu */ {
		NSMenu* appMenu = add_menu(mainMenu, @"Diff-o-tron");
		[appMenu addItem:_(@"About Diff-o-tron", @selector(showAboutPanel:), @"")];
		[appMenu addItem:[NSMenuItem separatorItem]];
		[appMenu addItem:_(@"Hide Diff-o-tron", @selector(hide:), @"h")];
		[appMenu addItem:with_modifiers(_(@"Hide Others", @selector(hideOtherApplications:), @"h"), NSEventModifierFlagCommand | NSEventModifierFlagOption)];
		[appMenu addItem:_(@"Show All", @selector(unhideAllApplications:), @"")];
		[appMenu addItem:[NSMenuItem separatorItem]];
		[appMenu addItem:_(@"Quit Diff-o-tron", @selector(terminate:), @"q")];
	}

	/* File menu */ {
		NSMenu* fileMenu = add_menu(mainMenu, @"File");
		[fileMenu addItem:_(@"New Window", @selector(newDocument:), @"n")];
		[fileMenu addItem:_(@"New Tab", @selector(newWindowForTab:), @"t")];
		[fileMenu addItem:_(@"Open…", @selector(openDocument:), @"o")];
		[fileMenu addItem:[NSMenuItem separatorItem]];
		[fileMenu addItem:_(@"Close", @selector(performClose:), @"w")];
	}

	/* Edit menu */ {
		NSMenu* editMenu = add_menu(mainMenu, @"Edit");
		[editMenu addItem:_(@"Undo", @selector(undo:), @"z")];
		[editMenu addItem:_(@"Redo", @selector(redo:), @"Z")];
		[editMenu addItem:[NSMenuItem separatorItem]];
		[editMenu addItem:_(@"Cut", @selector(cut:), @"x")];
		[editMenu addItem:_(@"Copy", @selector(copy:), @"c")];
		[editMenu addItem:_(@"Paste", @selector(paste:), @"v")];
		[editMenu addItem:_(@"Delete", @selector(delete:), @"")];
		[editMenu addItem:_(@"Select All", @selector(selectAll:), @"a")];
	}

	/* View menu */ {
		NSMenu* viewMenu = add_menu(mainMenu, @"View");
		[viewMenu addItem:_(@"Toggle Sidebar", @selector(toggleSidebar:), @"/")];
		[viewMenu addItem:with_modifiers(_(@"Enter Full Screen", @selector(toggleFullScreen:), @"f"), NSEventModifierFlagControl | NSEventModifierFlagCommand)];
		[viewMenu addItem:[NSMenuItem separatorItem]];
		[viewMenu addItem:with_modifiers(_(@"Select Previous File", @selector(selectPreviousFile:), up), shiftCommand)];
		[viewMenu addItem:with_modifiers(_(@"Select Next File", @selector(selectNextFile:), down), shiftCommand)];
		[viewMenu addItem:[NSMenuItem separatorItem]];
		[viewMenu addItem:_(@"Blocks", @selector(showBlocks:), @"1")];
		[viewMenu addItem:_(@"Fluid", @selector(showFluid:), @"2")];
		[viewMenu addItem:_(@"Unified", @selector(showUnified:), @"3")];
		[viewMenu addItem:[NSMenuItem separatorItem]];
		[viewMenu addItem:with_modifiers(_(@"Previous Change", @selector(previousChange:), up), command)];
		[viewMenu addItem:with_modifiers(_(@"Next Change", @selector(nextChange:), down), command)];
		[viewMenu addItem:[NSMenuItem separatorItem]];
		[viewMenu addItem:_(@"Increase Text Size", @selector(increaseTextSize:), @"+")];
		[viewMenu addItem:_(@"Decrease Text Size", @selector(decreaseTextSize:), @"-")];
		[viewMenu addItem:[NSMenuItem separatorItem]];
		[viewMenu addItem:with_modifiers(_(@"Wrap Lines", @selector(toggleWrapLines:), @"k"), shiftCommand)];
		[viewMenu addItem:with_modifiers(_(@"Ignore Whitespace", @selector(toggleIgnoreWhitespace:), @"'"), shiftCommand)];
	}

	/* Window menu */ {
		NSMenu* windowMenu = add_menu(mainMenu, @"Window");
		[app setWindowsMenu:windowMenu];
		[windowMenu addItem:_(@"Minimize", @selector(performMiniaturize:), @"m")];
		[windowMenu addItem:_(@"Zoom", @selector(performZoom:), @"")];
		[windowMenu addItem:[NSMenuItem separatorItem]];
		[windowMenu addItem:_(@"Bring All to Front", @selector(arrangeInFront:), @"")];
	}

	/* Help menu */ {
		NSMenu* helpMenu = add_menu(mainMenu, @"Help");
		[app setHelpMenu:helpMenu];
		[helpMenu addItem:_(@"Diff-o-tron Help", @selector(showHelp:), @"?")];
	}
}

@implementation AppDelegate

+ (int) start {
	NSApplication* app = [NSApplication sharedApplication];
	[app setActivationPolicy:NSApplicationActivationPolicyRegular];
	[NSApp activateIgnoringOtherApps:YES];

	/* The first document controller created becomes the shared one. */
	g_document_controller = [[DiffDocumentController alloc] init];

	g_app_delegate = [[AppDelegate alloc] init];
	if (!g_app_delegate) return 1;
	app.delegate = g_app_delegate;

	build_main_menu(app);
	[app run];

	return EXIT_SUCCESS;
}


- (BOOL) applicationShouldOpenUntitledFile:(NSApplication*)sender {
	return YES;
}

- (BOOL) applicationOpenUntitledFile:(NSApplication*)sender {
	[g_document_controller newDocument:nil];
	return YES;
}

/* The standard About panel, with the credits the licenses of the software built in require. */
- (IBAction) showAboutPanel:(id)sender {
	NSMutableDictionary* options = [NSMutableDictionary dictionary];
	NSURL* url = [[NSBundle mainBundle] URLForResource:@"Credits" withExtension:@"html"];
	NSData* data = url ? [NSData dataWithContentsOfURL:url] : nil;
	NSMutableAttributedString* credits = data ? [[NSMutableAttributedString alloc] initWithHTML:data documentAttributes:NULL] : nil;
	if (credits) {
		/* Text from HTML comes in black; follow the appearance instead. */
		[credits addAttribute:NSForegroundColorAttributeName value:[NSColor labelColor] range:NSMakeRange(0, credits.length)];
		options[NSAboutPanelOptionCredits] = credits;
	}
	[NSApp orderFrontStandardAboutPanelWithOptions:options];
}

- (BOOL) applicationSupportsSecureRestorableState:(NSApplication*)application {
	return YES; // Keeps macOS 12+ happy.
}

@end
