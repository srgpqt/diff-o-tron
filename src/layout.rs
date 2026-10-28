//! The layout of a diff's views, in points down the document: where each side's lines, the
//! side-by-side rows and the unified view's rows start, as tall as the front end measures each
//! line. A row is as tall as its tallest line. The layout also has Fluid mode's scrolling.

use std::ops::Range;

use crate::fluid::{self, Fluid};

/// One of the layout's tables of rows.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Table {
    /// A side's lines, for Fluid mode.
    Lines(usize),
    /// The side-by-side rows.
    Rows,
    /// The unified view's rows.
    Unified,
}

/// A hunk of the diff: its rows, its unified rows, and each side's lines.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Hunk {
    pub rows: Range<usize>,
    pub unified: Range<usize>,
    pub lines: Vec<Range<usize>>,
}

impl Hunk {
    fn range(&self, table: Table) -> Range<usize> {
        match table {
            Table::Lines(side) => self.lines.get(side).cloned().unwrap_or(0..0),
            Table::Rows => self.rows.clone(),
            Table::Unified => self.unified.clone(),
        }
    }
}

/// A place in a table kept at the same place on the screen while the layout changes: a fraction
/// of the way down a row, `screen_y` down from the top of the view.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Anchor {
    pub index: usize,
    pub fraction: f64,
    pub screen_y: f64,
}

/// Where each of a table's rows starts, after the padding at the top, then where the last ends.
#[derive(Debug)]
struct Tops(Vec<f64>);

impl Tops {
    fn new(padding: f64, heights: impl Iterator<Item = f64>) -> Tops {
        let mut tops = vec![padding];
        let mut y = padding;
        for height in heights {
            y += height;
            tops.push(y);
        }
        Tops(tops)
    }

    fn count(&self) -> usize {
        self.0.len() - 1
    }

    /// Where a row starts, or past the last, where the rows end.
    fn y(&self, index: usize) -> f64 {
        self.0[index.min(self.0.len() - 1)]
    }

    fn height(&self, index: usize) -> f64 {
        if index < self.count() { self.y(index + 1) - self.y(index) } else { 0.0 }
    }

    /// The row at y: -1 above the first, or the row count below the last.
    fn index_at(&self, y: f64) -> isize {
        if self.0.len() < 2 || y < self.0[0] {
            return -1;
        }
        self.0.partition_point(|&top| top <= y) as isize - 1
    }

    /// The rows that overlap top to bottom.
    fn range(&self, top: f64, bottom: f64) -> Range<usize> {
        let first = self.index_at(top).max(0) as usize;
        let last = self.index_at(bottom);
        let last = if last < 0 { 0 } else { (last as usize + 1).min(self.count()) };
        first..last
    }
}

#[derive(Debug)]
pub struct Layout {
    lines: Vec<Tops>,
    rows: Tops,
    unified: Tops,
    /// For the lines of a side the diff hasn't.
    none: Tops,
    hunks: Vec<Hunk>,
    padding: f64,
    pub fluid: Fluid,
}

