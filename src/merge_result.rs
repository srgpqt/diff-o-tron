//! A merge's merged result as the front end's text editor edits it. The result keeps a copy of
//! the text, told of each edit, to keep track of where each of the merge's chunks is in it, to
//! find the conflicts left unresolved, and to save it as the file was.
//!
//! Positions and lengths are in UTF-16 code units, as text editors count them.

use std::fs;
use std::ops::Range;
use std::path::Path;

use crate::merge::{ChunkKind, Merge, VERSION_MERGED};

/// How an unresolved conflict's lines start.
const CONFLICT_MARKER: &str = "<<<<<<< ";

/// A chunk of the merge, where it is in the text.
#[derive(Debug)]
struct Segment {
    range: Range<usize>,
    /// The change it is, or `None` if it's unchanged.
    hunk: Option<usize>,
    /// Its text in each version, indexed by `merge::VERSION_*`.
    versions: [String; 4],
}

#[derive(Debug, Default)]
pub struct MergeResult {
    text: Vec<u16>,
    /// In order, tiling the text.
    segments: Vec<Segment>,
    crlf: bool,
    latin1: bool,
}

impl MergeResult {
    /// The merged result as the merge starts it.
    pub fn new(merge: &Merge) -> MergeResult {
        let mut text = Vec::new();
        let mut segments = Vec::new();
        let mut hunks = 0;
        for (chunk, versions) in merge.chunks.iter().zip(&merge.texts) {
            let start = text.len();
            text.extend(versions[VERSION_MERGED].encode_utf16());
            let hunk = (chunk.kind != ChunkKind::Unchanged).then(|| {
                hunks += 1;
                hunks - 1
            });
            segments.push(Segment { range: start..text.len(), hunk, versions: versions.clone() });
        }
        MergeResult { text, segments, crlf: merge.crlf, latin1: merge.latin1 }
    }

    pub fn text(&self) -> &[u16] {
        &self.text
    }

    /// The text was edited: `length` units from `start` replaced with `new`.
    ///
    /// The chunks move with the text. A boundary between chunks before the edit stays put, one
    /// after it moves with the text after it, and one inside it moves to the end of the new
    /// text. Text inserted where a chunk is empty, as a removed change is, goes into that chunk.
    pub fn replace(&mut self, start: usize, length: usize, new: &[u16]) {
        let old_start = start.min(self.text.len());
        let old_end = (start + length).min(self.text.len());
        let new_end = old_start + new.len();
        let shift = |position: usize| position + new_end - old_end;
        self.text.splice(old_start..old_end, new.iter().copied());

        let target = (old_start == old_end)
            .then(|| self.segments.iter().position(|s| s.range.is_empty() && s.range.start == old_start))
            .flatten();
        for (i, segment) in self.segments.iter_mut().enumerate() {
            let Range { start, end } = segment.range;
            segment.range = match target {
                Some(t) if i == t => start..new_end,
                Some(t) if i > t => shift(start)..shift(end),
                Some(_) => start..end,
                None => {
                    let map = |b: usize| {
                        if b <= old_start {
                            b
                        } else if b >= old_end {
                            shift(b)
                        } else {
                            new_end
                        }
                    };
                    map(start)..map(end)
                }
            };
        }
    }

    pub fn hunk_count(&self) -> usize {
        self.segments.iter().filter(|s| s.hunk.is_some()).count()
    }

    fn segment(&self, hunk: usize) -> Option<&Segment> {
        self.segments.iter().find(|s| s.hunk == Some(hunk))
    }

    /// The change a position is in, or the last chunk's past the end. `None` for an unchanged chunk.
    pub fn hunk_at(&self, position: usize) -> Option<usize> {
        let segment = self.segments.iter().find(|s| s.range.contains(&position)).or(self.segments.last());
        segment.and_then(|s| s.hunk)
    }

    /// Where a change's text is.
    pub fn hunk_range(&self, hunk: usize) -> Option<Range<usize>> {
        self.segment(hunk).map(|s| s.range.clone())
    }

    /// A change's text in a version, `merge::VERSION_*`, for taking that version.
    pub fn version(&self, hunk: usize, version: usize) -> Option<&str> {
        self.segment(hunk).and_then(|s| s.versions.get(version)).map(String::as_str)
    }

    /// Whether a change is a conflict still unresolved: with git's conflict markers in it.
    pub fn unresolved(&self, hunk: usize) -> bool {
        self.segment(hunk).is_some_and(|s| has_conflict_markers(&self.text[s.range.clone()]))
    }

    /// How many changes are conflicts still unresolved.
    pub fn conflict_count(&self) -> usize {
        self.segments.iter().filter(|s| s.hunk.is_some() && has_conflict_markers(&self.text[s.range.clone()])).count()
    }

    /// Whether any of the text has git's conflict markers in it.
    pub fn has_conflict_markers(&self) -> bool {
        has_conflict_markers(&self.text)
    }

    /// The text as the file was: in its encoding, with its line breaks `\r\n` if they were.
    pub fn encode(&self) -> Result<Vec<u8>, String> {
        let mut text = String::from_utf16_lossy(&self.text);
        if self.crlf {
            // Lines added in the editor end with `\n`.
            let mut with_crlf = String::with_capacity(text.len());
            let mut previous = '\0';
            for c in text.chars() {
                if c == '\n' && previous != '\r' {
                    with_crlf.push('\r');
                }
                with_crlf.push(c);
                previous = c;
            }
            text = with_crlf;
        }
        if !self.latin1 {
            return Ok(text.into_bytes());
        }
        text.chars()
            .map(|c| {
                u8::try_from(c).map_err(|_| {
                    format!("The merged result has characters the file's encoding, Latin-1, can't hold, such as “{c}”.")
                })
            })
            .collect()
    }

