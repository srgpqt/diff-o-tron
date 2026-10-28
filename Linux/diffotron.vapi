/*
 * Vala bindings for the core library's C interface, include/diffotron.h, which
 * documents it. Strings are UTF-8 and not NUL-terminated: see text() in
 * Linux/Core.vala.
 */
[CCode (cheader_filename = "diffotron.h", lower_case_cprefix = "dt_")]
namespace Dt {
	[CCode (cname = "DT_STATUS_SAME")] public const uint8 STATUS_SAME;
	[CCode (cname = "DT_STATUS_MODIFIED")] public const uint8 STATUS_MODIFIED;
	[CCode (cname = "DT_STATUS_ADDED")] public const uint8 STATUS_ADDED;
	[CCode (cname = "DT_STATUS_REMOVED")] public const uint8 STATUS_REMOVED;

	[CCode (cname = "DT_LINE_EQUAL")] public const uint8 LINE_EQUAL;
	[CCode (cname = "DT_LINE_CHANGED")] public const uint8 LINE_CHANGED;
	[CCode (cname = "DT_LINE_REMOVED")] public const uint8 LINE_REMOVED;
	[CCode (cname = "DT_LINE_ADDED")] public const uint8 LINE_ADDED;
	[CCode (cname = "DT_LINE_CONFLICT")] public const uint8 LINE_CONFLICT;

	[CCode (cname = "DT_SIDE_A")] public const uint8 SIDE_A;
	[CCode (cname = "DT_SIDE_B")] public const uint8 SIDE_B;
	[CCode (cname = "DT_MERGE_BASE")] public const uint8 MERGE_BASE;
	[CCode (cname = "DT_MERGE_A")] public const uint8 MERGE_A;
	[CCode (cname = "DT_MERGE_B")] public const uint8 MERGE_B;
	[CCode (cname = "DT_MAX_SIDES")] public const int MAX_SIDES;

	[CCode (cname = "DT_IGNORE_WHITESPACE")] public const uint32 IGNORE_WHITESPACE;
	[CCode (cname = "DT_DIFF_IDENTICAL")] public const uint32 DIFF_IDENTICAL;
	[CCode (cname = "DT_DIFF_BINARY")] public const uint32 DIFF_BINARY;

	[CCode (cname = "DT_HUNK_CHANGED")] public const uint8 HUNK_CHANGED;
	[CCode (cname = "DT_HUNK_REMOVED")] public const uint8 HUNK_REMOVED;
	[CCode (cname = "DT_HUNK_ADDED")] public const uint8 HUNK_ADDED;
	[CCode (cname = "DT_HUNK_CONFLICT")] public const uint8 HUNK_CONFLICT;

	[CCode (cname = "DT_VERSION_BASE")] public const uint8 VERSION_BASE;
	[CCode (cname = "DT_VERSION_A")] public const uint8 VERSION_A;
	[CCode (cname = "DT_VERSION_B")] public const uint8 VERSION_B;
	[CCode (cname = "DT_VERSION_MERGED")] public const uint8 VERSION_MERGED;

	[CCode (cname = "DT_TABLE_ROWS")] public const uint8 TABLE_ROWS;
	[CCode (cname = "DT_TABLE_UNIFIED")] public const uint8 TABLE_UNIFIED;

	[CCode (cname = "DT_SCROLL_WHEEL")] public const uint8 SCROLL_WHEEL;
	[CCode (cname = "DT_SCROLL_GESTURE")] public const uint8 SCROLL_GESTURE;
	[CCode (cname = "DT_SCROLL_MOMENTUM")] public const uint8 SCROLL_MOMENTUM;

	[SimpleType]
	[CCode (cname = "DtStr", has_type_id = false)]
	public struct Str {
		public char* ptr;
		public size_t len;
	}

	[SimpleType]
	[CCode (cname = "DtStr16", has_type_id = false)]
	public struct Str16 {
		public uint16* ptr;
		public size_t len;
	}

	[SimpleType]
	[CCode (cname = "DtEntry", has_type_id = false)]
	public struct Entry {
		public Str path;
		public Str dir;
		public Str name;
		public uint8 status;
	}

	[SimpleType]
	[CCode (cname = "DtItem", has_type_id = false)]
	public struct Item {
		public Str title;
		public ssize_t entry;
	}

	[SimpleType]
	[CCode (cname = "DtDiffOptions", has_type_id = false)]
	public struct DiffOptions {
		public uint32 flags;
		public uint32 tab_width;
	}

	[SimpleType]
	[CCode (cname = "DtSpan", has_type_id = false)]
	public struct Span {
		public uint32 start;
		public uint32 end;
		public uint32 start16;
		public uint32 end16;
	}

