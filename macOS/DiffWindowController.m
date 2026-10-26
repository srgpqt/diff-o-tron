#import "DiffWindowController.h"

#import "Common.h"
#import "DiffDocument.h"
#import "DiffView.h"
#import "DropHighlightView.h"
#import "DropView.h"
#import "SidebarItem.h"

/* User defaults: the DiffView mode new windows start in, and whether they wrap lines. */
static NSString* const kDiffModeDefault = @"DiffMode";
static NSString* const kWrapLinesDefault = @"WrapLines";
/* User defaults: the frame of the comparison window last moved or resized, where new ones open. */
static NSString* const kWindowFrameDefault = @"WindowFrame";
/* How far a new window is moved off a window already where it would open. */
static const CGFloat kCascadeOffset = 22;

/*
 * Labels whose text may be too long hold their width below the sidebar's
 * holding priority, so they truncate instead of making it narrower.
 */
static const NSLayoutPriority kSidebarHoldingPriority = NSLayoutPriorityDefaultLow + 10;
static const NSLayoutPriority kSqueezablePriority = NSLayoutPriorityDefaultLow;

static const CGFloat kHeaderHeight = 36;
static const CGFloat kBottomBarHeight = 32;

static NSString* status_symbol(uint8_t status) {
	switch (status) {
		case DT_STATUS_MODIFIED: return @"triangle";
		case DT_STATUS_ADDED: return @"plus";
		case DT_STATUS_REMOVED: return @"minus";
		default: return @"equal";
	}
}

static NSString* status_name(uint8_t status) {
	switch (status) {
		case DT_STATUS_MODIFIED: return @"Modified";
		case DT_STATUS_ADDED: return @"Added";
		case DT_STATUS_REMOVED: return @"Removed";
		default: return @"Unchanged";
	}
}

static NSColor* status_color(uint8_t status) {
	switch (status) {
		case DT_STATUS_MODIFIED: return [NSColor systemPurpleColor];
		case DT_STATUS_ADDED: return [NSColor systemGreenColor];
		case DT_STATUS_REMOVED: return [NSColor systemRedColor];
		default: return [NSColor tertiaryLabelColor];
	}
}

@implementation DiffWindowController {
	NSSplitViewController* _split;
	NSTableView* _table;
	NSTextField* _sidebarTitle;
	NSProgressIndicator* _spinner;
	NSArray<NSTextField*>* _paneTitles;
	DiffView* _diffView;
	NSTextField* _message;
	NSTextField* _changeLabel;
	NSButton* _previousButton;
	NSButton* _nextButton;
	NSButton* _whitespaceCheckbox;
	NSSegmentedControl* _modeControl;
	DropHighlightView* _highlight;

	NSMutableArray<SidebarItem*>* _items;
	NSUInteger _shownGeneration;
	NSInteger _shownEntry;
	NSString* _shownPath;
	/* Shown instead of the diff, such as for binary files. */
	NSString* _fileMessage;
	BOOL _ignoreWhitespace;
}

- (instancetype) init {
	NSWindow* window = [[NSWindow alloc]
		initWithContentRect:NSMakeRect(0, 0, 1200, 780)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
		backing:NSBackingStoreBuffered
		defer:YES];
	if ((self = [super initWithWindow:window])) {
		_items = [NSMutableArray array];
		_shownGeneration = NSUIntegerMax;
		_shownEntry = -1;
		window.delegate = self;
		window.restorable = NO;
		window.tabbingIdentifier = kComparisonType;
		window.minSize = NSMakeSize(640, 400);
		[self buildViews];
	}
	return self;
}