    /// Write the text to a file, in place.
    pub fn save(&self, path: &Path) -> Result<(), String> {
        let bytes = self.encode()?;
        fs::write(path, bytes).map_err(|e| format!("{}: {e}", path.display()))
    }
}

/// Whether a line of the text starts with git's conflict marker.
fn has_conflict_markers(text: &[u16]) -> bool {
    let marker: Vec<u16> = CONFLICT_MARKER.encode_utf16().collect();
    let line_start = |i: usize| i == 0 || text[i - 1] == u16::from(b'\n');
    text.windows(marker.len()).enumerate().any(|(i, window)| window == marker.as_slice() && line_start(i))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diff::Options;
    use crate::merge::{VERSION_A, VERSION_B};
    use crate::text::Text;

    fn utf16(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }

    fn string(units: &[u16]) -> String {
        String::from_utf16_lossy(units)
    }

    fn result(base: &[u8], a: &[u8], b: &[u8]) -> MergeResult {
        let text = |bytes: &[u8]| Text::from_bytes(bytes.to_vec());
        let options = Options { tab_width: 4, ..Options::default() };
        MergeResult::new(&Merge::new(text(base), text(a), text(b), options))
    }

    /// Line two changed differently on each side, line five only in B.
    fn conflicted() -> MergeResult {
        result(b"one\ntwo\nthree\nfour\nfive\n", b"one\nTWO\nthree\nfour\nfive\n", b"one\n2\nthree\nfour\n5\n")
    }

    #[test]
    fn starts_as_the_merge_does() {
        let r = conflicted();
        assert_eq!(string(r.text()), "one\n<<<<<<< A\nTWO\n=======\n2\n>>>>>>> B\nthree\nfour\n5\n");
        assert_eq!(r.hunk_count(), 2);
        assert_eq!(r.hunk_range(0), Some(4..38));
        assert_eq!(r.hunk_at(4), Some(0));
        assert_eq!(r.hunk_at(0), None);
        assert_eq!(r.hunk_at(1000), Some(1));
        assert_eq!(r.version(0, VERSION_B), Some("2\n"));
        assert!(r.unresolved(0) && !r.unresolved(1));
        assert_eq!(r.conflict_count(), 1);
        assert!(r.has_conflict_markers());
    }

    #[test]
    fn taking_a_side_resolves_the_conflict() {
        let mut r = conflicted();
        let range = r.hunk_range(0).unwrap();
        let a = utf16(r.version(0, VERSION_A).unwrap());
        r.replace(range.start, range.len(), &a);
        assert_eq!(string(r.text()), "one\nTWO\nthree\nfour\n5\n");
        assert_eq!(r.hunk_range(0), Some(4..8));
        assert_eq!(r.hunk_range(1), Some(19..21));
        assert_eq!(r.conflict_count(), 0);
        assert!(!r.has_conflict_markers());
    }

    #[test]
    fn chunks_move_with_edits() {
        let mut r = conflicted();
        // Typing before a change moves it down.
        r.replace(0, 0, &utf16("zero\n"));
        assert_eq!(r.hunk_range(0), Some(9..43));
        // Deleting across the end of a change and into the text after it ends it where the deletion did.
        r.replace(35, 10, &[]);
        assert_eq!(r.hunk_range(0), Some(9..35));
        // Typing within a change grows it.
        r.replace(10, 0, &utf16("é"));
        assert_eq!(r.hunk_range(0), Some(9..36));
    }

    #[test]
    fn typing_into_an_emptied_change_goes_into_it() {
        let mut r = conflicted();
        let range = r.hunk_range(1).unwrap();
        r.replace(range.start, range.len(), &[]);
        assert_eq!(r.hunk_range(1), Some(range.start..range.start));
        r.replace(range.start, 0, &utf16("five\n"));
        assert_eq!(r.hunk_range(1), Some(range.start..range.start + 5));
    }

    #[test]
    fn conflict_markers_only_count_at_the_start_of_a_line() {
        assert!(has_conflict_markers(&utf16("<<<<<<< A\n")));
        assert!(has_conflict_markers(&utf16("x\n<<<<<<< A\n")));
        assert!(!has_conflict_markers(&utf16("x <<<<<<< A\n")));
    }

    #[test]
    fn saves_with_the_files_line_breaks() {
        let mut r = result(b"x\r\ny\r\n", b"a\r\ny\r\n", b"x\r\ny\r\n");
        r.replace(r.text().len(), 0, &utf16("typed\n"));
        assert_eq!(r.encode().unwrap(), b"a\r\ny\r\ntyped\r\n");
    }

    #[test]
    fn saves_in_latin1_when_side_a_was() {
        let mut r = result(b"caf\xe9\n", b"caf\xe9!\n", b"caf\xe9\n");
        assert_eq!(r.encode().unwrap(), b"caf\xe9!\n");
        r.replace(0, 0, &utf16("€"));
        assert!(r.encode().unwrap_err().contains("€"));
        let utf8 = result("café\n".as_bytes(), "café!\n".as_bytes(), "café\n".as_bytes());
        assert_eq!(utf8.encode().unwrap(), "café!\n".as_bytes());
    }
}