	[SimpleType]
	[CCode (cname = "DtLine", has_type_id = false)]
	public struct Line {
		public Str text;
		public uint32 columns;
		public uint8 kind;
		public uint32 span_count;
		[CCode (array_length = false)]
		public unowned Span[] spans;
	}

	[SimpleType]
	[CCode (cname = "DtHunk", has_type_id = false)]
	public struct Hunk {
		public uint32 row_start;
		public uint32 row_end;
		public uint32 unified_start;
		public uint32 unified_end;
		public uint32 start[3];
		public uint32 end[3];
		public uint8 kind;
	}

	[SimpleType]
	[CCode (cname = "DtMergeChunk", has_type_id = false)]
	public struct MergeChunk {
		public uint8 kind;
		public int32 hunk;
	}

	[SimpleType]
	[CCode (cname = "DtScrollAnchor", has_type_id = false)]
	public struct ScrollAnchor {
		public size_t index;
		public double fraction;
		public double screen_y;
		public bool valid;
	}

	[Compact]
	[CCode (cname = "DtComparison", free_function = "dt_comparison_free")]
	public class Comparison {
		[CCode (cname = "dt_comparison_new")]
		public Comparison (string path_a, string path_b);
		public Str error ();
		public size_t count ();
		public Entry entry (size_t index);
		public Str entry_path (size_t index, uint8 side);
		public size_t item_count ();
		public Item item (size_t index);
	}

	[Compact]
	[CCode (cname = "DtFileDiff", free_function = "dt_file_diff_free", lower_case_cprefix = "dt_file_diff_")]
	public class FileDiff {
		[CCode (cname = "dt_file_diff_new")]
		public FileDiff (Comparison cmp, size_t index, DiffOptions options);
		[CCode (cname = "dt_merge_new")]
		public FileDiff.merge (string base_path, string a, string b, DiffOptions options);
		public Str error ();
		public uint32 flags ();
		public size_t side_count ();
		public size_t row_count ();
		public int32 row_line (size_t row, uint8 side);
		public size_t unified_count ();
		public int32 unified_line (size_t row, uint8 side);
		public ssize_t unified_group (size_t row);
		public ssize_t nearest_hunk (bool unified, size_t row);
		public size_t line_count (uint8 side);
		public Line line (uint8 side, size_t index);
		public size_t hunk_count ();
		public Hunk hunk (size_t index);
		[CCode (cname = "dt_merge_chunk_count")]
		public size_t merge_chunk_count ();
		[CCode (cname = "dt_merge_chunk")]
		public MergeChunk merge_chunk (size_t index);
		[CCode (cname = "dt_merge_chunk_text")]
		public Str merge_chunk_text (size_t index, uint8 version);
	}

	[Compact]
	[CCode (cname = "DtMergeResult", free_function = "dt_merge_result_free", lower_case_cprefix = "dt_merge_result_")]
	public class MergeResult {
		[CCode (cname = "dt_merge_result_new")]
		public MergeResult (FileDiff merge);
		public Str16 text ();
		public void replace (size_t start, size_t length, [CCode (array_length_type = "size_t")] uint16[] text);
		public size_t hunk_count ();
		public ssize_t hunk_at (size_t position);
		public bool hunk_range (size_t hunk, out size_t start, out size_t length);
		public Str version (size_t hunk, uint8 version);
		public bool unresolved (size_t hunk);
		public size_t conflict_count ();
		public bool has_conflict_markers ();
		public bool save (string path);
		public Str error ();
	}

	[Compact]
	[CCode (cname = "DtLayout", free_function = "dt_layout_free", lower_case_cprefix = "dt_layout_")]
	public class Layout {
		/* line_heights: a pointer to each side's line heights, as doubles. */
		[CCode (cname = "dt_layout_new")]
		public Layout (FileDiff? diff, [CCode (array_length = false, type = "const double* const*")] void*[]? line_heights, double padding, double line_height);
		public double y (uint8 table, size_t index);
		public ssize_t index_at (uint8 table, double y);
		public void range (uint8 table, double top, double bottom, out size_t first, out size_t last);
		public double bottom (uint8 table);
		public ssize_t hunk_at (uint8 table, size_t index);
		public ScrollAnchor anchor (uint8 table, ssize_t current_hunk, double top, double height);
		public double anchor_top (uint8 table, ScrollAnchor anchor);
		public bool scroll_to_hunk (uint8 table, size_t hunk, double top, double height, out double y);
		public double fluid_top (uint8 side, double y, double height);
		public double fluid_scroll (uint8 side, double delta, uint8 phase, double pointer, double y, double height);
		public void fluid_release ();
		public void fluid_scrolled (double y, double height);
		public void fluid_line_up ();
		public bool fluid_gliding ();
		public bool fluid_glide (double elapsed);
	}
}