- (NSView*) buildSidebar {
	_sidebarTitle = [NSTextField labelWithString:@""];
	_sidebarTitle.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
	_sidebarTitle.lineBreakMode = NSLineBreakByTruncatingTail;
	[_sidebarTitle setContentCompressionResistancePriority:kSqueezablePriority forOrientation:NSLayoutConstraintOrientationHorizontal];

	_spinner = [[NSProgressIndicator alloc] init];
	_spinner.style = NSProgressIndicatorStyleSpinning;
	_spinner.controlSize = NSControlSizeSmall;
	_spinner.displayedWhenStopped = NO;

	NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:@"file"];
	column.resizingMask = NSTableColumnAutoresizingMask;
	_table = [[NSTableView alloc] init];
	[_table addTableColumn:column];
	_table.headerView = nil;
	_table.style = NSTableViewStyleSourceList;
	_table.rowHeight = 24;
	_table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
	_table.dataSource = self;
	_table.delegate = self;

	NSScrollView* tableScroll = [[NSScrollView alloc] init];
	tableScroll.documentView = _table;
	tableScroll.hasVerticalScroller = YES;
	tableScroll.autohidesScrollers = YES;
	tableScroll.drawsBackground = NO;

	NSView* sidebar = [[NSView alloc] init];
	add_subviews(sidebar, @[_sidebarTitle, _spinner, tableScroll]);
	[NSLayoutConstraint activateConstraints:@[
		[_sidebarTitle.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor constant:16],
		[_sidebarTitle.centerYAnchor constraintEqualToAnchor:sidebar.topAnchor constant:kHeaderHeight / 2],
		[_spinner.leadingAnchor constraintEqualToAnchor:_sidebarTitle.trailingAnchor constant:6],
		[_spinner.centerYAnchor constraintEqualToAnchor:_sidebarTitle.centerYAnchor],
		[_spinner.trailingAnchor constraintLessThanOrEqualToAnchor:sidebar.trailingAnchor constant:-12],
		[tableScroll.topAnchor constraintEqualToAnchor:sidebar.topAnchor constant:kHeaderHeight],
		[tableScroll.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor],
		[tableScroll.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor],
		[tableScroll.bottomAnchor constraintEqualToAnchor:sidebar.bottomAnchor]
	]];
	return sidebar;
}

