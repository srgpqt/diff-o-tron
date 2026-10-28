//! Three-way merges: two changed versions of a file, A and B, merged against their common base.

use std::ops::Range;
use std::path::Path;

use crate::diff::{LineKind, Options, Pairing, Side, line_hunks};
use crate::text::Text;

/// The sides of a merge, in the order they're shown.
pub const BASE: usize = 0;
pub const A: usize = 1;
pub const B: usize = 2;

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChunkKind {
    Unchanged = 0,
    ChangedInA = 1,
    ChangedInB = 2,
    /// Changed the same way in A and B.
    ChangedInBoth = 3,
    /// Changed differently in A and B.
    Conflict = 4,
}

/// A run of lines unchanged in both A and B, or changed in either or both.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Chunk {
    pub kind: ChunkKind,
    /// Its lines on each side.
    pub lines: [Range<u32>; 3],
    pub rows: Range<u32>,
}

/// The versions of a chunk's text, for the merged result.
pub const VERSION_BASE: usize = 0;
pub const VERSION_A: usize = 1;
pub const VERSION_B: usize = 2;
/// What the merged result starts with: the change from whichever side made one, or for a
/// conflict, both sides between git's conflict markers.
pub const VERSION_MERGED: usize = 3;

#[derive(Debug, Default)]
pub struct Merge {
    pub sides: [Side; 3],
    /// Rows of the side-by-side view: a line from any of the sides.
    pub rows: Vec<[Option<u32>; 3]>,
    pub chunks: Vec<Chunk>,
    /// Each chunk's text in each version.
    pub texts: Vec<[String; 4]>,
    pub error: Option<String>,
}

/// One side's change in the line diff from the base.
struct Change {
    side: usize,
    base: Range<u32>,
    lines: Range<u32>,
}

impl Merge {
    pub fn load(base: &Path, a: &Path, b: &Path, options: Options) -> Merge {
        let load = |path: &Path| Text::load(path).map_err(|e| format!("{}: {e}", path.display()));
        match (load(base), load(a), load(b)) {
            (Ok(base), Ok(a), Ok(b)) => Merge::new(base, a, b, options),
            (Err(e), _, _) | (_, Err(e), _) | (_, _, Err(e)) => Merge { error: Some(e), ..Merge::default() },
        }
    }

    pub fn new(base: Text, a: Text, b: Text, options: Options) -> Merge {
        if base.binary || a.binary || b.binary {
            return Merge { error: Some("Binary files can't be merged.".into()), ..Merge::default() };
        }
        let eol = if base.content.contains("\r\n") { "\r\n" } else { "\n" };
        let mut changes: Vec<Change> = Vec::new();
        for (side, other) in [(A, &a), (B, &b)] {
            for (before, after) in line_hunks(&base, other, options.ignore_whitespace) {
                changes.push(Change { side, base: before, lines: after });
            }
        }
        changes.sort_by_key(|c| (c.base.start, c.base.end));

        let mut merge = Merge {
            sides: [
                Side::new(base, options.tab_width),
                Side::new(a, options.tab_width),
                Side::new(b, options.tab_width),
            ],
            ..Merge::default()
        };

        // Changes that overlap or touch in the base are merged together.
        let mut groups: Vec<(Range<u32>, Vec<Change>)> = Vec::new();
        for change in changes {
            match groups.last_mut() {
                Some((range, group)) if change.base.start <= range.end => {
                    range.end = range.end.max(change.base.end);
                    group.push(change);
                }
                _ => groups.push((change.base.clone(), vec![change])),
            }
        }

        // How much further down A's and B's lines are than the base's, so far.
        let mut offsets = [0i64; 3];
        let mut next = 0;
        for (range, group) in &groups {
            merge.push_unchanged(next..range.start, offsets);
            let mut lines = [range.clone(), range.clone(), range.clone()];
            let mut changed = [false; 3];
            for side in [A, B] {
                let delta: i64 =
                    group.iter().filter(|c| c.side == side).map(|c| c.lines.len() as i64 - c.base.len() as i64).sum();
                changed[side] = group.iter().any(|c| c.side == side);
                let start = (range.start as i64 + offsets[side]) as u32;
                let end = (range.end as i64 + offsets[side] + delta) as u32;
                lines[side] = start..end;
                offsets[side] += delta;
            }
            let kind = match (changed[A], changed[B]) {
                (true, false) => ChunkKind::ChangedInA,
                (false, true) => ChunkKind::ChangedInB,
                _ if merge.text_of(A, &lines[A]) == merge.text_of(B, &lines[B]) => ChunkKind::ChangedInBoth,
                _ => ChunkKind::Conflict,
            };
            merge.push_change(kind, lines, eol);
            next = range.end;
        }
        let end = merge.sides[BASE].text.lines.len() as u32;
        merge.push_unchanged(next..end, offsets);
        merge
    }

