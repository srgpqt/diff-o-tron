use std::ops::Range;
use std::path::Path;
use std::sync::LazyLock;

use imara_diff::{Algorithm, Diff, InternedInput, Interner};
use regex::Regex;

use crate::edits;
use crate::text::{self, Text};

// delta's defaults for its within-line edit inference (`--word-diff-regex`, `--max-line-distance`).
static TOKENIZATION_REGEX: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\w+").unwrap());
const MAX_LINE_DISTANCE: f64 = 0.6;
const MAX_LINE_DISTANCE_FOR_NAIVELY_PAIRED_LINES: f64 = 0.0;

/// delta's inference compares every line of a hunk against every other, and each comparison is
/// quadratic in the line's length, so very large hunks and very long lines are left out.
const MAX_INFERENCE_PAIRS: usize = 40_000;
const MAX_INFERENCE_LINE_LEN: usize = 1024;

#[derive(Clone, Copy, Debug, Default)]
pub struct Options {
    pub ignore_whitespace: bool,
    pub tab_width: u32,
}

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LineKind {
    Equal = 0,
    /// Paired with a similar line on the other side; its differences are in `spans`.
    Changed = 1,
    /// Only on side A.
    Removed = 2,
    /// Only on side B.
    Added = 3,
}

/// A run of a line that differs from its paired line.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Span {
    /// Byte offsets into the line.
    pub start: u32,
    pub end: u32,
    /// The same offsets in UTF-16 code units.
    pub start16: u32,
    pub end16: u32,
}

/// One row of the side-by-side view: a line from either or both sides.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Row {
    pub a: Option<u32>,
    pub b: Option<u32>,
}

/// A change: consecutive rows of changed lines that are either all paired with similar lines on
/// the other side, or all unpaired.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Hunk {
    pub rows: Range<u32>,
    pub a: Range<u32>,
    pub b: Range<u32>,
    /// The hunk's rows in `FileDiff::unified`.
    pub unified: Range<u32>,
}

#[derive(Debug, Default)]
pub struct Side {
    pub text: Text,
    pub kinds: Vec<LineKind>,
    pub columns: Vec<u32>,
    /// Each line's range in `spans`.
    pub line_spans: Vec<Range<u32>>,
    pub spans: Vec<Span>,
}

impl Side {
    fn new(text: Text, tab_width: u32) -> Side {
        let n = text.lines.len();
        let columns = (0..n).map(|i| text::columns(text.line(i), tab_width)).collect();
        Side { text, kinds: vec![LineKind::Equal; n], columns, line_spans: vec![0..0; n], spans: Vec::new() }
    }

    pub fn line_spans(&self, line: usize) -> &[Span] {
        let r = &self.line_spans[line];
        &self.spans[r.start as usize..r.end as usize]
    }

    fn set_spans(&mut self, line: usize, emph: &[Range<usize>]) {
        let text = self.text.line(line);
        let start = self.spans.len() as u32;
        for r in emph {
            self.spans.push(Span {
                start: r.start as u32,
                end: r.end as u32,
                start16: utf16_len(&text[..r.start]),
                end16: utf16_len(&text[..r.end]),
            });
        }
        self.line_spans[line] = start..self.spans.len() as u32;
    }
}

#[derive(Debug, Default)]
pub struct FileDiff {
    pub a: Side,
    pub b: Side,
    pub rows: Vec<Row>,
    pub hunks: Vec<Hunk>,
    /// Rows of the unified view: unchanged lines with both sides, and changed lines with one.
    pub unified: Vec<Row>,
    /// Both sides have exactly the same contents.
    pub identical: bool,
    pub error: Option<String>,
}

