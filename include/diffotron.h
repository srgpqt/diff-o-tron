/*
 * Diff-o-tron core library: the platform-independent comparison and diff engine,
 * implemented in Rust (src/ffi.rs).
 *
 * Strings are UTF-8 and not NUL-terminated. Everything returned by a getter
 * stays valid until the object it came from is freed.
 */

#ifndef DIFFOTRON_H
#define DIFFOTRON_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DtComparison DtComparison;
typedef struct DtFileDiff DtFileDiff;
typedef struct DtLayout DtLayout;
typedef struct DtMergeResult DtMergeResult;

typedef struct {
	const char *ptr;
	size_t len;
} DtStr;

/* UTF-16 text, in code units. */
typedef struct {
	const uint16_t *ptr;
	size_t len;
} DtStr16;

/* DtEntry.status */
enum {
	DT_STATUS_SAME = 0,
	DT_STATUS_MODIFIED = 1,
	DT_STATUS_ADDED = 2,   /* only on side B */
	DT_STATUS_REMOVED = 3, /* only on side A */
};

/* DtLine.kind */
enum {
	DT_LINE_EQUAL = 0,
	DT_LINE_CHANGED = 1, /* paired with a similar line on the other side */
	DT_LINE_REMOVED = 2, /* only on side A */
	DT_LINE_ADDED = 3,   /* only on side B */
	DT_LINE_CONFLICT = 4, /* in a merge, a line of a conflict: changed differently on each side */
};

/*
 * Sides of a diff of two files. Functions taking a side take any of a diff's
 * sides: see dt_file_diff_side_count.
 */
enum {
	DT_SIDE_A = 0,
	DT_SIDE_B = 1,
};

/* Sides of a merge of three files, in the order they're shown. */
enum {
	DT_MERGE_BASE = 0,
	DT_MERGE_A = 1,
	DT_MERGE_B = 2,
};

#define DT_MAX_SIDES 3

/* DtDiffOptions.flags */
enum {
	DT_IGNORE_WHITESPACE = 1 << 0,
};

/* DtFileDiff state flags, from dt_file_diff_flags. */
enum {
	DT_DIFF_IDENTICAL = 1 << 0, /* both sides have exactly the same contents */
	DT_DIFF_BINARY = 1 << 1,    /* at least one side is binary; there are no rows */
};

typedef struct {
	DtStr path; /* relative to the compared roots, '/'-separated */
	DtStr dir;  /* directory part of path, empty at the root */
	DtStr name; /* file name part of path */
	uint8_t status;
} DtEntry;

typedef struct {
	uint32_t flags;
	uint32_t tab_width;
} DtDiffOptions;

/* A run of a changed line that differs from its paired line. */
typedef struct {
	uint32_t start, end;     /* byte offsets into the line */
	uint32_t start16, end16; /* the same offsets in UTF-16 code units */
} DtSpan;

typedef struct {
	DtStr text;        /* without its line terminator */
	uint32_t columns;  /* display width, with tabs expanded */
	uint8_t kind;
	uint32_t span_count;
	const DtSpan *spans;
} DtLine;

/* DtHunk.kind */
enum {
	DT_HUNK_CHANGED = 1,  /* lines changed, the same values as DT_LINE_* */
	DT_HUNK_REMOVED = 2,  /* lines only removed */
	DT_HUNK_ADDED = 3,    /* lines only added */
	DT_HUNK_CONFLICT = 4, /* in a merge, lines changed differently on each side */
};

/*
 * A change. In a diff of two files: consecutive rows of changed lines that are
 * either all paired with similar lines on the other side, or all unpaired. In
 * a merge: a chunk that isn't unchanged. Ranges are half-open.
 */
typedef struct {
	uint32_t row_start, row_end;
	uint32_t unified_start, unified_end; /* its rows in the unified view, of a diff of two files */
	uint32_t start[DT_MAX_SIDES], end[DT_MAX_SIDES]; /* its lines on each side */
	uint8_t kind;
} DtHunk;