    /// The text of a side's lines, with their terminators.
    fn text_of(&self, side: usize, lines: &Range<u32>) -> String {
        lines.clone().map(|i| self.sides[side].text.raw_line(i as usize)).collect()
    }

    fn push_unchanged(&mut self, base: Range<u32>, offsets: [i64; 3]) {
        if base.is_empty() {
            return;
        }
        let shift = |side: usize| (base.start as i64 + offsets[side]) as u32..(base.end as i64 + offsets[side]) as u32;
        let lines = [base.clone(), shift(A), shift(B)];
        let first_row = self.rows.len() as u32;
        for i in 0..base.len() as u32 {
            self.rows.push([Some(lines[BASE].start + i), Some(lines[A].start + i), Some(lines[B].start + i)]);
        }
        let text = self.text_of(BASE, &lines[BASE]);
        self.texts.push([text.clone(), self.text_of(A, &lines[A]), self.text_of(B, &lines[B]), text]);
        self.chunks.push(Chunk { kind: ChunkKind::Unchanged, lines, rows: first_row..self.rows.len() as u32 });
    }

    fn push_change(&mut self, kind: ChunkKind, lines: [Range<u32>; 3], eol: &str) {
        let first_row = self.rows.len() as u32;
        let [base, a, b] = lines.clone();
        // A side that didn't change has the base's lines; align it with the base.
        let same_as_base = |line: Option<u32>, side: &Range<u32>| line.map(|l| side.start + (l - base.start));
        match kind {
            ChunkKind::ChangedInA | ChunkKind::ChangedInB => {
                let (changed, unchanged) = if kind == ChunkKind::ChangedInA { (A, B) } else { (B, A) };
                let pairing = self.pairing(BASE, &base, changed, &lines[changed]);
                let [base_side, a_side, b_side] = &mut self.sides;
                let changed_side = if changed == A { a_side } else { b_side };
                pairing.apply(base_side, changed_side);
                for (base_line, changed_line) in pairing.rows(true) {
                    let mut row = [None; 3];
                    row[BASE] = base_line;
                    row[changed] = changed_line;
                    row[unchanged] = same_as_base(base_line, &lines[unchanged]);
                    self.rows.push(row);
                }
            }
            ChunkKind::ChangedInBoth => {
                let pairing = self.pairing(BASE, &base, A, &a);
                let b_pairing = self.pairing(BASE, &base, B, &b);
                let [base_side, a_side, b_side] = &mut self.sides;
                pairing.apply(base_side, a_side);
                b_pairing.apply_to(b_side, false, LineKind::Added);
                // B's lines are A's.
                for (base_line, a_line) in pairing.rows(true) {
                    self.rows.push([base_line, a_line, a_line.map(|l| b.start + (l - a.start))]);
                }
            }
            ChunkKind::Conflict => {
                let a_pairing = self.pairing(BASE, &base, A, &a);
                let b_pairing = self.pairing(BASE, &base, B, &b);
                let [base_side, a_side, b_side] = &mut self.sides;
                // The base's lines are changed if paired with either side's.
                a_pairing.apply_to(base_side, true, LineKind::Removed);
                b_pairing.apply_pairs_to(base_side, true);
                a_pairing.apply_to(a_side, false, LineKind::Added);
                b_pairing.apply_to(b_side, false, LineKind::Added);
                // Every line of a conflict is one, keeping its changed parts.
                for (side, range) in self.sides.iter_mut().zip(&lines) {
                    for i in range.clone() {
                        side.kinds[i as usize] = LineKind::Conflict;
                    }
                }
                let height = base.len().max(a.len()).max(b.len()) as u32;
                let line = |range: &Range<u32>, i: u32| (i < range.len() as u32).then_some(range.start + i);
                for i in 0..height {
                    self.rows.push([line(&base, i), line(&a, i), line(&b, i)]);
                }
            }
            ChunkKind::Unchanged => unreachable!(),
        }

        let (base_text, a_text, b_text) = (self.text_of(BASE, &base), self.text_of(A, &a), self.text_of(B, &b));
        let merged = match kind {
            ChunkKind::ChangedInA | ChunkKind::ChangedInBoth => a_text.clone(),
            ChunkKind::ChangedInB => b_text.clone(),
            _ => conflict_text(&a_text, &b_text, eol),
        };
        self.texts.push([base_text, a_text, b_text, merged]);
        self.chunks.push(Chunk { kind, lines, rows: first_row..self.rows.len() as u32 });
    }

    fn pairing(&self, x: usize, x_lines: &Range<u32>, y: usize, y_lines: &Range<u32>) -> Pairing {
        Pairing::infer(&self.sides[x], x_lines.clone(), &self.sides[y], y_lines.clone())
    }

    /// The merged result, as it starts.
    pub fn merged_text(&self) -> String {
        self.texts.iter().map(|t| t[VERSION_MERGED].as_str()).collect()
    }
}

