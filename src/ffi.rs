//! The C interface used by the native front ends. See include/diffotron.h.
//!
//! Getters given an out-of-range index return an empty value rather than failing.

use std::ffi::{CStr, c_char};
use std::path::PathBuf;
use std::ptr;

use crate::diff::{FileDiff, LineKind, Options, Side, Span};
use crate::fluid::Phase;
use crate::layout::{self, Anchor, Layout, Table};
use crate::merge::{self, ChunkKind, Merge};
use crate::merge_result::MergeResult;
use crate::tree::{Comparison, Status};

pub struct DtComparison(Comparison);

/// A diff of two files, or a merge of three.
pub struct DtFileDiff(Diff);

enum Diff {
    Files(FileDiff),
    /// With the index of each hunk's chunk: hunks are the chunks that aren't unchanged.
    Merge(Merge, Vec<usize>),
}

#[repr(C)]
pub struct DtStr {
    ptr: *const c_char,
    len: usize,
}

impl DtStr {
    fn new(s: &str) -> DtStr {
        DtStr { ptr: s.as_ptr().cast(), len: s.len() }
    }

    fn empty() -> DtStr {
        DtStr::new("")
    }
}

#[repr(C)]
pub struct DtEntry {
    path: DtStr,
    dir: DtStr,
    name: DtStr,
    status: u8,
}

const DT_IGNORE_WHITESPACE: u32 = 1 << 0;
const DT_DIFF_IDENTICAL: u32 = 1 << 0;
const DT_DIFF_BINARY: u32 = 1 << 1;

const DT_MAX_SIDES: usize = 3;
const DT_HUNK_CHANGED: u8 = LineKind::Changed as u8;
const DT_HUNK_REMOVED: u8 = LineKind::Removed as u8;
const DT_HUNK_ADDED: u8 = LineKind::Added as u8;
const DT_HUNK_CONFLICT: u8 = 4;

#[repr(C)]
pub struct DtDiffOptions {
    flags: u32,
    tab_width: u32,
}

impl DtDiffOptions {
    fn options(&self) -> Options {
        Options { ignore_whitespace: self.flags & DT_IGNORE_WHITESPACE != 0, tab_width: self.tab_width }
    }
}

#[repr(C)]
pub struct DtLine {
    text: DtStr,
    columns: u32,
    kind: u8,
    span_count: u32,
    spans: *const Span,
}

#[repr(C)]
#[derive(Default)]
pub struct DtHunk {
    row_start: u32,
    row_end: u32,
    unified_start: u32,
    unified_end: u32,
    start: [u32; DT_MAX_SIDES],
    end: [u32; DT_MAX_SIDES],
    kind: u8,
}

#[repr(C)]
pub struct DtMergeChunk {
    kind: u8,
    hunk: i32,
}

/// How a hunk is colored: by its lines on the side before the change and the side after.
fn hunk_kind(before: &std::ops::Range<u32>, after: &std::ops::Range<u32>) -> u8 {
    if before.is_empty() {
        DT_HUNK_ADDED
    } else if after.is_empty() {
        DT_HUNK_REMOVED
    } else {
        DT_HUNK_CHANGED
    }
}

impl Diff {
    fn side(&self, side: u8) -> Option<&Side> {
        match self {
            Diff::Files(diff) => match side {
                0 => Some(&diff.a),
                1 => Some(&diff.b),
                _ => None,
            },
            Diff::Merge(merge, _) => merge.sides.get(side as usize),
        }
    }

    fn error(&self) -> &Option<String> {
        match self {
            Diff::Files(diff) => &diff.error,
            Diff::Merge(merge, _) => &merge.error,
        }
    }

    fn row_count(&self) -> usize {
        match self {
            Diff::Files(diff) => diff.rows.len(),
            Diff::Merge(merge, _) => merge.rows.len(),
        }
    }

    fn row_line(&self, row: usize, side: u8) -> i32 {
        let line = match self {
            Diff::Files(diff) => diff.rows.get(row).and_then(|r| two_way_line(r.a, r.b, side)),
            Diff::Merge(merge, _) => merge.rows.get(row).and_then(|r| r.get(side as usize).copied().flatten()),
        };
        line.map_or(-1, |l| l as i32)
    }

    fn hunk_count(&self) -> usize {
        match self {
            Diff::Files(diff) => diff.hunks.len(),
            Diff::Merge(_, hunks) => hunks.len(),
        }
    }