/* DtMergeChunk.kind */
enum {
	DT_CHUNK_UNCHANGED = 0,
	DT_CHUNK_CHANGED_IN_A = 1,
	DT_CHUNK_CHANGED_IN_B = 2,
	DT_CHUNK_CHANGED_IN_BOTH = 3, /* the same way */
	DT_CHUNK_CONFLICT = 4,        /* differently */
};

/* A run of a merge: lines unchanged on both sides, or changed on either or both. */
typedef struct {
	uint8_t kind;
	int32_t hunk; /* the change it is, or -1 if it's unchanged */
} DtMergeChunk;

/* Versions of a merge chunk's text, from dt_merge_chunk_text. */
enum {
	DT_VERSION_BASE = 0,
	DT_VERSION_A = 1,
	DT_VERSION_B = 2,
	/*
	 * What the merged result starts with: the change from whichever side made
	 * one, or for a conflict, both sides between git's conflict markers.
	 */
	DT_VERSION_MERGED = 3,
};

/*
 * Compare two paths, each a file or a directory, given as NUL-terminated UTF-8.
 * Directories are walked recursively; a file compared with a directory is
 * compared with the directory's file of the same name. Symlinks to files are
 * followed, and /dev/null compares as a missing file. Never returns NULL.
 */
DtComparison *dt_comparison_new(const char *path_a, const char *path_b);
void dt_comparison_free(DtComparison *cmp);
DtStr dt_comparison_error(const DtComparison *cmp); /* empty if none */
size_t dt_comparison_count(const DtComparison *cmp);
/* Entries are sorted by path, each directory's files before its subdirectories. */
DtEntry dt_comparison_entry(const DtComparison *cmp, size_t index);
/* The full path of an entry's file on one side, empty if it's absent there. */
DtStr dt_comparison_entry_path(const DtComparison *cmp, size_t index, uint8_t side);

/*
 * The comparison's files to list, as a sidebar shows them: those that changed,
 * or the one compared if it's just two files, each directory's under a heading.
 */
typedef struct {
	DtStr title;    /* the file's name, or the directory's path, its parts separated by " › " */
	ptrdiff_t entry; /* the file's entry, or -1 for a directory's heading */
} DtItem;
size_t dt_comparison_item_count(const DtComparison *cmp);
DtItem dt_comparison_item(const DtComparison *cmp, size_t index);

/* Diff the files of an entry. Never returns NULL. */
DtFileDiff *dt_file_diff_new(const DtComparison *cmp, size_t index, DtDiffOptions options);
/*
 * Merge two changed versions of a file, A and B, against their common base,
 * given as NUL-terminated UTF-8 paths. Its sides are DT_MERGE_*. Never returns
 * NULL.
 */
DtFileDiff *dt_merge_new(const char *base, const char *a, const char *b, DtDiffOptions options);
void dt_file_diff_free(DtFileDiff *diff);
DtStr dt_file_diff_error(const DtFileDiff *diff); /* empty if none */
uint32_t dt_file_diff_flags(const DtFileDiff *diff);
/* 2 for a diff of two files, 3 for a merge. */
size_t dt_file_diff_side_count(const DtFileDiff *diff);
/* Rows of the side-by-side view, each showing a line from one or more sides. */
size_t dt_file_diff_row_count(const DtFileDiff *diff);
/* The index of the line a row shows on a side, or -1 for none. */
int32_t dt_file_diff_row_line(const DtFileDiff *diff, size_t row, uint8_t side);
/*
 * Rows of the unified view of a diff of two files, none for a merge: unchanged
 * lines show both sides, and changed lines one. Within a hunk, each run of
 * paired changed lines shows its A lines and then its B lines, and each run
 * of unpaired lines is a hunk of its own.
 */
size_t dt_file_diff_unified_count(const DtFileDiff *diff);
int32_t dt_file_diff_unified_line(const DtFileDiff *diff, size_t row, uint8_t side);
/*
 * The run of the unified view's changed lines from the same side and of the
 * same kind a row is in, as side * 8 + kind (DT_LINE_*), or -1 for an unchanged row.
 */
ptrdiff_t dt_file_diff_unified_group(const DtFileDiff *diff, size_t row);
/*
 * The first hunk that doesn't end before a row, of the side-by-side or the
 * unified rows, or else the last, or -1 for none: the hunk to keep current
 * when a diff is reloaded.
 */