- (NSView*) buildDetail {
	DropView* detail = [[DropView alloc] init];
	detail.controller = self;
	[detail registerForDraggedTypes:@[NSPasteboardTypeFileURL]];

	NSMutableArray<NSTextField*>* titles = [NSMutableArray array];
	for (NSUInteger side = 0; side < kSideCount; side++) {
		NSTextField* title = [NSTextField labelWithString:@""];
		title.lineBreakMode = NSLineBreakByTruncatingMiddle;
		/* Truncate a long name rather than push the sidebar narrower. */
		[title setContentCompressionResistancePriority:kSqueezablePriority forOrientation:NSLayoutConstraintOrientationHorizontal];
		[titles addObject:title];
	}
	_paneTitles = titles;

	NSBox* topSeparator = [[NSBox alloc] init];
	topSeparator.boxType = NSBoxSeparator;
	NSBox* bottomSeparator = [[NSBox alloc] init];
	bottomSeparator.boxType = NSBoxSeparator;

	_diffView = [[DiffView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
	__weak DiffWindowController* weakSelf = self;
	_diffView.currentHunkChanged = ^(void) {
		[weakSelf updateChangeLabel];
	};
	NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
	NSInteger mode = [defaults objectForKey:kDiffModeDefault] ? [defaults integerForKey:kDiffModeDefault] : kDiffModeFluid;
	_diffView.mode = mode >= kDiffModeBlocks && mode <= kDiffModeUnified ? mode : kDiffModeFluid;
	_diffView.wrapsLines = [defaults objectForKey:kWrapLinesDefault] ? [defaults boolForKey:kWrapLinesDefault] : YES;

	_message = [NSTextField wrappingLabelWithString:@""];
	_message.alignment = NSTextAlignmentCenter;
	_message.textColor = [NSColor secondaryLabelColor];
	_message.font = [NSFont systemFontOfSize:15];

	_whitespaceCheckbox = [NSButton checkboxWithTitle:@"Ignore whitespace" target:self action:@selector(toggleIgnoreWhitespace:)];
	_changeLabel = [NSTextField labelWithString:@""];
	_changeLabel.textColor = [NSColor secondaryLabelColor];
	_previousButton = [NSButton
		buttonWithImage:[NSImage imageWithSystemSymbolName:@"chevron.up" accessibilityDescription:@"Previous Change"]
		target:self
		action:@selector(previousChange:)];
	_nextButton = [NSButton
		buttonWithImage:[NSImage imageWithSystemSymbolName:@"chevron.down" accessibilityDescription:@"Next Change"]
		target:self
		action:@selector(nextChange:)];
	/* Segments in the order of the kDiffMode values. */
	_modeControl = [NSSegmentedControl
		segmentedControlWithLabels:@[@"Blocks", @"Fluid", @"Unified"]
		trackingMode:NSSegmentSwitchTrackingSelectOne
		target:self
		action:@selector(modeControlDidChange:)];
	_modeControl.selectedSegment = _diffView.mode;
	NSStackView* bar = [[NSStackView alloc] init];
	bar.edgeInsets = NSEdgeInsetsMake(0, 12, 0, 12);
	bar.spacing = 12;
	[bar addView:_modeControl inGravity:NSStackViewGravityLeading];
	[bar addView:_whitespaceCheckbox inGravity:NSStackViewGravityTrailing];
	[bar addView:_changeLabel inGravity:NSStackViewGravityTrailing];
	[bar addView:_previousButton inGravity:NSStackViewGravityTrailing];
	[bar addView:_nextButton inGravity:NSStackViewGravityTrailing];

	_highlight = [[DropHighlightView alloc] initWithFrame:NSZeroRect];
	detail.highlightView = _highlight;

	add_subviews(detail, @[titles[0], titles[1], topSeparator, _diffView, _message, bottomSeparator, bar, _highlight]);
	[NSLayoutConstraint activateConstraints:@[
		/* Each title over its side, as DiffView lays them out. */
		[titles[0].leadingAnchor constraintEqualToAnchor:detail.leadingAnchor constant:12],
		[titles[0].trailingAnchor constraintLessThanOrEqualToAnchor:detail.centerXAnchor constant:-kMiddleWidth / 2 - 8],
		[titles[0].centerYAnchor constraintEqualToAnchor:detail.topAnchor constant:kHeaderHeight / 2],
		[titles[1].leadingAnchor constraintEqualToAnchor:detail.centerXAnchor constant:kMiddleWidth / 2 + 12],
		[titles[1].trailingAnchor constraintLessThanOrEqualToAnchor:detail.trailingAnchor constant:-12],
		[titles[1].centerYAnchor constraintEqualToAnchor:titles[0].centerYAnchor],

		[topSeparator.topAnchor constraintEqualToAnchor:detail.topAnchor constant:kHeaderHeight],
		[topSeparator.leadingAnchor constraintEqualToAnchor:detail.leadingAnchor],
		[topSeparator.trailingAnchor constraintEqualToAnchor:detail.trailingAnchor],
		[topSeparator.heightAnchor constraintEqualToConstant:1],

		[_diffView.topAnchor constraintEqualToAnchor:topSeparator.bottomAnchor],
		[_diffView.leadingAnchor constraintEqualToAnchor:detail.leadingAnchor],
		[_diffView.trailingAnchor constraintEqualToAnchor:detail.trailingAnchor],
		[_diffView.bottomAnchor constraintEqualToAnchor:bottomSeparator.topAnchor],

		[_message.centerXAnchor constraintEqualToAnchor:_diffView.centerXAnchor],
		[_message.centerYAnchor constraintEqualToAnchor:_diffView.centerYAnchor],
		[_message.widthAnchor constraintLessThanOrEqualToConstant:420],

		[bottomSeparator.leadingAnchor constraintEqualToAnchor:detail.leadingAnchor],
		[bottomSeparator.trailingAnchor constraintEqualToAnchor:detail.trailingAnchor],
		[bottomSeparator.heightAnchor constraintEqualToConstant:1],

		[bar.topAnchor constraintEqualToAnchor:bottomSeparator.bottomAnchor],
		[bar.leadingAnchor constraintEqualToAnchor:detail.leadingAnchor],
		[bar.trailingAnchor constraintEqualToAnchor:detail.trailingAnchor],
		[bar.bottomAnchor constraintEqualToAnchor:detail.bottomAnchor],
		[bar.heightAnchor constraintEqualToConstant:kBottomBarHeight],

		[_highlight.topAnchor constraintEqualToAnchor:detail.topAnchor],
		[_highlight.leadingAnchor constraintEqualToAnchor:detail.leadingAnchor],
		[_highlight.trailingAnchor constraintEqualToAnchor:detail.trailingAnchor],
		[_highlight.bottomAnchor constraintEqualToAnchor:detail.bottomAnchor]
	]];
	return detail;
}

- (void) buildViews {
	NSViewController* sidebarController = [[NSViewController alloc] init];
	sidebarController.view = [self buildSidebar];
	NSViewController* detailController = [[NSViewController alloc] init];
	detailController.view = [self buildDetail];

	NSSplitViewItem* sidebarItem = [NSSplitViewItem sidebarWithViewController:sidebarController];
	sidebarItem.minimumThickness = 180;
	sidebarItem.maximumThickness = 480;
	sidebarItem.canCollapse = YES;
	/* Keep the sidebar's width as the window resizes, and against labels too long for theirs. */
	sidebarItem.holdingPriority = kSidebarHoldingPriority;
	NSSplitViewItem* detailItem = [NSSplitViewItem splitViewItemWithViewController:detailController];
	detailItem.minimumThickness = 400;

	_split = [[NSSplitViewController alloc] init];
	[_split addSplitViewItem:sidebarItem];
	[_split addSplitViewItem:detailItem];

	NSWindow* window = self.window;
	window.contentViewController = _split;
	[window setContentSize:NSMakeSize(1200, 780)];
	[window layoutIfNeeded];
	[_split.splitView setPosition:260 ofDividerAtIndex:0];
	[window center];
	[self restoreWindowFrame];
	window.initialFirstResponder = _table;

	[self updateChangeLabel];
}

/* Open where the last comparison window was, moved off any window already there. */
- (void) restoreWindowFrame {
	NSWindow* window = self.window;
	NSString* frame = [[NSUserDefaults standardUserDefaults] stringForKey:kWindowFrameDefault];
	if (frame) [window setFrameFromString:frame];

	BOOL covered = YES;
	for (int tries = 0; covered && tries < 20; tries++) {
		covered = NO;
		for (NSWindow* other in NSApp.windows) {
			if (other == window || !other.visible || ![other.delegate isKindOfClass:[DiffWindowController class]]) continue;
			if (fabs(NSMinX(other.frame) - NSMinX(window.frame)) < 1 && fabs(NSMaxY(other.frame) - NSMaxY(window.frame)) < 1) {
				covered = YES;
			}
		}
		if (covered) {
			[window setFrameTopLeftPoint:NSMakePoint(NSMinX(window.frame) + kCascadeOffset, NSMaxY(window.frame) - kCascadeOffset)];
		}
	}
}

- (void) saveWindowFrame {
	NSWindow* window = self.window;
	if (!window.visible || (window.styleMask & NSWindowStyleMaskFullScreen)) return;
	[[NSUserDefaults standardUserDefaults] setObject:window.stringWithSavedFrame forKey:kWindowFrameDefault];
}

- (void) windowDidMove:(NSNotification*)notification {
	[self saveWindowFrame];
}

- (void) windowDidResize:(NSNotification*)notification {
	[self saveWindowFrame];
}

#pragma mark Document state

- (DiffDocument*) diffDocument {
	return self.document;
}

- (void) documentDidChange {
	[self synchronizeWindowTitleWithDocumentName];
	DiffDocument* doc = [self diffDocument];
	if (doc.generation != _shownGeneration) {
		_shownGeneration = doc.generation;
		[self reloadItemsKeepingSelection:doc.reloaded];
	}
	[self updateSidebarTitle];
	[self updatePaneTitles];
	[self updateMessage];
}

- (void) setDocument:(id)document {
	[super setDocument:document];
	if (document) [self documentDidChange];
}

/*
 * List the comparison's files and show the first. When it's reloaded, keep
 * showing the same file, if it's still there, where it was.
 */
- (void) reloadItemsKeepingSelection:(BOOL)keep {
	NSString* shownPath = keep ? _shownPath : nil;
	[_items removeAllObjects];
	DiffDocument* doc = [self diffDocument];
	DtComparison* cmp = doc.comparison;
	size_t count = cmp ? dt_comparison_count(cmp) : 0;
	NSString* lastDir = @"";
	for (size_t i = 0; i < count; i++) {
		DtEntry entry = dt_comparison_entry(cmp, i);
		/* Only list unchanged files when comparing two files. */
		if (entry.status == DT_STATUS_SAME && count > 1) continue;

		NSString* dir = dt_string(entry.dir);
		if (dir.length > 0 && ![dir isEqualToString:lastDir]) {
			SidebarItem* group = [[SidebarItem alloc] init];
			group.isGroup = YES;
			group.title = [dir stringByReplacingOccurrencesOfString:@"/" withString:@" › "];
			[_items addObject:group];
		}
		lastDir = dir;

		SidebarItem* item = [[SidebarItem alloc] init];
		item.title = dt_string(entry.name);
		/* Comparing two files: name them by their labels, when they have them. */
		if (count == 1 && ([doc labelForSide:0] || [doc labelForSide:1])) {
			NSString* a = [doc nameForSide:0];
			NSString* b = [doc nameForSide:1];
			item.title = [a isEqualToString:b] ? a : [NSString stringWithFormat:@"%@ → %@", a, b];
		}
		item.entry = i;
		item.path = dt_string(entry.path);
		item.status = entry.status;
		[_items addObject:item];
	}
	[_table reloadData];

	NSInteger row = -1;
	for (NSUInteger i = 0; shownPath && i < _items.count; i++) {
		if (!_items[i].isGroup && [_items[i].path isEqualToString:shownPath]) row = (NSInteger)i;
	}
	BOOL same = row >= 0;
	if (!same) row = [self fileRowFrom:-1 step:1];
	if (row >= 0) {
		[_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
		[_table scrollRowToVisible:row];
	}
	[self showSelectedEntry:YES keepingPosition:same];
}

- (void) updateSidebarTitle {
	DiffDocument* doc = [self diffDocument];
	if (doc.comparing) {
		_sidebarTitle.stringValue = @"Comparing…";
		[_spinner startAnimation:nil];
		return;
	}
	[_spinner stopAnimation:nil];
	if (!doc.comparison) {
		_sidebarTitle.stringValue = @"";
		return;
	}
	NSUInteger changed = 0;
	for (SidebarItem* item in _items) {
		if (!item.isGroup && item.status != DT_STATUS_SAME) changed++;
	}
	_sidebarTitle.stringValue = changed == 1
		? @"1 changed file"
		: [NSString stringWithFormat:@"%lu changed files", (unsigned long)changed];
}

- (void) updatePaneTitles {
	NSArray<NSString*>* letters = @[@"A", @"B"];
	DiffDocument* doc = [self diffDocument];
	DtComparison* cmp = doc.comparison;
	NSDictionary* letterAttributes = @{
		NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
		NSForegroundColorAttributeName: [NSColor secondaryLabelColor]
	};
	NSDictionary* nameAttributes = @{
		NSFontAttributeName: [NSFont systemFontOfSize:13],
		NSForegroundColorAttributeName: [NSColor labelColor]
	};

	for (NSUInteger side = 0; side < kSideCount; side++) {
		NSString* name = @"";
		NSString* path = nil;
		if (cmp && _shownEntry >= 0) {
			DtEntry entry = dt_comparison_entry(cmp, (size_t)_shownEntry);
			path = dt_string(dt_comparison_entry_path(cmp, (size_t)_shownEntry, (uint8_t)side));
			NSString* dir = dt_string(entry.dir);
			NSString* label = [doc labelForSide:side];
			if (path.length == 0) {
				name = @"Not present";
			} else if (label && dt_comparison_count(cmp) == 1 && dir.length == 0) {
				name = label;
			} else if (dir.length > 0) {
				dir = [dir stringByReplacingOccurrencesOfString:@"/" withString:@" › "];
				name = [NSString stringWithFormat:@"%@ › %@", dir, path.lastPathComponent];
			} else {
				name = path.lastPathComponent;
			}
		} else {
			NSURL* url = [doc urlForSide:side];
			if (url) name = [doc nameForSide:side];
			path = url.path;
		}

		NSMutableAttributedString* title = [[NSMutableAttributedString alloc] initWithString:letters[side] attributes:letterAttributes];
		NSString* spacedName = [@"   " stringByAppendingString:name];
		[title appendAttributedString:[[NSAttributedString alloc] initWithString:spacedName attributes:nameAttributes]];
		_paneTitles[side].attributedStringValue = title;
		_paneTitles[side].toolTip = path.length > 0 ? path : nil;
	}
}

- (void) updateMessage {
	DiffDocument* doc = [self diffDocument];
	NSURL* a = [doc urlForSide:0];
	NSURL* b = [doc urlForSide:1];
	NSString* message = nil;
	if (!a && !b) {
		message = @"Drop two files or folders here to compare them, or choose File › Open…";
	} else if (!a || !b) {
		message = [NSString stringWithFormat:@"Drop a file or folder on the %@ to compare it with “%@”.",
			a ? @"right" : @"left", (a ? a : b).lastPathComponent];
	} else if (doc.comparing) {
		message = nil;
	} else if (doc.comparison && dt_comparison_error(doc.comparison).len > 0) {
		message = dt_string(dt_comparison_error(doc.comparison));
	} else if (doc.comparison && _items.count == 0) {
		message = @"There are no differences.";
	} else {
		message = _fileMessage;
	}
	_message.stringValue = message ? message : @"";
	_message.hidden = message == nil;
}

- (void) updateChangeLabel {
	DtFileDiff* diff = _diffView.diff;
	size_t count = diff ? dt_file_diff_hunk_count(diff) : 0;
	NSInteger current = _diffView.currentHunk;
	if (!diff || _fileMessage) {
		_changeLabel.stringValue = @"";
	} else if (count == 0) {
		_changeLabel.stringValue = @"No changes";
	} else {
		_changeLabel.stringValue = [NSString stringWithFormat:@"Change %ld of %lu", (long)current + 1, (unsigned long)count];
	}
	_previousButton.enabled = current > 0;
	_nextButton.enabled = count > 0 && (size_t)(current + 1) < count;
}

#pragma mark Showing files

- (NSInteger) fileRowFrom:(NSInteger)row step:(NSInteger)step {
	for (NSInteger i = row + step; i >= 0 && i < (NSInteger)_items.count; i += step) {
		if (!_items[(NSUInteger)i].isGroup) return i;
	}
	return -1;
}

/* Show the selected file's diff, unless it's already shown and force is NO. */
- (void) showSelectedEntry:(BOOL)force {
	[self showSelectedEntry:force keepingPosition:NO];
}

/* keep: keep the diff where it's scrolled to, as when the same file is shown again. */
- (void) showSelectedEntry:(BOOL)force keepingPosition:(BOOL)keep {
	NSInteger row = _table.selectedRow;
	NSInteger entry = -1;
	NSString* entryPath = nil;
	if (row >= 0 && (NSUInteger)row < _items.count && !_items[(NSUInteger)row].isGroup) {
		entry = (NSInteger)_items[(NSUInteger)row].entry;
		entryPath = _items[(NSUInteger)row].path;
	}
	if (entry == _shownEntry && !force) return;

	_shownEntry = entry;
	_shownPath = entryPath;
	_fileMessage = nil;
	DtComparison* cmp = [self diffDocument].comparison;
	DtFileDiff* diff = NULL;
	if (entry >= 0 && cmp) {
		DtDiffOptions options = {(uint32_t)(_ignoreWhitespace ? DT_IGNORE_WHITESPACE : 0), kTabWidth};
		diff = dt_file_diff_new(cmp, (size_t)entry, options);
		uint32_t flags = dt_file_diff_flags(diff);
		if (dt_file_diff_error(diff).len > 0) {
			_fileMessage = dt_string(dt_file_diff_error(diff));
		} else if (flags & DT_DIFF_BINARY) {
			_fileMessage = (flags & DT_DIFF_IDENTICAL) ? @"The binary files are identical." : @"The binary files differ.";
		}
	}
	NSMutableArray* files = [NSMutableArray array];
	for (NSUInteger side = 0; side < kSideCount; side++) {
		NSString* path = cmp && entry >= 0 ? dt_string(dt_comparison_entry_path(cmp, (size_t)entry, (uint8_t)side)) : @"";
		[files addObject:path.length > 0 ? (id)[NSURL fileURLWithPath:path] : [NSNull null]];
	}
	_diffView.fileURLs = files;
	[_diffView setDiff:diff keepingPosition:keep];
	if (!keep) [_diffView scrollToCurrentHunk];

	[self updatePaneTitles];
	[self updateChangeLabel];
	[self updateMessage];
}

- (void) dropURLs:(NSArray<NSURL*>*)urls side:(NSInteger)side {
	DiffDocument* doc = [self diffDocument];
	if (urls.count == 0) return;
	if (side < 0 || (NSUInteger)side >= kSideCount || urls.count > 1) {
		[doc setURLs:urls];
	} else {
		[doc setURL:urls[0] forSide:(NSUInteger)side];
	}
}

#pragma mark Table

- (NSInteger) numberOfRowsInTableView:(NSTableView*)tableView {
	return (NSInteger)_items.count;
}

- (BOOL) tableView:(NSTableView*)tableView isGroupRow:(NSInteger)row {
	return _items[(NSUInteger)row].isGroup;
}

- (BOOL) tableView:(NSTableView*)tableView shouldSelectRow:(NSInteger)row {
	return !_items[(NSUInteger)row].isGroup;
}

- (void) tableViewSelectionDidChange:(NSNotification*)notification {
	[self showSelectedEntry:NO];
}

- (NSView*) tableView:(NSTableView*)tableView viewForTableColumn:(NSTableColumn*)column row:(NSInteger)row {
	SidebarItem* item = _items[(NSUInteger)row];
	if (item.isGroup) {
		NSTextField* label = [tableView makeViewWithIdentifier:@"group" owner:self];
		if (!label) {
			label = [NSTextField labelWithString:@""];
			label.identifier = @"group";
			label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
			label.textColor = [NSColor secondaryLabelColor];
			label.lineBreakMode = NSLineBreakByTruncatingHead;
		}
		label.stringValue = item.title;
		return label;
	}

	NSTableCellView* cell = [tableView makeViewWithIdentifier:@"file" owner:self];
	if (!cell) {
		cell = [[NSTableCellView alloc] init];
		cell.identifier = @"file";
		NSImageView* icon = [[NSImageView alloc] init];
		NSTextField* label = [NSTextField labelWithString:@""];
		label.lineBreakMode = NSLineBreakByTruncatingMiddle;
		add_subviews(cell, @[icon, label]);
		cell.imageView = icon;
		cell.textField = label;
		[NSLayoutConstraint activateConstraints:@[
			[icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
			[icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
			[icon.widthAnchor constraintEqualToConstant:16],
			[icon.heightAnchor constraintEqualToConstant:16],
			[label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:6],
			[label.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-4],
			[label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]
		]];
	}
	cell.textField.stringValue = item.title;
	cell.imageView.image = [NSImage imageWithSystemSymbolName:status_symbol(item.status) accessibilityDescription:status_name(item.status)];
	cell.imageView.contentTintColor = status_color(item.status);
	return cell;
}

#pragma mark Actions

- (IBAction) newWindowForTab:(id)sender {
	NSError* error = nil;
	NSDocument* doc = [[NSDocumentController sharedDocumentController] openUntitledDocumentAndDisplay:NO error:&error];
	if (!doc) {
		if (error) [self presentError:error];
		return;
	}
	[doc makeWindowControllers];
	NSWindow* window = doc.windowControllers.firstObject.window;
	[self.window addTabbedWindow:window ordered:NSWindowAbove];
	[window makeKeyAndOrderFront:nil];
}

- (IBAction) toggleSidebar:(id)sender {
	[_split toggleSidebar:sender];
}

- (IBAction) selectPreviousFile:(id)sender {
	[self selectFileStep:-1];
}

- (IBAction) selectNextFile:(id)sender {
	[self selectFileStep:1];
}

- (void) selectFileStep:(NSInteger)step {
	NSInteger row = [self fileRowFrom:_table.selectedRow step:step];
	if (row < 0) return;
	[_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
	[_table scrollRowToVisible:row];
}

- (IBAction) previousChange:(id)sender {
	[self moveChange:-1];
}

- (IBAction) nextChange:(id)sender {
	[self moveChange:1];
}

- (void) moveChange:(NSInteger)step {
	DtFileDiff* diff = _diffView.diff;
	if (!diff) return;
	NSInteger hunk = _diffView.currentHunk + step;
	if (hunk < 0 || hunk >= (NSInteger)dt_file_diff_hunk_count(diff)) {
		/* Nowhere further to go: show where the current hunk is instead. */
		[_diffView scrollToCurrentHunk];
		[_diffView flashCurrentHunk];
		return;
	}
	_diffView.currentHunk = hunk;
	[_diffView scrollToCurrentHunk];
	[self updateChangeLabel];
}

- (IBAction) showBlocks:(id)sender {
	[self setDiffMode:kDiffModeBlocks];
}

- (IBAction) showFluid:(id)sender {
	[self setDiffMode:kDiffModeFluid];
}

- (IBAction) showUnified:(id)sender {
	[self setDiffMode:kDiffModeUnified];
}

- (IBAction) modeControlDidChange:(id)sender {
	[self setDiffMode:_modeControl.selectedSegment];
}

- (void) setDiffMode:(NSInteger)mode {
	_diffView.mode = mode;
	_modeControl.selectedSegment = mode;
	[[NSUserDefaults standardUserDefaults] setInteger:mode forKey:kDiffModeDefault];
}

- (IBAction) toggleWrapLines:(id)sender {
	_diffView.wrapsLines = !_diffView.wrapsLines;
	[[NSUserDefaults standardUserDefaults] setBool:_diffView.wrapsLines forKey:kWrapLinesDefault];
}

- (IBAction) toggleIgnoreWhitespace:(id)sender {
	_ignoreWhitespace = !_ignoreWhitespace;
	_whitespaceCheckbox.state = _ignoreWhitespace ? NSControlStateValueOn : NSControlStateValueOff;
	[self showSelectedEntry:YES];
}

- (IBAction) increaseTextSize:(id)sender {
	[self setTextSize:_diffView.fontSize + 1];
}

- (IBAction) decreaseTextSize:(id)sender {
	[self setTextSize:_diffView.fontSize - 1];
}

- (void) setTextSize:(CGFloat)size {
	if (size < 8 || size > 36) return;
	_diffView.fontSize = size;
}

- (BOOL) validateMenuItem:(NSMenuItem*)menuItem {
	SEL action = menuItem.action;
	if (action == @selector(toggleIgnoreWhitespace:)) {
		menuItem.state = _ignoreWhitespace ? NSControlStateValueOn : NSControlStateValueOff;
	} else if (action == @selector(toggleWrapLines:)) {
		menuItem.state = _diffView.wrapsLines ? NSControlStateValueOn : NSControlStateValueOff;
	} else if (action == @selector(showBlocks:)) {
		menuItem.state = _diffView.mode == kDiffModeBlocks ? NSControlStateValueOn : NSControlStateValueOff;
	} else if (action == @selector(showFluid:)) {
		menuItem.state = _diffView.mode == kDiffModeFluid ? NSControlStateValueOn : NSControlStateValueOff;
	} else if (action == @selector(showUnified:)) {
		menuItem.state = _diffView.mode == kDiffModeUnified ? NSControlStateValueOn : NSControlStateValueOff;
	} else if (action == @selector(previousChange:) || action == @selector(nextChange:)) {
		/*
		 * Enabled even with no change to move to, so their keys don't fall through
		 * to the sidebar, which would move to another file: that's for Shift too.
		 */
		return _diffView.diff != NULL;
	} else if (action == @selector(selectPreviousFile:)) {
		return [self fileRowFrom:_table.selectedRow step:-1] >= 0;
	} else if (action == @selector(selectNextFile:)) {
		return [self fileRowFrom:_table.selectedRow step:1] >= 0;
	} else if (action == @selector(increaseTextSize:)) {
		return _diffView.fontSize < 36;
	} else if (action == @selector(decreaseTextSize:)) {
		return _diffView.fontSize > 8;
	}
	return YES;
}

@end