    fn hunk(&self, index: usize) -> DtHunk {
        match self {
            Diff::Files(diff) => match diff.hunks.get(index) {
                Some(h) => DtHunk {
                    row_start: h.rows.start,
                    row_end: h.rows.end,
                    unified_start: h.unified.start,
                    unified_end: h.unified.end,
                    start: [h.a.start, h.b.start, 0],
                    end: [h.a.end, h.b.end, 0],
                    kind: hunk_kind(&h.a, &h.b),
                },
                None => DtHunk::default(),
            },
            Diff::Merge(merge, hunks) => match hunks.get(index).map(|&c| &merge.chunks[c]) {
                Some(chunk) => {
                    let changed = if chunk.kind == ChunkKind::ChangedInB { merge::B } else { merge::A };
                    DtHunk {
                        row_start: chunk.rows.start,
                        row_end: chunk.rows.end,
                        unified_start: 0,
                        unified_end: 0,
                        start: chunk.lines.clone().map(|r| r.start),
                        end: chunk.lines.clone().map(|r| r.end),
                        kind: if chunk.kind == ChunkKind::Conflict {
                            DT_HUNK_CONFLICT
                        } else {
                            hunk_kind(&chunk.lines[merge::BASE], &chunk.lines[changed])
                        },
                    }
                }
                None => DtHunk::default(),
            },
        }
    }
}

fn two_way_line(a: Option<u32>, b: Option<u32>, side: u8) -> Option<u32> {
    match side {
        0 => a,
        1 => b,
        _ => None,
    }
}

fn error_str(error: &Option<String>) -> DtStr {
    error.as_deref().map(DtStr::new).unwrap_or_else(DtStr::empty)
}

unsafe fn path_from_c(path: *const c_char) -> PathBuf {
    if path.is_null() {
        return PathBuf::new();
    }
    let bytes = unsafe { CStr::from_ptr(path) }.to_bytes();
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        PathBuf::from(std::ffi::OsStr::from_bytes(bytes))
    }
    #[cfg(not(unix))]
    {
        PathBuf::from(String::from_utf8_lossy(bytes).into_owned())
    }
}

/// # Safety
/// The paths must be NUL-terminated strings, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dt_comparison_new(path_a: *const c_char, path_b: *const c_char) -> *mut DtComparison {
    let (a, b) = unsafe { (path_from_c(path_a), path_from_c(path_b)) };
    Box::into_raw(Box::new(DtComparison(Comparison::new(&a, &b))))
}