ptrdiff_t dt_file_diff_nearest_hunk(const DtFileDiff *diff, bool unified, size_t row);
size_t dt_file_diff_line_count(const DtFileDiff *diff, uint8_t side);
DtLine dt_file_diff_line(const DtFileDiff *diff, uint8_t side, size_t index);
size_t dt_file_diff_hunk_count(const DtFileDiff *diff);
DtHunk dt_file_diff_hunk(const DtFileDiff *diff, size_t index);

/*
 * A merge's chunks, in order, none for a diff of two files. Each chunk's texts
 * in a version, put together, make that version of the file.
 */
size_t dt_merge_chunk_count(const DtFileDiff *diff);
DtMergeChunk dt_merge_chunk(const DtFileDiff *diff, size_t index);
DtStr dt_merge_chunk_text(const DtFileDiff *diff, size_t index, uint8_t version);

/*
 * A merge's merged result as the front end's text editor edits it, as the merge
 * starts it: a copy of the text, told of each edit, keeping track of where each
 * change is in it, finding the conflicts left unresolved, and saving it as the
 * file was, in its encoding and with its line breaks. Its changes are the
 * merge's hunks. Positions and lengths are in UTF-16 code units.
 *
 * Empty for a diff of two files. Never returns NULL.
 */
DtMergeResult *dt_merge_result_new(const DtFileDiff *merge);
void dt_merge_result_free(DtMergeResult *result);
/* The text, valid until the next edit. */
DtStr16 dt_merge_result_text(const DtMergeResult *result);
/* The text was edited: length units from start replaced with text_len of text. */
void dt_merge_result_replace(DtMergeResult *result, size_t start, size_t length, const uint16_t *text, size_t text_len);
size_t dt_merge_result_hunk_count(const DtMergeResult *result);
/* The change at a position, or past the end, the last; -1 for none, where the merge left the lines unchanged. */
ptrdiff_t dt_merge_result_hunk_at(const DtMergeResult *result, size_t position);
/* Where a change's text is: false if there's no such change. */
bool dt_merge_result_hunk_range(const DtMergeResult *result, size_t hunk, size_t *start, size_t *length);
/* A change's text in a version, DT_VERSION_*, to take that version. */
DtStr dt_merge_result_version(const DtMergeResult *result, size_t hunk, uint8_t version);
/* Whether a change is a conflict still unresolved: with git's conflict markers in it. */
bool dt_merge_result_unresolved(const DtMergeResult *result, size_t hunk);
size_t dt_merge_result_conflict_count(const DtMergeResult *result);
/* Whether a line of the text starts with git's conflict marker. */
bool dt_merge_result_has_conflict_markers(const DtMergeResult *result);
/*
 * Write the text to a file, given as a NUL-terminated UTF-8 path, in place
 * rather than atomically. On failure, returns false, with dt_merge_result_error
 * saying why, such as characters the file's encoding can't hold.
 */
bool dt_merge_result_save(DtMergeResult *result, const char *path);
DtStr dt_merge_result_error(const DtMergeResult *result); /* empty if none */

/*
 * The layout of a diff's views, in points down the document, from how tall the
 * front end measures each line, wrapped or not: tables of where each of a
 * side's lines (DT_SIDE_* or DT_MERGE_*), the side-by-side rows, or the unified
 * view's rows starts, each table after padding at the top. A row is as tall as
 * its tallest line; a unified row as its line.
 *
 * line_heights has, for each side, how tall each of its lines is, or is NULL
 * for none; line_height is a line's height unwrapped. diff may be NULL, for an
 * empty layout. Never returns NULL.
 */
DtLayout *dt_layout_new(const DtFileDiff *diff, const double *const *line_heights, double padding, double line_height);
void dt_layout_free(DtLayout *layout);

/* The layout's tables besides the sides' lines, for the table arguments. */
enum {
	DT_TABLE_ROWS = 16,
	DT_TABLE_UNIFIED = 17,
};

