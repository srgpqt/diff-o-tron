#import "AppDelegate.h"

#import "Common.h"
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
	NSString* left = key_string(NSLeftArrowFunctionKey);
	NSString* right = key_string(NSRightArrowFunctionKey);
	NSString* backspace = key_string(NSBackspaceCharacter);
	NSEventModifierFlags command = NSEventModifierFlagCommand;
	NSEventModifierFlags shiftCommand = NSEventModifierFlagShift | NSEventModifierFlagCommand;
	NSEventModifierFlags optionCommand = NSEventModifierFlagOption | NSEventModifierFlagCommand;

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
		[fileMenu addItem:_(@"Save", @selector(saveDocument:), @"s")];
	}

	/* Edit menu */ {
		NSMenu* editMenu = add_menu(mainMenu, @"Edit");
		[editMenu addItem:_(@"Undo", @selector(undo:), @"z")];
		[editMenu addItem:_(@"Redo", @selector(redo:), @"Z")];
		[editMenu addItem:[NSMenuItem separatorItem]];
		[editMenu addItem:_(@"Cut", @selector(cut:), @"x")];
		[editMenu addItem:_(@"Copy", @selector(copy:), @"c")];
		[editMenu addItem:_(@"Paste", @selector(paste:), @"v")];
		[editMenu addItem:with_modifiers(_(@"Paste and Match Style", @selector(pasteAsPlainText:), @"v"), optionCommand | NSEventModifierFlagShift)];
		[editMenu addItem:_(@"Delete", @selector(delete:), @"")];
		[editMenu addItem:_(@"Select All", @selector(selectAll:), @"a")];
		[editMenu addItem:[NSMenuItem separatorItem]];

		/* For the merged result. */
		NSMenuItem* findItem = _(@"Find", NULL, @"");
		NSMenu* findMenu = [[NSMenu alloc] initWithTitle:@"Find"];
		findItem.submenu = findMenu;
		[editMenu addItem:findItem];
		NSMenuItem* find = _(@"Find…", @selector(performTextFinderAction:), @"f");
		find.tag = NSTextFinderActionShowFindInterface;
		[findMenu addItem:find];
		NSMenuItem* replace = with_modifiers(_(@"Find and Replace…", @selector(performTextFinderAction:), @"f"), optionCommand);
		replace.tag = NSTextFinderActionShowReplaceInterface;
		[findMenu addItem:replace];
		NSMenuItem* findNext = _(@"Find Next", @selector(performTextFinderAction:), @"g");
		findNext.tag = NSTextFinderActionNextMatch;
		[findMenu addItem:findNext];
		NSMenuItem* findPrevious = _(@"Find Previous", @selector(performTextFinderAction:), @"G");
		findPrevious.tag = NSTextFinderActionPreviousMatch;
		[findMenu addItem:findPrevious];
		NSMenuItem* useSelection = _(@"Use Selection for Find", @selector(performTextFinderAction:), @"e");
		useSelection.tag = NSTextFinderActionSetSearchString;
		[findMenu addItem:useSelection];
		[findMenu addItem:_(@"Jump to Selection", @selector(centerSelectionInVisibleArea:), @"j")];
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
		NSMenuItem* fontItem = _(@"Font", NULL, @"");
		NSMenu* fontMenu = [[NSMenu alloc] initWithTitle:@"Font"];
		/* Filled in as it opens. */
		fontMenu.delegate = (id<NSMenuDelegate>)app.delegate;
		fontItem.submenu = fontMenu;
		[viewMenu addItem:fontItem];
		[viewMenu addItem:[NSMenuItem separatorItem]];
		[viewMenu addItem:with_modifiers(_(@"Wrap Lines", @selector(toggleWrapLines:), @"k"), shiftCommand)];
		[viewMenu addItem:with_modifiers(_(@"Ignore Whitespace", @selector(toggleIgnoreWhitespace:), @"'"), shiftCommand)];
	}

	/* Merge menu: replacing the current change in the merged result. */ {
		NSMenu* mergeMenu = add_menu(mainMenu, @"Merge");
		[mergeMenu addItem:with_modifiers(_(@"Previous Conflict", @selector(previousConflict:), up), optionCommand)];
		[mergeMenu addItem:with_modifiers(_(@"Next Conflict", @selector(nextConflict:), down), optionCommand)];
		[mergeMenu addItem:[NSMenuItem separatorItem]];
		[mergeMenu addItem:with_modifiers(_(@"Take A", @selector(takeA:), left), command)];
		[mergeMenu addItem:with_modifiers(_(@"Take B", @selector(takeB:), right), command)];
		[mergeMenu addItem:with_modifiers(_(@"Take A then B", @selector(takeAThenB:), right), optionCommand)];
		[mergeMenu addItem:with_modifiers(_(@"Take B then A", @selector(takeBThenA:), left), optionCommand)];
		[mergeMenu addItem:[NSMenuItem separatorItem]];
		[mergeMenu addItem:with_modifiers(_(@"Reset Change", @selector(resetChange:), backspace), optionCommand)];
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

/*
 * The installed font families of fixed-width fonts, for View › Font: the layout
 * counts columns, so proportional fonts would break it.
 */
static NSArray<NSString*>* fixed_width_families(void) {
	NSMutableSet<NSString*>* families = [NSMutableSet set];
	for (NSString* name in [[NSFontManager sharedFontManager] availableFontNamesWithTraits:NSFixedPitchFontMask]) {
		NSString* family = [NSFont fontWithName:name size:12].familyName;
		/* The system's own fonts, which start with a dot, aren't for choosing. */
		if (family && ![family hasPrefix:@"."]) [families addObject:family];
	}
	return [families.allObjects sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

/* View › Font: the system's monospaced font, then the fixed-width font families, each in its font. */
- (void) menuNeedsUpdate:(NSMenu*)menu {
	if (menu.numberOfItems > 0) return;
	NSMenuItem* system = _(@"System Monospaced", @selector(chooseFontFamily:), @"");
	system.target = self;
	[menu addItem:system];
	[menu addItem:[NSMenuItem separatorItem]];
	CGFloat size = [NSFont systemFontSize];
	for (NSString* family in fixed_width_families()) {
		NSMenuItem* item = _(family, @selector(chooseFontFamily:), @"");
		item.target = self;
		item.representedObject = family;
		item.attributedTitle = [[NSAttributedString alloc] initWithString:family attributes:@{NSFontAttributeName: text_font(family, size)}];
		[menu addItem:item];
	}
}

/* Use a font family, or the system's monospaced font, in every comparison window, and from now on. */
- (IBAction) chooseFontFamily:(NSMenuItem*)sender {
	NSString* family = sender.representedObject;
	NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
	if (family) {
		[defaults setObject:family forKey:kFontFamilyDefault];
	} else {
		[defaults removeObjectForKey:kFontFamilyDefault];
	}
	[[NSNotificationCenter defaultCenter] postNotificationName:kFontFamilyDidChangeNotification object:nil];
}

- (BOOL) validateMenuItem:(NSMenuItem*)menuItem {
	if (menuItem.action == @selector(chooseFontFamily:)) {
		NSString* current = [[NSUserDefaults standardUserDefaults] stringForKey:kFontFamilyDefault];
		NSString* family = menuItem.representedObject;
		BOOL chosen = family ? [family isEqualToString:current] : current.length == 0;
		menuItem.state = chosen ? NSControlStateValueOn : NSControlStateValueOff;
	}
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