/// Both sides' text between git's conflict markers.
fn conflict_text(a: &str, b: &str, eol: &str) -> String {
    let mut text = format!("<<<<<<< A{eol}");
    for side in [a, b] {
        text.push_str(side);
        // The last line of a file may have no line break.
        if !side.is_empty() && !side.ends_with('\n') {
            text.push_str(eol);
        }
        if side == a {
            text.push_str(&format!("======={eol}"));
        }
    }
    text.push_str(&format!(">>>>>>> B{eol}"));
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    fn merge(base: &str, a: &str, b: &str) -> Merge {
        let text = |s: &str| Text::from_bytes(s.into());
        Merge::new(text(base), text(a), text(b), Options { tab_width: 4, ..Options::default() })
    }

    fn kinds(m: &Merge) -> Vec<ChunkKind> {
        m.chunks.iter().map(|c| c.kind).collect()
    }

    #[test]
    fn takes_changes_from_either_side() {
        let m = merge("1\n2\n3\n4\n5\n", "1\ntwo\n3\n4\n5\n", "1\n2\n3\n4\nfive\n");
        assert_eq!(
            kinds(&m),
            [ChunkKind::Unchanged, ChunkKind::ChangedInA, ChunkKind::Unchanged, ChunkKind::ChangedInB]
        );
        assert_eq!(m.merged_text(), "1\ntwo\n3\n4\nfive\n");
        assert_eq!(m.chunks[3].lines, [4..5, 4..5, 4..5]);
    }

    #[test]
    fn same_change_on_both_sides() {
        let m = merge("1\n2\n3\n", "1\ntwo\n3\n", "1\ntwo\n3\n");
        assert_eq!(kinds(&m), [ChunkKind::Unchanged, ChunkKind::ChangedInBoth, ChunkKind::Unchanged]);
        assert_eq!(m.merged_text(), "1\ntwo\n3\n");
    }

    #[test]
    fn conflicting_changes() {
        let m = merge("1\n2\n3\n", "1\ntwo\n3\n", "1\nTWO\nzwei\n3\n");
        assert_eq!(kinds(&m), [ChunkKind::Unchanged, ChunkKind::Conflict, ChunkKind::Unchanged]);
        assert_eq!(m.chunks[1].lines, [1..2, 1..2, 1..3]);
        assert_eq!(m.merged_text(), "1\n<<<<<<< A\ntwo\n=======\nTWO\nzwei\n>>>>>>> B\n3\n");
        assert_eq!(m.texts[1][VERSION_B], "TWO\nzwei\n");
        assert_eq!(m.sides[B].kinds, [LineKind::Equal, LineKind::Conflict, LineKind::Conflict, LineKind::Equal]);
        // The tallest side sets the conflict's rows.
        assert_eq!(m.rows[1..3], [[Some(1), Some(1), Some(1)], [None, None, Some(2)]]);
    }

    #[test]
    fn touching_changes_conflict() {
        let m = merge("1\n2\n3\n4\n", "1\nB\n3\n4\n", "1\n2\nC\n4\n");
        assert_eq!(kinds(&m), [ChunkKind::Unchanged, ChunkKind::Conflict, ChunkKind::Unchanged]);
        assert_eq!(m.chunks[1].lines, [1..3, 1..3, 1..3]);
    }

    #[test]
    fn lines_shift_after_insertions() {
        let m = merge("1\n2\n3\n", "0\n1\n2\n3\n", "1\n2\nthree\n");
        assert_eq!(kinds(&m), [ChunkKind::ChangedInA, ChunkKind::Unchanged, ChunkKind::ChangedInB]);
        assert_eq!(m.chunks[0].lines, [0..0, 0..1, 0..0]);
        assert_eq!(m.chunks[1].lines, [0..2, 1..3, 0..2]);
        assert_eq!(m.chunks[2].lines, [2..3, 3..4, 2..3]);
        assert_eq!(m.merged_text(), "0\n1\n2\nthree\n");
    }

    #[test]
    fn conflict_markers_follow_line_endings() {
        let m = merge("x\r\n", "a\r\n", "b");
        assert_eq!(m.merged_text(), "<<<<<<< A\r\na\r\n=======\r\nb\r\n>>>>>>> B\r\n");
    }

    #[test]
    fn unchanged_sides_align_with_the_base() {
        let m = merge("1\nlet x = 1;\n3\n", "1\nlet x = 2;\n3\n", "1\nlet x = 1;\n3\n");
        assert_eq!(m.chunks[1].kind, ChunkKind::ChangedInA);
        assert_eq!(m.rows[1], [Some(1), Some(1), Some(1)]);
        assert_eq!(m.sides[BASE].kinds[1], LineKind::Changed);
        assert_eq!(m.sides[A].kinds[1], LineKind::Changed);
        assert_eq!(m.sides[B].kinds[1], LineKind::Equal);
    }

    #[test]
    fn binary_files_are_an_error() {
        assert!(merge("a\0", "b", "c").error.is_some());
    }
}