impl Layout {
    /// Lay out lines `line_heights[side][line]` tall, after `padding`, which is also left after
    /// the last row. `rows` side-by-side rows show, on each side, the line `row_line(row, side)`;
    /// `unified` unified rows each show `unified_line(row)`, a side and line, or else are
    /// `line_height` tall, a line's height unwrapped.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        line_heights: &[&[f64]],
        rows: usize,
        row_line: impl Fn(usize, usize) -> Option<usize>,
        unified: usize,
        unified_line: impl Fn(usize) -> Option<(usize, usize)>,
        hunks: Vec<Hunk>,
        padding: f64,
        line_height: f64,
    ) -> Layout {
        let lines: Vec<Tops> = line_heights.iter().map(|heights| Tops::new(padding, heights.iter().copied())).collect();
        let line_height_of = |side: usize, line: usize| lines.get(side).map_or(0.0, |tops| tops.height(line));
        let rows = Tops::new(
            padding,
            (0..rows).map(|row| {
                (0..lines.len())
                    .filter_map(|side| row_line(row, side).map(|line| line_height_of(side, line)))
                    .fold(0.0, f64::max)
            }),
        );
        let unified = Tops::new(
            padding,
            (0..unified).map(|row| unified_line(row).map_or(line_height, |(side, line)| line_height_of(side, line))),
        );

        let fluid_hunks: Vec<fluid::Hunk> =
            hunks.iter().map(|h| fluid::Hunk { rows: h.rows.clone(), lines: h.lines.clone() }).collect();
        let line_tops: Vec<&[f64]> = lines.iter().map(|tops| tops.0.as_slice()).collect();
        let fluid = Fluid::new(&fluid_hunks, &rows.0, &line_tops, padding, line_height);
        Layout { lines, rows, unified, none: Tops::new(padding, std::iter::empty()), hunks, padding, fluid }
    }

    fn tops(&self, table: Table) -> &Tops {
        match table {
            Table::Lines(side) => self.lines.get(side).unwrap_or(&self.none),
            Table::Rows => &self.rows,
            Table::Unified => &self.unified,
        }
    }

    /// Where a row starts, or past the last, where the rows end.
    pub fn y(&self, table: Table, index: usize) -> f64 {
        self.tops(table).y(index)
    }

    /// The row at y: -1 above the first, or the row count below the last.
    pub fn index_at(&self, table: Table, y: f64) -> isize {
        self.tops(table).index_at(y)
    }

    /// The rows that overlap top to bottom.
    pub fn range(&self, table: Table, top: f64, bottom: f64) -> Range<usize> {
        self.tops(table).range(top, bottom)
    }

    /// Where the document ends, after the rows and the padding below them.
    pub fn bottom(&self, table: Table) -> f64 {
        let tops = self.tops(table);
        tops.y(tops.count()) + self.padding
    }

    /// The hunk a row is in.
    pub fn hunk_at(&self, table: Table, index: usize) -> Option<usize> {
        self.hunks.iter().position(|h| h.range(table).contains(&index))
    }

    /// What to keep in place on the screen while the layout changes, as it's shown from `top`
    /// in a view `height` tall: the current hunk if it's in view, or else the point in the
    /// middle of the view.
    pub fn anchor(&self, table: Table, current: Option<usize>, top: f64, height: f64) -> Option<Anchor> {
        let tops = self.tops(table);
        if let Some(hunk) = current.and_then(|i| self.hunks.get(i)) {
            let range = hunk.range(table);
            let hunk_top = tops.y(range.start);
            if tops.y(range.end) > top && hunk_top < top + height {
                return Some(Anchor { index: range.start, fraction: 0.0, screen_y: hunk_top - top });
            }
        }
        let count = tops.count();
        if count == 0 {
            return None;
        }
        let y = top + height / 2.0;
        let index = tops.index_at(y).clamp(0, count as isize - 1) as usize;
        let (row_top, row_height) = (tops.y(index), tops.height(index));
        let fraction = if row_height > 0.0 { ((y - row_top) / row_height).clamp(0.0, 1.0) } else { 0.0 };
        Some(Anchor { index, fraction, screen_y: y - top })
    }

    /// Where to show the layout from to keep an anchor where it was on the screen.
    pub fn anchor_top(&self, table: Table, anchor: Anchor) -> f64 {
        let tops = self.tops(table);
        (tops.y(anchor.index) + anchor.fraction * tops.height(anchor.index) - anchor.screen_y).max(0.0)
    }

    /// Where to show the layout from to bring a hunk into view, a third of the way down a view
    /// `height` tall, or nowhere if it's already in view shown from `top`.
    pub fn scroll_to_hunk(&self, table: Table, hunk: usize, top: f64, height: f64) -> Option<f64> {
        let range = self.hunks.get(hunk)?.range(table);
        let tops = self.tops(table);
        let (hunk_top, hunk_bottom) = (tops.y(range.start), tops.y(range.end));
        if hunk_top >= top && hunk_bottom <= top + height {
            return None;
        }
        Some((hunk_top - (height / 3.0).floor()).max(0.0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Side A: lines 0 and 1 unchanged, 2 removed; side B: lines 0 and 1, then 2 added.
    /// Side A's line 1 is twice as tall, wrapped.
    fn layout() -> Layout {
        let rows = [(Some(0), Some(0)), (Some(1), Some(1)), (Some(2), None), (None, Some(2))];
        let unified = [Some((0, 0)), Some((0, 1)), Some((0, 2)), Some((1, 2)), None];
        let hunks = vec![
            Hunk { rows: 2..3, unified: 2..3, lines: vec![2..3, 2..2] },
            Hunk { rows: 3..4, unified: 3..4, lines: vec![3..3, 2..3] },
        ];
        Layout::new(
            &[&[10.0, 20.0, 10.0], &[10.0, 10.0, 10.0]],
            rows.len(),
            |row, side| if side == 0 { rows[row].0 } else { rows[row].1 },
            unified.len(),
            |row| unified[row],
            hunks,
            4.0,
            10.0,
        )
    }

    #[test]
    fn rows_are_as_tall_as_their_tallest_line() {
        let l = layout();
        assert_eq!(l.rows.0, [4.0, 14.0, 34.0, 44.0, 54.0]);
        assert_eq!(l.lines[1].0, [4.0, 14.0, 24.0, 34.0]);
        // The last unified row shows no line, and is a line tall.
        assert_eq!(l.unified.0, [4.0, 14.0, 34.0, 44.0, 54.0, 64.0]);
        assert_eq!(l.bottom(Table::Rows), 58.0);
        assert_eq!(l.y(Table::Lines(7), 3), 4.0);
    }

    #[test]
    fn finding_rows() {
        let l = layout();
        assert_eq!(l.index_at(Table::Rows, 0.0), -1);
        assert_eq!(l.index_at(Table::Rows, 4.0), 0);
        assert_eq!(l.index_at(Table::Rows, 33.9), 1);
        assert_eq!(l.index_at(Table::Rows, 100.0), 4);
        assert_eq!(l.range(Table::Rows, 20.0, 40.0), 1..3);
        assert_eq!(l.range(Table::Rows, 0.0, 1000.0), 0..4);
        assert_eq!(l.y(Table::Rows, 99), 54.0);
    }

    #[test]
    fn finding_hunks() {
        let l = layout();
        assert_eq!(l.hunk_at(Table::Rows, 3), Some(1));
        assert_eq!(l.hunk_at(Table::Rows, 1), None);
        assert_eq!(l.hunk_at(Table::Lines(0), 2), Some(0));
        assert_eq!(l.hunk_at(Table::Lines(1), 2), Some(1));
    }

    #[test]
    fn anchors_keep_the_current_hunk_or_the_middle_in_place() {
        let l = layout();
        let hunk = l.anchor(Table::Rows, Some(1), 0.0, 50.0).unwrap();
        assert_eq!(hunk, Anchor { index: 3, fraction: 0.0, screen_y: 44.0 });
        assert_eq!(l.anchor_top(Table::Rows, hunk), 0.0);
        // Hunk 0 out of view, starting where the view ends: the middle of the view, halfway down row 1.
        let middle = l.anchor(Table::Rows, Some(0), 14.0, 20.0).unwrap();
        assert_eq!(middle, Anchor { index: 1, fraction: 0.5, screen_y: 10.0 });
        assert_eq!(l.anchor_top(Table::Rows, middle), 14.0);
        let empty = Layout::new(&[], 0, |_, _| None, 0, |_| None, vec![], 4.0, 10.0);
        assert_eq!(empty.anchor(Table::Rows, None, 0.0, 50.0), None);
    }

    #[test]
    fn scrolling_to_a_hunk_out_of_view() {
        let l = layout();
        assert_eq!(l.scroll_to_hunk(Table::Rows, 1, 0.0, 100.0), None);
        assert_eq!(l.scroll_to_hunk(Table::Rows, 1, 0.0, 30.0), Some(34.0));
        assert_eq!(l.scroll_to_hunk(Table::Rows, 9, 0.0, 30.0), None);
    }
}