/// # Safety
/// `cmp` must come from `dt_comparison_new` and not be used afterwards, or be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dt_comparison_free(cmp: *mut DtComparison) {
    if !cmp.is_null() {
        drop(unsafe { Box::from_raw(cmp) });
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_comparison_error(cmp: &DtComparison) -> DtStr {
    error_str(&cmp.0.error)
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_comparison_count(cmp: &DtComparison) -> usize {
    cmp.0.entries.len()
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_comparison_entry(cmp: &DtComparison, index: usize) -> DtEntry {
    match cmp.0.entries.get(index) {
        Some(e) => DtEntry {
            path: DtStr::new(&e.path),
            dir: DtStr::new(e.dir()),
            name: DtStr::new(e.name()),
            status: e.status as u8,
        },
        None => DtEntry { path: DtStr::empty(), dir: DtStr::empty(), name: DtStr::empty(), status: Status::Same as u8 },
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_comparison_entry_path(cmp: &DtComparison, index: usize, side: u8) -> DtStr {
    match cmp.0.entries.get(index).and_then(|e| e.display.get(side as usize)) {
        Some(path) => DtStr::new(path),
        None => DtStr::empty(),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_file_diff_new(cmp: &DtComparison, index: usize, options: DtDiffOptions) -> *mut DtFileDiff {
    let diff = match cmp.0.entries.get(index) {
        Some(e) => FileDiff::load(e.a.as_deref(), e.b.as_deref(), options.options()),
        None => FileDiff { error: Some(format!("No entry {index}")), ..FileDiff::default() },
    };
    Box::into_raw(Box::new(DtFileDiff(Diff::Files(diff))))
}

/// # Safety
/// The paths must be NUL-terminated strings, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dt_merge_new(
    base: *const c_char,
    a: *const c_char,
    b: *const c_char,
    options: DtDiffOptions,
) -> *mut DtFileDiff {
    let (base, a, b) = unsafe { (path_from_c(base), path_from_c(a), path_from_c(b)) };
    let merge = Merge::load(&base, &a, &b, options.options());
    let hunks = (0..merge.chunks.len()).filter(|&c| merge.chunks[c].kind != ChunkKind::Unchanged).collect();
    Box::into_raw(Box::new(DtFileDiff(Diff::Merge(merge, hunks))))
}

/// # Safety
/// `diff` must come from `dt_file_diff_new` or `dt_merge_new` and not be used afterwards, or be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dt_file_diff_free(diff: *mut DtFileDiff) {
    if !diff.is_null() {
        drop(unsafe { Box::from_raw(diff) });
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_file_diff_error(diff: &DtFileDiff) -> DtStr {
    error_str(diff.0.error())
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_file_diff_flags(diff: &DtFileDiff) -> u32 {
    let mut flags = 0;
    if let Diff::Files(diff) = &diff.0 {
        if diff.identical {
            flags |= DT_DIFF_IDENTICAL;
        }
        if diff.binary() {
            flags |= DT_DIFF_BINARY;
        }
    }
    flags
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_file_diff_side_count(diff: &DtFileDiff) -> usize {
    match diff.0 {
        Diff::Files(_) => 2,
        Diff::Merge(..) => 3,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_file_diff_row_count(diff: &DtFileDiff) -> usize {
    diff.0.row_count()
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_file_diff_row_line(diff: &DtFileDiff, row: usize, side: u8) -> i32 {
    diff.0.row_line(row, side)
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_file_diff_unified_count(diff: &DtFileDiff) -> usize {
    match &diff.0 {
        Diff::Files(diff) => diff.unified.len(),
        Diff::Merge(..) => 0,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_file_diff_unified_line(diff: &DtFileDiff, row: usize, side: u8) -> i32 {
    let line = match &diff.0 {
        Diff::Files(diff) => diff.unified.get(row).and_then(|r| two_way_line(r.a, r.b, side)),
        Diff::Merge(..) => None,
    };
    line.map_or(-1, |l| l as i32)
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_file_diff_line_count(diff: &DtFileDiff, side: u8) -> usize {
    diff.0.side(side).map_or(0, |s| s.text.lines.len())
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_file_diff_line(diff: &DtFileDiff, side: u8, index: usize) -> DtLine {
    let side = match diff.0.side(side) {
        Some(side) if index < side.text.lines.len() => side,
        _ => return DtLine { text: DtStr::empty(), columns: 0, kind: 0, span_count: 0, spans: ptr::null() },
    };
    let spans = side.line_spans(index);
    DtLine {
        text: DtStr::new(side.text.line(index)),
        columns: side.columns[index],
        kind: side.kinds[index] as u8,
        span_count: spans.len() as u32,
        spans: spans.as_ptr(),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_file_diff_hunk_count(diff: &DtFileDiff) -> usize {
    diff.0.hunk_count()
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_file_diff_hunk(diff: &DtFileDiff, index: usize) -> DtHunk {
    diff.0.hunk(index)
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_merge_chunk_count(diff: &DtFileDiff) -> usize {
    match &diff.0 {
        Diff::Files(_) => 0,
        Diff::Merge(merge, _) => merge.chunks.len(),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_merge_chunk(diff: &DtFileDiff, index: usize) -> DtMergeChunk {
    match &diff.0 {
        Diff::Merge(merge, hunks) if index < merge.chunks.len() => DtMergeChunk {
            kind: merge.chunks[index].kind as u8,
            hunk: hunks.iter().position(|&c| c == index).map_or(-1, |h| h as i32),
        },
        _ => DtMergeChunk { kind: ChunkKind::Unchanged as u8, hunk: -1 },
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_merge_chunk_text(diff: &DtFileDiff, index: usize, version: u8) -> DtStr {
    match &diff.0 {
        Diff::Merge(merge, _) => match merge.texts.get(index).and_then(|t| t.get(version as usize)) {
            Some(text) => DtStr::new(text),
            None => DtStr::empty(),
        },
        Diff::Files(_) => DtStr::empty(),
    }
}

pub struct DtLayout(Layout);

pub const DT_TABLE_ROWS: u8 = 16;
pub const DT_TABLE_UNIFIED: u8 = 17;

fn table_of(table: u8) -> Table {
    match table {
        DT_TABLE_ROWS => Table::Rows,
        DT_TABLE_UNIFIED => Table::Unified,
        side => Table::Lines(side as usize),
    }
}

#[repr(C)]
pub struct DtScrollAnchor {
    pub index: usize,
    pub fraction: f64,
    pub screen_y: f64,
    pub valid: bool,
}

/// # Safety
/// `diff` must be a diff or null. `line_heights` must point to `dt_file_diff_side_count(diff)`
/// pointers, each to `dt_file_diff_line_count(diff, side)` values, or be null for none.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dt_layout_new(
    diff: *const DtFileDiff,
    line_heights: *const *const f64,
    padding: f64,
    line_height: f64,
) -> *mut DtLayout {
    let Some(diff) = (unsafe { diff.as_ref() }) else {
        let layout = Layout::new(&[], 0, |_, _| None, 0, |_| None, Vec::new(), padding, line_height);
        return Box::into_raw(Box::new(DtLayout(layout)));
    };
    let sides = dt_file_diff_side_count(diff);
    let heights: Vec<&[f64]> = (0..sides)
        .map(|side| {
            let ptr = if line_heights.is_null() { ptr::null() } else { unsafe { *line_heights.add(side) } };
            let len = dt_file_diff_line_count(diff, side as u8);
            if ptr.is_null() { &[] } else { unsafe { std::slice::from_raw_parts(ptr, len) } }
        })
        .collect();
    let hunks = (0..diff.0.hunk_count())
        .map(|i| {
            let h = diff.0.hunk(i);
            layout::Hunk {
                rows: h.row_start as usize..h.row_end as usize,
                unified: h.unified_start as usize..h.unified_end as usize,
                lines: (0..sides).map(|s| h.start[s] as usize..h.end[s] as usize).collect(),
            }
        })
        .collect();
    let row_line = |row: usize, side: usize| usize::try_from(diff.0.row_line(row, side as u8)).ok();
    // A unified row shows side A's line, or else side B's.
    let unified_line = |row: usize| {
        (0..sides as u8).find_map(|side| {
            let line = dt_file_diff_unified_line(diff, row, side);
            usize::try_from(line).ok().map(|line| (side as usize, line))
        })
    };
    let unified = dt_file_diff_unified_count(diff);
    let layout =
        Layout::new(&heights, diff.0.row_count(), row_line, unified, unified_line, hunks, padding, line_height);
    Box::into_raw(Box::new(DtLayout(layout)))
}

/// # Safety
/// `layout` must come from `dt_layout_new` and not be used afterwards, or be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dt_layout_free(layout: *mut DtLayout) {
    if !layout.is_null() {
        drop(unsafe { Box::from_raw(layout) });
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_layout_y(layout: &DtLayout, table: u8, index: usize) -> f64 {
    layout.0.y(table_of(table), index)
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_layout_index_at(layout: &DtLayout, table: u8, y: f64) -> isize {
    layout.0.index_at(table_of(table), y)
}

/// # Safety
/// `first` and `last` must be valid to write to.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dt_layout_range(
    layout: &DtLayout,
    table: u8,
    top: f64,
    bottom: f64,
    first: *mut usize,
    last: *mut usize,
) {
    let range = layout.0.range(table_of(table), top, bottom);
    unsafe {
        *first = range.start;
        *last = range.end;
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_layout_bottom(layout: &DtLayout, table: u8) -> f64 {
    layout.0.bottom(table_of(table))
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_layout_hunk_at(layout: &DtLayout, table: u8, index: usize) -> isize {
    layout.0.hunk_at(table_of(table), index).map_or(-1, |h| h as isize)
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_layout_anchor(
    layout: &DtLayout,
    table: u8,
    current_hunk: isize,
    top: f64,
    height: f64,
) -> DtScrollAnchor {
    let current = usize::try_from(current_hunk).ok();
    match layout.0.anchor(table_of(table), current, top, height) {
        Some(a) => DtScrollAnchor { index: a.index, fraction: a.fraction, screen_y: a.screen_y, valid: true },
        None => DtScrollAnchor { index: 0, fraction: 0.0, screen_y: 0.0, valid: false },
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_layout_anchor_top(layout: &DtLayout, table: u8, anchor: DtScrollAnchor) -> f64 {
    let anchor = Anchor { index: anchor.index, fraction: anchor.fraction, screen_y: anchor.screen_y };
    layout.0.anchor_top(table_of(table), anchor)
}

/// # Safety
/// `y` must be valid to write to.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dt_layout_scroll_to_hunk(
    layout: &DtLayout,
    table: u8,
    hunk: usize,
    top: f64,
    height: f64,
    y: *mut f64,
) -> bool {
    match layout.0.scroll_to_hunk(table_of(table), hunk, top, height) {
        Some(to) => {
            unsafe { *y = to };
            true
        }
        None => false,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_layout_fluid_top(layout: &DtLayout, side: u8, y: f64, height: f64) -> f64 {
    layout.0.fluid.top(side as usize, y, height)
}

pub const DT_SCROLL_WHEEL: u8 = 0;
pub const DT_SCROLL_GESTURE: u8 = 1;
pub const DT_SCROLL_MOMENTUM: u8 = 2;

#[unsafe(no_mangle)]
pub extern "C" fn dt_layout_fluid_scroll(
    layout: &mut DtLayout,
    side: u8,
    delta: f64,
    phase: u8,
    pointer: f64,
    y: f64,
    height: f64,
) -> f64 {
    let phase = match phase {
        DT_SCROLL_GESTURE => Phase::Gesture,
        DT_SCROLL_MOMENTUM => Phase::Momentum,
        _ => Phase::Wheel,
    };
    layout.0.fluid.scroll(side as usize, delta, phase, pointer, y, height)
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_layout_fluid_release(layout: &mut DtLayout) {
    layout.0.fluid.release()
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_layout_fluid_scrolled(layout: &mut DtLayout, y: f64, height: f64) {
    layout.0.fluid.scrolled(y, height)
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_layout_fluid_line_up(layout: &mut DtLayout) {
    layout.0.fluid.line_up()
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_layout_fluid_gliding(layout: &DtLayout) -> bool {
    layout.0.fluid.gliding()
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_layout_fluid_glide(layout: &mut DtLayout, elapsed: f64) -> bool {
    layout.0.fluid.glide(elapsed)
}

pub struct DtMergeResult {
    result: MergeResult,
    error: Option<String>,
}

#[repr(C)]
pub struct DtStr16 {
    pub ptr: *const u16,
    pub len: usize,
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_merge_result_new(diff: &DtFileDiff) -> *mut DtMergeResult {
    let result = match &diff.0 {
        Diff::Merge(merge, _) => MergeResult::new(merge),
        Diff::Files(_) => MergeResult::default(),
    };
    Box::into_raw(Box::new(DtMergeResult { result, error: None }))
}

/// # Safety
/// `result` must come from `dt_merge_result_new` and not be used afterwards, or be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dt_merge_result_free(result: *mut DtMergeResult) {
    if !result.is_null() {
        drop(unsafe { Box::from_raw(result) });
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_merge_result_text(result: &DtMergeResult) -> DtStr16 {
    let text = result.result.text();
    DtStr16 { ptr: text.as_ptr(), len: text.len() }
}

/// # Safety
/// `text` must point to `text_len` UTF-16 code units, or be null if there are none.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dt_merge_result_replace(
    result: &mut DtMergeResult,
    start: usize,
    length: usize,
    text: *const u16,
    text_len: usize,
) {
    let text = if text.is_null() { &[] } else { unsafe { std::slice::from_raw_parts(text, text_len) } };
    result.result.replace(start, length, text);
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_merge_result_hunk_count(result: &DtMergeResult) -> usize {
    result.result.hunk_count()
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_merge_result_hunk_at(result: &DtMergeResult, position: usize) -> isize {
    result.result.hunk_at(position).map_or(-1, |h| h as isize)
}

/// # Safety
/// `start` and `length` must be valid to write to.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dt_merge_result_hunk_range(
    result: &DtMergeResult,
    hunk: usize,
    start: *mut usize,
    length: *mut usize,
) -> bool {
    match result.result.hunk_range(hunk) {
        Some(range) => {
            unsafe {
                *start = range.start;
                *length = range.len();
            }
            true
        }
        None => false,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_merge_result_version(result: &DtMergeResult, hunk: usize, version: u8) -> DtStr {
    result.result.version(hunk, version as usize).map_or_else(DtStr::empty, DtStr::new)
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_merge_result_unresolved(result: &DtMergeResult, hunk: usize) -> bool {
    result.result.unresolved(hunk)
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_merge_result_conflict_count(result: &DtMergeResult) -> usize {
    result.result.conflict_count()
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_merge_result_has_conflict_markers(result: &DtMergeResult) -> bool {
    result.result.has_conflict_markers()
}

/// # Safety
/// `path` must be a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dt_merge_result_save(result: &mut DtMergeResult, path: *const c_char) -> bool {
    let path = unsafe { path_from_c(path) };
    result.error = result.result.save(&path).err();
    result.error.is_none()
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_merge_result_error(result: &DtMergeResult) -> DtStr {
    error_str(&result.error)
}
