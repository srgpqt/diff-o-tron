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
typedef struct DtFluid DtFluid;

typedef struct {
	const char *ptr;
	size_t len;
} DtStr;

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
 * paired changed lines shows its A lines and then its B lines, and so does
 * each run of unpaired lines.
 */
size_t dt_file_diff_unified_count(const DtFileDiff *diff);
int32_t dt_file_diff_unified_line(const DtFileDiff *diff, size_t row, uint8_t side);
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
 * Fluid mode's scrolling, where each side shows its own lines together, without
 * the side-by-side rows' filler, and the sides scroll to keep lined up.
 *
 * Positions are in points down the document, as the front end lays it out: the
 * shared layout is the side-by-side rows, which the views scroll by, and each
 * side's own layout its lines. The side scrolled over with the wheel leads,
 * moving with it, and the others line up with it, the same part of the way
 * through each run of changes. Scrolled some other way, as with the scroller,
 * the sides line up with the shared layout. When they line up anew, they glide
 * into line: while dt_fluid_gliding, call dt_fluid_glide each frame.
 *
 * row_tops has where each of the diff's rows starts, then where the last ends;
 * line_tops has, for each side, the same for its lines. padding is the space
 * after the last row, and after each side's last line; line_height, a line's
 * height without wrapping, sets how far runs of changes are widened into the
 * lines around them so that no side has to jump past lines another has none of.
 * Never returns NULL.
 */
DtFluid *dt_fluid_new(const DtFileDiff *diff, const double *row_tops, const double *const *line_tops,
	double padding, double line_height);
void dt_fluid_free(DtFluid *fluid);
/*
 * Where a side shows from in its own layout, gliding or not, with the shared
 * layout scrolled down to y in a view height tall.
 */
double dt_fluid_top(const DtFluid *fluid, uint8_t side, double y, double height);
/*
 * Scroll down by delta for a wheel over a side, with the pointer pointer down
 * the view. Returns where to scroll the shared layout to, from y.
 */
double dt_fluid_scroll(DtFluid *fluid, uint8_t side, double delta, double pointer, double y, double height);
/*
 * The shared layout was scrolled to y, as by the scroller: unless
 * dt_fluid_scroll scrolled it there, the sides line up with it again.
 */
void dt_fluid_scrolled(DtFluid *fluid, double y, double height);
bool dt_fluid_gliding(const DtFluid *fluid);
/* Glide for elapsed seconds. Returns whether the sides are still gliding. */
bool dt_fluid_glide(DtFluid *fluid, double elapsed);

#ifdef __cplusplus
}
#endif

#endif
