/*
 * Diff-o-tron core library: the platform-independent comparison and diff engine,
 * implemented in Rust (src/ffi.rs).
 *
 * Strings are UTF-8 and not NUL-terminated. Everything returned by a getter
 * stays valid until the object it came from is freed.
 */

#ifndef DIFFOTRON_H
#define DIFFOTRON_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DtComparison DtComparison;
typedef struct DtFileDiff DtFileDiff;

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
};

/*
 * Sides of a comparison. Functions taking a side are indexed so that more
 * sides (a merge base and result) can be added later.
 */
enum {
	DT_SIDE_A = 0,
	DT_SIDE_B = 1,
};

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

/* A block of consecutive changed rows. Ranges are half-open. */
typedef struct {
	uint32_t row_start, row_end;
	uint32_t a_start, a_end;
	uint32_t b_start, b_end;
} DtHunk;

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
void dt_file_diff_free(DtFileDiff *diff);
DtStr dt_file_diff_error(const DtFileDiff *diff); /* empty if none */
uint32_t dt_file_diff_flags(const DtFileDiff *diff);
/* Rows of the side-by-side view, each showing a line from one or more sides. */
size_t dt_file_diff_row_count(const DtFileDiff *diff);
/* The index of the line a row shows on a side, or -1 for none. */
int32_t dt_file_diff_row_line(const DtFileDiff *diff, size_t row, uint8_t side);
size_t dt_file_diff_line_count(const DtFileDiff *diff, uint8_t side);
DtLine dt_file_diff_line(const DtFileDiff *diff, uint8_t side, size_t index);
size_t dt_file_diff_hunk_count(const DtFileDiff *diff);
DtHunk dt_file_diff_hunk(const DtFileDiff *diff, size_t index);

#ifdef __cplusplus
}
#endif

#endif