impl FileDiff {
    /// Compare two files. A missing side compares as empty.
    pub fn load(a: Option<&Path>, b: Option<&Path>, options: Options) -> FileDiff {
        let load = |path: Option<&Path>| match path {
            Some(path) => Text::load(path).map_err(|e| format!("{}: {e}", path.display())),
            None => Ok(Text::default()),
        };
        match (load(a), load(b)) {
            (Ok(a), Ok(b)) => FileDiff::new(a, b, options),
            (Err(e), _) | (_, Err(e)) => FileDiff { error: Some(e), ..FileDiff::default() },
        }
    }

    pub fn new(a: Text, b: Text, options: Options) -> FileDiff {
        let identical = a.same_contents(&b);
        let binary = a.binary || b.binary;
        let mut diff = FileDiff {
            a: Side::new(a, options.tab_width),
            b: Side::new(b, options.tab_width),
            identical,
            ..FileDiff::default()
        };
        if !binary {
            diff.compute(options);
        }
        diff
    }

    pub fn binary(&self) -> bool {
        self.a.text.binary || self.b.text.binary
    }

    fn compute(&mut self, options: Options) {
        let line_diff = if options.ignore_whitespace {
            let mut input = InternedInput {
                before: Vec::new(),
                after: Vec::new(),
                interner: Interner::new(self.a.text.lines.len() + self.b.text.lines.len()),
            };
            input.update_before(self.a.text.raw_lines().map(strip_whitespace));
            input.update_after(self.b.text.raw_lines().map(strip_whitespace));
            let mut diff = Diff::compute(Algorithm::Histogram, &input);
            diff.postprocess_no_heuristic(&input);
            diff
        } else {
            let mut input = InternedInput::default();
            input.update_before(self.a.text.raw_lines());
            input.update_after(self.b.text.raw_lines());
            let mut diff = Diff::compute(Algorithm::Histogram, &input);
            diff.postprocess_lines(&input);
            diff
        };

        let (mut a, mut b) = (0, 0);
        for hunk in line_diff.hunks() {
            self.push_equal(a..hunk.before.start, b..hunk.after.start);
            self.push_hunk(hunk.before.clone(), hunk.after.clone());
            (a, b) = (hunk.before.end, hunk.after.end);
        }
        let (a_len, b_len) = (self.a.text.lines.len() as u32, self.b.text.lines.len() as u32);
        self.push_equal(a..a_len, b..b_len);
        self.push_unified();
    }

    /// Lay out the unified view. Within a hunk, each run of rows that pair changed lines shows
    /// the run's A lines and then its B lines, and so does each run of unpaired lines.
    fn push_unified(&mut self) {
        let mut unified = Vec::with_capacity(self.rows.len());
        let mut ranges = Vec::with_capacity(self.hunks.len());
        let mut next = 0;
        for hunk in &self.hunks {
            let (start, end) = (hunk.rows.start as usize, hunk.rows.end as usize);
            unified.extend_from_slice(&self.rows[next..start]);
            let first = unified.len() as u32;
            for run in self.rows[start..end].chunk_by(|x, y| self.paired(x) == self.paired(y)) {
                unified.extend(run.iter().filter_map(|r| r.a).map(|a| Row { a: Some(a), b: None }));
                unified.extend(run.iter().filter_map(|r| r.b).map(|b| Row { a: None, b: Some(b) }));
            }
            ranges.push(first..unified.len() as u32);
            next = end;
        }
        unified.extend_from_slice(&self.rows[next..]);
        for (hunk, range) in self.hunks.iter_mut().zip(ranges) {
            hunk.unified = range;
        }
        self.unified = unified;
    }

    fn push_equal(&mut self, a: Range<u32>, b: Range<u32>) {
        debug_assert_eq!(a.len(), b.len());
        self.rows.extend(a.zip(b).map(|(a, b)| Row { a: Some(a), b: Some(b) }));
    }

