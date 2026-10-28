/*
 * Exercises the C interface of the core library through include/diffotron.h,
 * to catch mismatches between the header and src/ffi.rs.
 *
 * Usage: ffi <scratch directory>
 */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "diffotron.h"

static int failures = 0;

#define CHECK(cond) do { \
	if (!(cond)) { \
		fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
		failures++; \
	} \
} while (0)

static int str_eq(DtStr s, const char *expected) {
	return s.len == strlen(expected) && memcmp(s.ptr, expected, s.len) == 0;
}

static void write_file(const char *path, const char *contents) {
	FILE *f = fopen(path, "wb");
	if (!f) {
		perror(path);
		exit(1);
	}
	fputs(contents, f);
	fclose(f);
}

int main(int argc, char **argv) {
	if (argc != 2) {
		fprintf(stderr, "usage: %s <scratch directory>\n", argv[0]);
		return 2;
	}

	char path_a[4096], path_b[4096];
	snprintf(path_a, sizeof path_a, "%s/a.txt", argv[1]);
	snprintf(path_b, sizeof path_b, "%s/b.txt", argv[1]);
	write_file(path_a, "one\nlet x = foo(1);\nthree\n");
	write_file(path_b, "one\nlet x = bar(1);\nthree\nfour\n");

	DtComparison *cmp = dt_comparison_new(path_a, path_b);
	CHECK(dt_comparison_error(cmp).len == 0);
	CHECK(dt_comparison_count(cmp) == 1);

	DtEntry entry = dt_comparison_entry(cmp, 0);
	CHECK(str_eq(entry.path, "a.txt → b.txt"));
	CHECK(str_eq(entry.dir, ""));
	CHECK(entry.status == DT_STATUS_MODIFIED);
	CHECK(str_eq(dt_comparison_entry_path(cmp, 0, DT_SIDE_A), path_a));
	CHECK(str_eq(dt_comparison_entry_path(cmp, 0, DT_SIDE_B), path_b));
	CHECK(dt_comparison_entry_path(cmp, 0, 7).len == 0);

	DtDiffOptions options = { 0, 4 };
	DtFileDiff *diff = dt_file_diff_new(cmp, 0, options);
	CHECK(dt_file_diff_error(diff).len == 0);
	CHECK(dt_file_diff_flags(diff) == 0);
	CHECK(dt_file_diff_line_count(diff, DT_SIDE_A) == 3);
	CHECK(dt_file_diff_line_count(diff, DT_SIDE_B) == 4);

	CHECK(dt_file_diff_row_count(diff) == 4);
	CHECK(dt_file_diff_row_line(diff, 3, DT_SIDE_A) == -1);
	CHECK(dt_file_diff_row_line(diff, 3, DT_SIDE_B) == 3);
	CHECK(dt_file_diff_row_line(diff, 0, DT_SIDE_B) == 0);
	CHECK(dt_file_diff_row_line(diff, 99, DT_SIDE_B) == -1);

	DtLine line = dt_file_diff_line(diff, DT_SIDE_B, 1);
	CHECK(str_eq(line.text, "let x = bar(1);"));
	CHECK(line.kind == DT_LINE_CHANGED);
	CHECK(line.columns == 15);
	CHECK(line.span_count == 1);
	if (line.span_count == 1) {
		CHECK(line.spans[0].start == 8 && line.spans[0].end == 11);
		CHECK(line.spans[0].start16 == 8 && line.spans[0].end16 == 11);
	}
	CHECK(dt_file_diff_line(diff, DT_SIDE_B, 3).kind == DT_LINE_ADDED);
	CHECK(dt_file_diff_line(diff, DT_SIDE_B, 99).text.len == 0);

	CHECK(dt_file_diff_hunk_count(diff) == 2);
	DtHunk hunk = dt_file_diff_hunk(diff, 1);
	CHECK(hunk.row_start == 3 && hunk.row_end == 4);
	CHECK(hunk.start[DT_SIDE_A] == 3 && hunk.end[DT_SIDE_A] == 3);
	CHECK(hunk.start[DT_SIDE_B] == 3 && hunk.end[DT_SIDE_B] == 4);
	CHECK(hunk.kind == DT_HUNK_ADDED);
	CHECK(dt_file_diff_hunk(diff, 0).kind == DT_HUNK_CHANGED);
	CHECK(dt_file_diff_side_count(diff) == 2);
	CHECK(dt_merge_chunk_count(diff) == 0);
	/* one, the changed line on side A then on side B, three, four */
	CHECK(hunk.unified_start == 4 && hunk.unified_end == 5);
	CHECK(dt_file_diff_unified_count(diff) == 5);
	CHECK(dt_file_diff_unified_line(diff, 1, DT_SIDE_A) == 1 && dt_file_diff_unified_line(diff, 1, DT_SIDE_B) == -1);
	CHECK(dt_file_diff_unified_line(diff, 2, DT_SIDE_A) == -1 && dt_file_diff_unified_line(diff, 2, DT_SIDE_B) == 1);
	CHECK(dt_file_diff_unified_line(diff, 3, DT_SIDE_A) == 2 && dt_file_diff_unified_line(diff, 3, DT_SIDE_B) == 2);
	CHECK(dt_file_diff_unified_line(diff, 99, DT_SIDE_A) == -1);

	/* The layout, with lines 10 points tall after 4 of padding, in a view 20 points tall. */
	double heights[2][64];
	for (uint8_t side = 0; side < 2; side++) {
		for (size_t i = 0; i < dt_file_diff_line_count(diff, side) && i < 64; i++) heights[side][i] = 10;
	}
	const double *line_heights[2] = {heights[0], heights[1]};
	DtLayout *layout = dt_layout_new(diff, line_heights, 4, 10);
	size_t rows = dt_file_diff_row_count(diff);
	CHECK(fabs(dt_layout_y(layout, DT_TABLE_ROWS, 1) - 14) < 1e-9);
	CHECK(fabs(dt_layout_y(layout, DT_SIDE_B, 2) - 24) < 1e-9);
	CHECK(fabs(dt_layout_bottom(layout, DT_TABLE_ROWS) - (8 + 10 * (double)rows)) < 1e-9);
	CHECK(dt_layout_index_at(layout, DT_TABLE_ROWS, 0) == -1 && dt_layout_index_at(layout, DT_TABLE_ROWS, 15) == 1);
	size_t first = 0, last = 0;
	dt_layout_range(layout, DT_TABLE_ROWS, 15, 25, &first, &last);
	CHECK(first == 1 && last == 3);
	CHECK(dt_layout_hunk_at(layout, DT_TABLE_ROWS, hunk.row_start) == 1);
	CHECK(dt_layout_hunk_at(layout, DT_TABLE_ROWS, 0) == -1);
	/* Hunk 1, at 34, is out of view: the middle of the view instead, 60% down row 0. */
	DtScrollAnchor anchor = dt_layout_anchor(layout, DT_TABLE_ROWS, 1, 0, 20);
	CHECK(anchor.valid && anchor.index == 0);
	CHECK(fabs(dt_layout_anchor_top(layout, DT_TABLE_ROWS, anchor)) < 1e-9);
	double to = 0;
	CHECK(dt_layout_scroll_to_hunk(layout, DT_TABLE_ROWS, 1, 0, 20, &to) && fabs(to - 28) < 1e-9);
	CHECK(!dt_layout_scroll_to_hunk(layout, DT_TABLE_ROWS, 1, 30, 20, &to));

	/* Fluid scrolling. */
	CHECK(fabs(dt_layout_fluid_top(layout, DT_SIDE_A, 0, 20)) < 1e-9 && fabs(dt_layout_fluid_top(layout, DT_SIDE_B, 0, 20)) < 1e-9);
	CHECK(!dt_layout_fluid_gliding(layout));
	double y = dt_layout_fluid_scroll(layout, DT_SIDE_B, 10, 5, 0, 20);
	CHECK(y > 0);
	CHECK(fabs(dt_layout_fluid_top(layout, DT_SIDE_B, y, 20) - 10) < 1e-9);
	dt_layout_fluid_scrolled(layout, y, 20);
	CHECK(fabs(dt_layout_fluid_top(layout, DT_SIDE_B, y, 20) - 10) < 1e-9);
	CHECK(!dt_layout_fluid_glide(layout, 1));
	dt_layout_free(layout);
	dt_layout_free(NULL);

	DtLayout *empty = dt_layout_new(NULL, NULL, 4, 10);
	CHECK(fabs(dt_layout_y(empty, DT_TABLE_ROWS, 3) - 4) < 1e-9);
	CHECK(!dt_layout_anchor(empty, DT_TABLE_ROWS, -1, 0, 20).valid);
	dt_layout_free(empty);

	dt_file_diff_free(diff);
	dt_comparison_free(cmp);

	cmp = dt_comparison_new(path_a, "/nonexistent/diffotron");
	CHECK(dt_comparison_error(cmp).len > 0);
	CHECK(dt_comparison_count(cmp) == 0);
	dt_comparison_free(cmp);

	/* A merge: line two changed differently on each side, line three only in B. */
	char path_base[4096];
	snprintf(path_base, sizeof path_base, "%s/base.txt", argv[1]);
	write_file(path_base, "one\ntwo\nthree\nfour\nfive\n");
	write_file(path_a, "one\nTWO\nthree\nfour\nfive\n");
	write_file(path_b, "one\n2\nthree\nfour\n5\n");
	DtFileDiff *merge = dt_merge_new(path_base, path_a, path_b, options);
	CHECK(dt_file_diff_error(merge).len == 0);
	CHECK(dt_file_diff_side_count(merge) == 3);
	CHECK(dt_file_diff_unified_count(merge) == 0);
	CHECK(dt_file_diff_row_count(merge) == 5);
	CHECK(dt_file_diff_hunk_count(merge) == 2);
	DtHunk conflict = dt_file_diff_hunk(merge, 0);
	CHECK(conflict.kind == DT_HUNK_CONFLICT);
	CHECK(conflict.start[DT_MERGE_BASE] == 1 && conflict.end[DT_MERGE_BASE] == 2);
	CHECK(conflict.start[DT_MERGE_B] == 1 && conflict.end[DT_MERGE_B] == 2);
	CHECK(dt_file_diff_hunk(merge, 1).kind == DT_HUNK_CHANGED);

	CHECK(dt_merge_chunk_count(merge) == 4);
	DtMergeChunk chunk = dt_merge_chunk(merge, 1);
	CHECK(chunk.kind == DT_CHUNK_CONFLICT && chunk.hunk == 0);
	CHECK(dt_merge_chunk(merge, 2).kind == DT_CHUNK_UNCHANGED && dt_merge_chunk(merge, 2).hunk == -1);
	CHECK(dt_merge_chunk(merge, 3).kind == DT_CHUNK_CHANGED_IN_B && dt_merge_chunk(merge, 3).hunk == 1);
	CHECK(str_eq(dt_merge_chunk_text(merge, 1, DT_VERSION_A), "TWO\n"));
	CHECK(str_eq(dt_merge_chunk_text(merge, 1, DT_VERSION_MERGED), "<<<<<<< A\nTWO\n=======\n2\n>>>>>>> B\n"));
	CHECK(str_eq(dt_merge_chunk_text(merge, 3, DT_VERSION_MERGED), "5\n"));
	dt_file_diff_free(merge);

	if (failures) {
		fprintf(stderr, "%d check(s) failed\n", failures);
		return 1;
	}
	printf("ffi: all checks passed\n");
	return 0;
}