/* Where a row starts, or past the last, where the rows end. */
double dt_layout_y(const DtLayout *layout, uint8_t table, size_t index);
/* The row at y: -1 above the first, or the row count below the last. */
ptrdiff_t dt_layout_index_at(const DtLayout *layout, uint8_t table, double y);
/* The rows from first up to last that overlap top to bottom. */
void dt_layout_range(const DtLayout *layout, uint8_t table, double top, double bottom, size_t *first, size_t *last);
/* Where the document ends, after the rows and as much padding again. */
double dt_layout_bottom(const DtLayout *layout, uint8_t table);
/* The hunk a row is in, or -1. */
ptrdiff_t dt_layout_hunk_at(const DtLayout *layout, uint8_t table, size_t index);

/* A place in a table kept in place on the screen: a fraction of the way down a row, screen_y down the view. */
typedef struct {
	size_t index;
	double fraction;
	double screen_y;
	bool valid; /* false for none */
} DtScrollAnchor;

/*
 * What to keep in place while the layout changes, as it's shown from top in a
 * view height tall: the current hunk (or -1) if it's in view, or else the point
 * in the middle of the view. Lay it out anew, then show it from dt_layout_anchor_top.
 */
DtScrollAnchor dt_layout_anchor(const DtLayout *layout, uint8_t table, ptrdiff_t current_hunk, double top, double height);
double dt_layout_anchor_top(const DtLayout *layout, uint8_t table, DtScrollAnchor anchor);
/*
 * Where to show the layout from to bring a hunk into view, a third of the way
 * down a view height tall, in y: false if it's already in view shown from top.
 */
bool dt_layout_scroll_to_hunk(const DtLayout *layout, uint8_t table, size_t hunk, double top, double height, double *y);

/*
 * Fluid mode's scrolling, where each side shows its own lines together, without
 * the side-by-side rows' filler, and the sides scroll to keep lined up.
 *
 * The shared layout is the side-by-side rows, which the views scroll by, and
 * each side's own layout its lines. The side scrolled over with the wheel
 * leads, moving with it, and the others line up with it, the same part of the
 * way through each run of changes, widened into the lines around it so that no
 * side has to jump past lines another has none of. Scrolled some other way, as
 * with the scroller, the sides line up with the shared layout. When they line
 * up anew, they glide into line: while dt_layout_fluid_gliding, call
 * dt_layout_fluid_glide each frame.
 */
/*
 * Where a side shows from in its own layout, gliding or not, with the shared
 * layout scrolled down to y in a view height tall.
 */
double dt_layout_fluid_top(const DtLayout *layout, uint8_t side, double y, double height);
/* What's scrolling, for dt_layout_fluid_scroll. */
enum {
	DT_SCROLL_WHEEL = 0,    /* a mouse's wheel, which stops at the start and end */
	DT_SCROLL_GESTURE = 1,  /* fingers on a trackpad, which stretch past them */
	DT_SCROLL_MOMENTUM = 2, /* momentum after the fingers lift, which bounces off them */
};

/*
 * Scroll down by delta for a wheel over a side, with the pointer pointer down
 * the view. Returns where to scroll the shared layout to, from y. With a
 * trackpad, the side stretches past its start or end, until dt_layout_fluid_release
 * lets it spring back, gliding.
 */
double dt_layout_fluid_scroll(DtLayout *layout, uint8_t side, double delta, uint8_t phase, double pointer, double y,
	double height);
/* The fingers lifted from the trackpad, or momentum ran out: a side stretched past its start or end springs back. */
void dt_layout_fluid_release(DtLayout *layout);
/*
 * The shared layout was scrolled to y, as by the scroller: unless
 * dt_layout_fluid_scroll scrolled it there, the sides line up with it again.
 */
void dt_layout_fluid_scrolled(DtLayout *layout, double y, double height);
/* Line the sides up with the shared layout at once, without gliding, as before it jumps. */
void dt_layout_fluid_line_up(DtLayout *layout);
bool dt_layout_fluid_gliding(const DtLayout *layout);
/* Glide for elapsed seconds. Returns whether the sides are still gliding. */
bool dt_layout_fluid_glide(DtLayout *layout, double elapsed);

#ifdef __cplusplus
}
#endif

#endif