    fn push_hunk(&mut self, a: Range<u32>, b: Range<u32>) {
        let first_row = self.rows.len() as u32;
        for i in a.clone() {
            self.a.kinds[i as usize] = LineKind::Removed;
        }
        for i in b.clone() {
            self.b.kinds[i as usize] = LineKind::Added;
        }

        let alignment = if a.len() * b.len() <= MAX_INFERENCE_PAIRS {
            self.infer_edits(a.clone(), b.clone())
        } else {
            a.clone().map(|i| (Some(i), None)).chain(b.clone().map(|i| (None, Some(i)))).collect()
        };

        // delta gives unpaired lines rows of their own; share rows between runs of them instead.
        let (mut minus, mut plus) = (Vec::new(), Vec::new());
        for (m, p) in alignment {
            match (m, p) {
                (Some(_), Some(_)) => {
                    self.push_unpaired(&mut minus, &mut plus);
                    self.rows.push(Row { a: m, b: p });
                }
                (Some(m), None) => minus.push(m),
                (None, Some(p)) => plus.push(p),
                (None, None) => {}
            }
        }
        self.push_unpaired(&mut minus, &mut plus);

        // A hunk of the line diff for each run of paired rows and each run of unpaired rows.
        let (mut row, mut a_next, mut b_next) = (first_row, a.start, b.start);
        let mut hunks = Vec::new();
        for run in self.rows[first_row as usize..].chunk_by(|x, y| self.paired(x) == self.paired(y)) {
            let a_count = run.iter().filter(|r| r.a.is_some()).count() as u32;
            let b_count = run.iter().filter(|r| r.b.is_some()).count() as u32;
            let len = run.len() as u32;
            hunks.push(Hunk {
                rows: row..row + len,
                a: a_next..a_next + a_count,
                b: b_next..b_next + b_count,
                unified: 0..0,
            });
            (row, a_next, b_next) = (row + len, a_next + a_count, b_next + b_count);
        }
        debug_assert_eq!((a_next, b_next), (a.end, b.end));
        self.hunks.extend(hunks);
    }

    /// Whether a row pairs changed lines.
    fn paired(&self, row: &Row) -> bool {
        row.a.is_some_and(|a| self.a.kinds[a as usize] == LineKind::Changed)
    }

    fn push_unpaired(&mut self, minus: &mut Vec<u32>, plus: &mut Vec<u32>) {
        for i in 0..minus.len().max(plus.len()) {
            self.rows.push(Row { a: minus.get(i).copied(), b: plus.get(i).copied() });
        }
        minus.clear();
        plus.clear();
    }

    /// Pair up similar lines with delta and record their differences.
    /// Returns delta's alignment, in absolute line numbers.
    fn infer_edits(&mut self, a: Range<u32>, b: Range<u32>) -> Vec<(Option<u32>, Option<u32>)> {
        #[derive(Clone, Copy, Debug, PartialEq)]
        enum Op {
            MinusNoop,
            PlusNoop,
            Deletion,
            Insertion,
        }

        let minus_lines: Vec<&str> =
            a.clone().map(|i| truncate(self.a.text.line(i as usize), MAX_INFERENCE_LINE_LEN)).collect();
        let plus_lines: Vec<&str> =
            b.clone().map(|i| truncate(self.b.text.line(i as usize), MAX_INFERENCE_LINE_LEN)).collect();
        let (minus_len, plus_len) = (minus_lines.len(), plus_lines.len());
        let (annotated_minus, annotated_plus, alignment) = edits::infer_edits(
            minus_lines,
            plus_lines,
            vec![Op::MinusNoop; minus_len],
            Op::Deletion,
            vec![Op::PlusNoop; plus_len],
            Op::Insertion,
            &TOKENIZATION_REGEX,
            MAX_LINE_DISTANCE,
            MAX_LINE_DISTANCE_FOR_NAIVELY_PAIRED_LINES,
        );

        // delta emits annotated lines in the order of the alignment.
        let (mut minus_iter, mut plus_iter) = (annotated_minus.iter(), annotated_plus.iter());
        let mut result = Vec::with_capacity(alignment.len());
        let mut paired = Vec::new();
        for &(m, p) in &alignment {
            let m = m.map(|m| a.start + m as u32);
            let p = p.map(|p| b.start + p as u32);
            let annotated_m = m.and_then(|_| minus_iter.next());
            let annotated_p = p.and_then(|_| plus_iter.next());
            if let (Some(m), Some(p), Some(annotated_m), Some(annotated_p)) = (m, p, annotated_m, annotated_p) {
                let (m, p) = (m as usize, p as usize);
                let emph_m = emphasized(self.a.text.line(m), annotated_m, Op::Deletion);
                let emph_p = emphasized(self.b.text.line(p), annotated_p, Op::Insertion);
                paired.push((m, emph_m, p, emph_p));
            }
            result.push((m, p));
        }
        for (m, emph_m, p, emph_p) in paired {
            self.a.kinds[m] = LineKind::Changed;
            self.b.kinds[p] = LineKind::Changed;
            self.a.set_spans(m, &emph_m);
            self.b.set_spans(p, &emph_p);
        }
        result
    }
}

