//! The C interface used by the native front ends. See include/diffotron.h.
//!
//! Getters given an out-of-range index return an empty value rather than failing.

use std::ffi::{CStr, c_char};
use std::path::PathBuf;
use std::ptr;

use crate::diff::{FileDiff, Options, Side, Span};
use crate::tree::{Comparison, Status};

pub struct DtComparison(Comparison);
pub struct DtFileDiff(FileDiff);

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

#[repr(C)]
pub struct DtDiffOptions {
    flags: u32,
    tab_width: u32,
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
    a_start: u32,
    a_end: u32,
    b_start: u32,
    b_end: u32,
}

fn diff_side(diff: &DtFileDiff, side: u8) -> Option<&Side> {
    match side {
        0 => Some(&diff.0.a),
        1 => Some(&diff.0.b),
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
    let options =
        Options { ignore_whitespace: options.flags & DT_IGNORE_WHITESPACE != 0, tab_width: options.tab_width };
    let diff = match cmp.0.entries.get(index) {
        Some(e) => FileDiff::load(e.a.as_deref(), e.b.as_deref(), options),
        None => FileDiff { error: Some(format!("No entry {index}")), ..FileDiff::default() },
    };
    Box::into_raw(Box::new(DtFileDiff(diff)))
}

/// # Safety
/// `diff` must come from `dt_file_diff_new` and not be used afterwards, or be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dt_file_diff_free(diff: *mut DtFileDiff) {
    if !diff.is_null() {
        drop(unsafe { Box::from_raw(diff) });
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_file_diff_error(diff: &DtFileDiff) -> DtStr {
    error_str(&diff.0.error)
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_file_diff_flags(diff: &DtFileDiff) -> u32 {
    let mut flags = 0;
    if diff.0.identical {
        flags |= DT_DIFF_IDENTICAL;
    }
    if diff.0.binary() {
        flags |= DT_DIFF_BINARY;
    }
    flags
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_file_diff_row_count(diff: &DtFileDiff) -> usize {
    diff.0.rows.len()
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_file_diff_row_line(diff: &DtFileDiff, row: usize, side: u8) -> i32 {
    let line = diff.0.rows.get(row).and_then(|r| match side {
        0 => r.a,
        1 => r.b,
        _ => None,
    });
    line.map_or(-1, |l| l as i32)
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_file_diff_line_count(diff: &DtFileDiff, side: u8) -> usize {
    diff_side(diff, side).map_or(0, |s| s.text.lines.len())
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_file_diff_line(diff: &DtFileDiff, side: u8, index: usize) -> DtLine {
    let side = match diff_side(diff, side) {
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
    diff.0.hunks.len()
}

#[unsafe(no_mangle)]
pub extern "C" fn dt_file_diff_hunk(diff: &DtFileDiff, index: usize) -> DtHunk {
    match diff.0.hunks.get(index) {
        Some(h) => DtHunk {
            row_start: h.rows.start,
            row_end: h.rows.end,
            a_start: h.a.start,
            a_end: h.a.end,
            b_start: h.b.start,
            b_end: h.b.end,
        },
        None => DtHunk::default(),
    }
}
