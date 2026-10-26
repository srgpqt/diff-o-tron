//! Diff-o-tron's platform-independent core, linked into each native front end as a static library.

pub mod diff;
pub mod ffi;
pub mod text;
pub mod tree;

// delta's within-line edit inference, compiled straight from the vendored source. These modules
// refer to each other as `crate::align` and `crate::minusplus`, so they live at the crate root.
// They're skipped by rustfmt to leave the submodule untouched.
#[rustfmt::skip]
#[path = "../vendor/delta/src/align.rs"]
mod align;
#[rustfmt::skip]
#[path = "../vendor/delta/src/edits.rs"]
#[allow(dead_code)]
mod edits;
#[rustfmt::skip]
#[path = "../vendor/delta/src/minusplus.rs"]
#[allow(dead_code)]
mod minusplus;