/// The byte ranges of `line` that delta annotated with `op`, merging adjacent ones.
fn emphasized<Op: PartialEq>(line: &str, annotated: &[(Op, &str)], op: Op) -> Vec<Range<usize>> {
    let mut ranges: Vec<Range<usize>> = Vec::new();
    for (piece_op, piece) in annotated {
        if *piece_op != op || piece.is_empty() {
            continue;
        }
        // delta's pieces are slices of the line it was given.
        let start = piece.as_ptr() as usize - line.as_ptr() as usize;
        let end = start + piece.len();
        match ranges.last_mut() {
            Some(last) if last.end == start => last.end = end,
            _ => ranges.push(start..end),
        }
    }
    ranges
}

fn truncate(s: &str, max_len: usize) -> &str {
    if s.len() <= max_len {
        return s;
    }
    let mut end = max_len;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

fn strip_whitespace(line: &str) -> String {
    line.chars().filter(|c| !c.is_whitespace()).collect()
}

fn utf16_len(s: &str) -> u32 {
    s.chars().map(|c| c.len_utf16() as u32).sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn diff(a: &str, b: &str) -> FileDiff {
        let options = Options { tab_width: 4, ..Options::default() };
        FileDiff::new(Text::from_bytes(a.into()), Text::from_bytes(b.into()), options)
    }

    fn rows(d: &FileDiff) -> Vec<(Option<u32>, Option<u32>)> {
        d.rows.iter().map(|r| (r.a, r.b)).collect()
    }

    #[test]
    fn identical_files() {
        let d = diff("a\nb\n", "a\nb\n");
        assert!(d.identical);
        assert!(d.hunks.is_empty());
        assert_eq!(rows(&d), [(Some(0), Some(0)), (Some(1), Some(1))]);
    }

    #[test]
    fn insertion_and_removal() {
        let d = diff("a\nb\nc\n", "a\nc\nd\n");
        assert_eq!(rows(&d), [(Some(0), Some(0)), (Some(1), None), (Some(2), Some(1)), (None, Some(2))]);
        assert_eq!(d.a.kinds, [LineKind::Equal, LineKind::Removed, LineKind::Equal]);
        assert_eq!(d.b.kinds, [LineKind::Equal, LineKind::Equal, LineKind::Added]);
        assert_eq!(
            d.hunks,
            [
                Hunk { rows: 1..2, a: 1..2, b: 1..1, unified: 1..2 },
                Hunk { rows: 3..4, a: 3..3, b: 2..3, unified: 3..4 }
            ]
        );
    }

    #[test]
    fn changed_line_has_emphasized_words() {
        let d = diff("let x = foo(1);\n", "let x = bar(1);\n");
        assert_eq!(d.a.kinds, [LineKind::Changed]);
        assert_eq!(d.b.kinds, [LineKind::Changed]);
        assert_eq!(d.a.line_spans(0), [Span { start: 8, end: 11, start16: 8, end16: 11 }]);
        assert_eq!(d.b.line_spans(0), [Span { start: 8, end: 11, start16: 8, end16: 11 }]);
    }

    #[test]
    fn span_offsets_in_utf16() {
        let d = diff("é 日本 old\n", "é 日本 new\n");
        let span = d.b.line_spans(0)[0];
        assert_eq!(&d.b.text.line(0)[span.start as usize..span.end as usize], "new");
        assert_eq!((span.start16, span.end16), (5, 8));
    }

    #[test]
    fn unpaired_lines_share_rows() {
        let d = diff("x\naaaa\n", "x\nzzzz\nyyyy\n");
        assert_eq!(rows(&d), [(Some(0), Some(0)), (Some(1), Some(1)), (None, Some(2))]);
        assert_eq!(d.a.kinds[1], LineKind::Removed);
        assert_eq!(d.b.kinds[1], LineKind::Added);
    }

    fn unified(d: &FileDiff) -> Vec<(Option<u32>, Option<u32>)> {
        d.unified.iter().map(|r| (r.a, r.b)).collect()
    }

    #[test]
    fn unified_shows_runs_of_a_lines_then_b_lines() {
        let d =
            diff("same\nlet a = 1;\nlet b = 2;\ngone gone gone\nend\n", "same\nlet a = 10;\nlet b = 20;\nadded\nend\n");
        // Two changed lines paired, then a removed line and an added one sharing a row.
        assert_eq!(
            rows(&d),
            [(Some(0), Some(0)), (Some(1), Some(1)), (Some(2), Some(2)), (Some(3), Some(3)), (Some(4), Some(4))]
        );
        assert_eq!(d.a.kinds[3], LineKind::Removed);
        assert_eq!(
            unified(&d),
            [
                (Some(0), Some(0)),
                (Some(1), None),
                (Some(2), None),
                (None, Some(1)),
                (None, Some(2)),
                (Some(3), None),
                (None, Some(3)),
                (Some(4), Some(4)),
            ]
        );
        assert_eq!(d.hunks.iter().map(|h| h.unified.clone()).collect::<Vec<_>>(), [1..5, 5..7]);
    }

    #[test]
    fn hunks_split_into_paired_and_unpaired_runs() {
        // One hunk of the line diff: a changed line, a removed one, then another changed line.
        let d = diff("x\nlet a = 1;\nremoved line here\nlet b = 2;\ny\n", "x\nlet a = 10;\nlet b = 20;\ny\n");
        assert_eq!(
            rows(&d),
            [(Some(0), Some(0)), (Some(1), Some(1)), (Some(2), None), (Some(3), Some(2)), (Some(4), Some(3))]
        );
        assert_eq!(
            d.hunks,
            [
                Hunk { rows: 1..2, a: 1..2, b: 1..2, unified: 1..3 },
                Hunk { rows: 2..3, a: 2..3, b: 2..2, unified: 3..4 },
                Hunk { rows: 3..4, a: 3..4, b: 2..3, unified: 4..6 },
            ]
        );
    }

    #[test]
    fn unified_of_identical_files() {
        let d = diff("a\nb\n", "a\nb\n");
        assert_eq!(unified(&d), rows(&d));
    }

    #[test]
    fn ignore_whitespace() {
        let options = Options { ignore_whitespace: true, tab_width: 4 };
        let d = FileDiff::new(Text::from_bytes("a b\n".into()), Text::from_bytes("  a  b\n".into()), options);
        assert!(!d.identical);
        assert!(d.hunks.is_empty());
    }

    #[test]
    fn binary_files_are_not_diffed() {
        let d = diff("a\0", "b\0");
        assert!(d.binary());
        assert!(!d.identical);
        assert!(d.rows.is_empty());
    }
}
