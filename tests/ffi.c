/*
 * Exercises the C interface of the core library through include/diffotron.h,
 * to catch mismatches between the header and src/ffi.rs.
 *
 * Usage: ffi <scratch directory>
 */

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
	CHECK(hunk.a_start == 3 && hunk.a_end == 3);
	CHECK(hunk.b_start == 3 && hunk.b_end == 4);

	dt_file_diff_free(diff);
	dt_comparison_free(cmp);

	cmp = dt_comparison_new(path_a, "/nonexistent/diffotron");
	CHECK(dt_comparison_error(cmp).len > 0);
	CHECK(dt_comparison_count(cmp) == 0);
	dt_comparison_free(cmp);

	if (failures) {
		fprintf(stderr, "%d check(s) failed\n", failures);
		return 1;
	}
	printf("ffi: all checks passed\n");
	return 0;
}
