#import "MergeEditor.h"

#import "DiffView+Private.h"
#import "MergeSegment.h"

static NSString* const kConflictMarker = @"<<<<<<< ";

BOOL has_conflict_markers(NSString* text) {
	return [text hasPrefix:kConflictMarker] || [text rangeOfString:[@"\n" stringByAppendingString:kConflictMarker]].location != NSNotFound;
}

@implementation MergeEditor {
	__weak NSTextView* _textView;
	/* The merge's chunks, in order, their ranges tiling the text. */
	NSArray<MergeSegment*>* _segments;
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

- (void) loadMerge:(DtFileDiff*)merge {
	NSMutableArray<MergeSegment*>* segments = [NSMutableArray array];
	NSMutableString* text = [NSMutableString string];
	size_t count = merge ? dt_merge_chunk_count(merge) : 0;
	for (size_t i = 0; i < count; i++) {
		DtMergeChunk chunk = dt_merge_chunk(merge, i);
		NSMutableArray<NSString*>* versions = [NSMutableArray array];
		for (uint8_t version = DT_VERSION_BASE; version <= DT_VERSION_MERGED; version++) {
			[versions addObject:dt_string(dt_merge_chunk_text(merge, i, version))];
		}
		MergeSegment* segment = [[MergeSegment alloc] init];
		segment.kind = chunk.kind;
		segment.hunk = chunk.hunk;
		segment.versions = versions;
		segment.range = NSMakeRange(text.length, versions[DT_VERSION_MERGED].length);
		[text appendString:versions[DT_VERSION_MERGED]];
		[segments addObject:segment];
	}

	NSTextStorage* storage = _textView.textStorage;
	NSAttributedString* attributed = [[NSAttributedString alloc] initWithString:text attributes:_textView.typingAttributes];
	_loading = YES;
	[storage replaceCharactersInRange:NSMakeRange(0, storage.length) withAttributedString:attributed];
	_loading = NO;
	_segments = segments;
	[self setNeedsHighlight];
}

- (void) setCurrentHunk:(NSInteger)currentHunk {
	_currentHunk = currentHunk;
	[self setNeedsHighlight];
}

- (MergeSegment*) segmentOfHunk:(NSInteger)hunk {
	for (MergeSegment* segment in _segments) {
		if (segment.hunk == hunk) return segment;
	}
	return nil;
}

- (NSInteger) hunkAtLocation:(NSUInteger)location {
	for (MergeSegment* segment in _segments) {
		if (NSLocationInRange(location, segment.range)) return segment.hunk;
	}
	return _segments.lastObject.hunk;
}

- (void) scrollToHunk:(NSInteger)hunk {
	MergeSegment* segment = [self segmentOfHunk:hunk];
	if (segment) [_textView scrollRangeToVisible:segment.range];
}

- (void) replaceHunk:(NSInteger)hunk withVersions:(NSArray<NSNumber*>*)versions actionName:(NSString*)name {
	MergeSegment* segment = [self segmentOfHunk:hunk];
	if (!segment) return;
	NSMutableString* text = [NSMutableString string];
	for (NSNumber* version in versions) [text appendString:segment.versions[version.unsignedIntegerValue]];

	NSRange range = segment.range;
	if (![_textView shouldChangeTextInRange:range replacementString:text]) return;
	[_textView.textStorage replaceCharactersInRange:range withString:text];
	[_textView didChangeText];
	[_textView.undoManager setActionName:name];
	_textView.selectedRange = NSMakeRange(range.location, 0);
}

- (BOOL) hunkHasConflictMarkers:(NSInteger)hunk {
	MergeSegment* segment = [self segmentOfHunk:hunk];
	return segment && NSMaxRange(segment.range) <= _textView.textStorage.length && [self segmentHasConflictMarkers:segment];
}

- (BOOL) segmentHasConflictMarkers:(MergeSegment*)segment {
	return has_conflict_markers([_textView.string substringWithRange:segment.range]);
}

#pragma mark Editing

/*
 * Move the chunks' ranges with the text as it's edited. A boundary between
 * chunks before the edit stays put, one after it moves with the text after it,
 * and one inside it moves to the end of the new text. Text inserted where a
 * chunk is empty, as a removed change is, goes into that chunk.
 */
- (void) textStorage:(NSTextStorage*)textStorage didProcessEditing:(NSTextStorageEditActions)editedMask range:(NSRange)editedRange changeInLength:(NSInteger)delta {
	if (!(editedMask & NSTextStorageEditedCharacters) || _loading) return;
	NSUInteger oldStart = editedRange.location;
	NSUInteger newEnd = NSMaxRange(editedRange);
	NSUInteger oldEnd = (NSUInteger)((NSInteger)newEnd - delta);

	NSInteger target = -1;
	for (NSUInteger i = 0; oldStart == oldEnd && i < _segments.count; i++) {
		NSRange range = _segments[i].range;
		if (range.length == 0 && range.location == oldStart) {
			target = (NSInteger)i;
			break;
		}
	}

	for (NSUInteger i = 0; i < _segments.count; i++) {
		MergeSegment* segment = _segments[i];
		NSUInteger start = segment.range.location;
		NSUInteger end = NSMaxRange(segment.range);
		if (target >= 0) {
			if ((NSInteger)i == target) {
				end = newEnd;
			} else if ((NSInteger)i > target) {
				start = (NSUInteger)((NSInteger)start + delta);
				end = (NSUInteger)((NSInteger)end + delta);
			}
		} else {
			start = start <= oldStart ? start : start >= oldEnd ? (NSUInteger)((NSInteger)start + delta) : newEnd;
			end = end <= oldStart ? end : end >= oldEnd ? (NSUInteger)((NSInteger)end + delta) : newEnd;
		}
		segment.range = NSMakeRange(start, end - start);
	}
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
	NSUInteger conflicts = 0;
	[layoutManager removeTemporaryAttribute:NSBackgroundColorAttributeName forCharacterRange:NSMakeRange(0, length)];
	for (MergeSegment* segment in _segments) {
		if (segment.hunk < 0 || segment.range.length == 0 || NSMaxRange(segment.range) > length) continue;
		BOOL conflict = [self segmentHasConflictMarkers:segment];
		if (conflict) conflicts++;
		NSColor* color = line_color(conflict ? DT_LINE_CONFLICT : DT_LINE_CHANGED, segment.hunk == _currentHunk);
		[layoutManager addTemporaryAttribute:NSBackgroundColorAttributeName value:color forCharacterRange:segment.range];
	}
	if (conflicts != _conflictCount) {
		_conflictCount = conflicts;
		if (_conflictCountChanged) _conflictCountChanged();
	}
}

@end
