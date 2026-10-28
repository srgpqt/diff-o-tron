#import "MergeEditor.h"

#import "DiffView+Private.h"

static NSString* string16(DtStr16 s) {
	return [NSString stringWithCharacters:s.ptr length:s.len];
}

@implementation MergeEditor {
	__weak NSTextView* _textView;
	/* A copy of the text, told of each edit, with where the changes are in it; NULL with no merge. */
	DtMergeResult* _result;
	BOOL _loading;
	BOOL _highlightPending;
}

- (instancetype) initWithTextView:(NSTextView*)textView {
	if ((self = [super init])) {
		_textView = textView;
		_currentHunk = -1;
		textView.textStorage.delegate = self;
	}
	return self;
}

- (void) dealloc {
	dt_merge_result_free(_result);
}

- (void) loadMerge:(DtFileDiff*)merge {
	dt_merge_result_free(_result);
	_result = merge ? dt_merge_result_new(merge) : NULL;
	NSString* text = _result ? string16(dt_merge_result_text(_result)) : @"";

	NSTextStorage* storage = _textView.textStorage;
	NSAttributedString* attributed = [[NSAttributedString alloc] initWithString:text attributes:_textView.typingAttributes];
	_loading = YES;
	[storage replaceCharactersInRange:NSMakeRange(0, storage.length) withAttributedString:attributed];
	_loading = NO;
	[self setNeedsHighlight];
}

- (void) setCurrentHunk:(NSInteger)currentHunk {
	_currentHunk = currentHunk;
	[self setNeedsHighlight];
}

/* Where a change's text is, if there's such a change. */
- (BOOL) hunk:(NSInteger)hunk range:(NSRange*)range {
	size_t start = 0;
	size_t length = 0;
	if (!_result || hunk < 0 || !dt_merge_result_hunk_range(_result, (size_t)hunk, &start, &length)) return NO;
	*range = NSMakeRange(start, length);
	return YES;
}

- (NSInteger) hunkAtLocation:(NSUInteger)location {
	return _result ? dt_merge_result_hunk_at(_result, location) : -1;
}

- (void) scrollToHunk:(NSInteger)hunk {
	NSRange range;
	if ([self hunk:hunk range:&range]) [_textView scrollRangeToVisible:range];
}

- (void) replaceHunk:(NSInteger)hunk withVersions:(NSArray<NSNumber*>*)versions actionName:(NSString*)name {
	NSRange range;
	if (![self hunk:hunk range:&range]) return;
	NSMutableString* text = [NSMutableString string];
	for (NSNumber* version in versions) {
		[text appendString:dt_string(dt_merge_result_version(_result, (size_t)hunk, version.unsignedCharValue))];
	}

	if (![_textView shouldChangeTextInRange:range replacementString:text]) return;
	[_textView.textStorage replaceCharactersInRange:range withString:text];
	[_textView didChangeText];
	[_textView.undoManager setActionName:name];
	_textView.selectedRange = NSMakeRange(range.location, 0);
}

- (BOOL) hunkHasConflictMarkers:(NSInteger)hunk {
	return _result && hunk >= 0 && dt_merge_result_unresolved(_result, (size_t)hunk);
}

- (BOOL) hasConflictMarkers {
	return _result && dt_merge_result_has_conflict_markers(_result);
}

- (BOOL) saveToURL:(NSURL*)url error:(NSError**)error {
	if (_result && dt_merge_result_save(_result, url.path.fileSystemRepresentation)) return YES;
	if (error) {
		NSString* reason = _result ? dt_string(dt_merge_result_error(_result)) : @"There's no merged result to save.";
		*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:@{NSLocalizedDescriptionKey: reason}];
	}
	return NO;
}

#pragma mark Editing

/* Tell the result of each edit, which moves the changes with the text. */
- (void) textStorage:(NSTextStorage*)textStorage didProcessEditing:(NSTextStorageEditActions)editedMask range:(NSRange)editedRange changeInLength:(NSInteger)delta {
	if (!(editedMask & NSTextStorageEditedCharacters) || _loading || !_result) return;
	NSUInteger oldLength = (NSUInteger)((NSInteger)editedRange.length - delta);
	unichar* text = malloc((editedRange.length > 0 ? editedRange.length : 1) * sizeof(unichar));
	if (!text) abort();
	[textStorage.string getCharacters:text range:editedRange];
	dt_merge_result_replace(_result, editedRange.location, oldLength, text, editedRange.length);
	free(text);
	[self setNeedsHighlight];
}

#pragma mark Colors

- (void) setNeedsHighlight {
	if (_highlightPending) return;
	_highlightPending = YES;
	__weak MergeEditor* weakSelf = self;
	dispatch_async(dispatch_get_main_queue(), ^(void) {
		MergeEditor* editor = weakSelf;
		if (!editor) return;
		editor->_highlightPending = NO;
		[editor highlight];
	});
}

/* Color the changes: conflicts with their markers still in them, and the rest. And count the conflicts. */
- (void) highlight {
	NSTextView* textView = _textView;
	NSLayoutManager* layoutManager = textView.layoutManager;
	NSUInteger length = textView.textStorage.length;
	[layoutManager removeTemporaryAttribute:NSBackgroundColorAttributeName forCharacterRange:NSMakeRange(0, length)];
	size_t count = _result ? dt_merge_result_hunk_count(_result) : 0;
	for (size_t hunk = 0; hunk < count; hunk++) {
		NSRange range;
		if (![self hunk:(NSInteger)hunk range:&range] || range.length == 0 || NSMaxRange(range) > length) continue;
		BOOL conflict = dt_merge_result_unresolved(_result, hunk);
		NSColor* color = line_color(conflict ? DT_LINE_CONFLICT : DT_LINE_CHANGED, (NSInteger)hunk == _currentHunk);
		[layoutManager addTemporaryAttribute:NSBackgroundColorAttributeName value:color forCharacterRange:range];
	}
	NSUInteger conflicts = _result ? dt_merge_result_conflict_count(_result) : 0;
	if (conflicts != _conflictCount) {
		_conflictCount = conflicts;
		if (_conflictCountChanged) _conflictCountChanged();
	}
}

@end
