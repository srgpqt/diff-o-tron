//! Fluid mode's scrolling. In Fluid mode, each side of a diff shows its own lines together,
//! without the filler of the side-by-side rows, and the sides scroll to keep lined up.
//!
//! Positions are in points down the document, as the front end lays it out: the shared layout
//! is the side-by-side rows, each as tall as its tallest line, and each side's own layout is its
//! lines. The side scrolled over leads, moving with the wheel, and the others line up with it,
//! the same part of the way through each run of hunks; scrolled some other way, as with the
//! scroller, the sides line up with the shared layout. When they line up anew, they glide into line.

use std::ops::Range;

/// Each run of touching hunks is widened into the unchanged lines around it, by at least this
/// many lines, until no side runs more than `MAX_RATIO` times as fast as another across it.
const MIN_MARGIN_LINES: f64 = 3.0;
const MAX_RATIO: f64 = 3.0;

/// Sides lining up anew glide into line, closing the gap at this rate, in seconds, at no more
/// than this speed in points a second.
const GLIDE_TIME: f64 = 0.1;
const MAX_GLIDE_SPEED: f64 = 4000.0;

/// How far the shared layout must move from where the leader scrolled it for it to have been
/// scrolled some other way, allowing for the front end rounding it to pixels.
const SCROLLED_TOLERANCE: f64 = 1.0;

/// A hunk of the diff: its rows, and each side's lines.
#[derive(Clone, Debug, PartialEq)]
pub struct Hunk {
    pub rows: Range<usize>,
    pub lines: Vec<Range<usize>>,
}

/// A map from the shared layout to a side's own, through points where they meet, in order of
/// both, and one to one before the first and after the last.
#[derive(Debug, Default)]
struct Map(Vec<(f64, f64)>);

impl Map {
    fn side(&self, shared: f64) -> f64 {
        interpolate(&self.0, shared, |&(shared, side)| (shared, side))
    }

    fn shared(&self, side: f64) -> f64 {
        interpolate(&self.0, side, |&(shared, side)| (side, shared))
    }
}

/// The y for x along the line through `points`, as `key` gives their (x, y).
fn interpolate(points: &[(f64, f64)], x: f64, key: impl Fn(&(f64, f64)) -> (f64, f64)) -> f64 {
    let Some(first) = points.first() else { return x };
    let i = points.partition_point(|p| key(p).0 <= x);
    if i == 0 {
        let (x0, y0) = key(first);
        return y0 + (x - x0);
    }
    let (x0, y0) = key(&points[i - 1]);
    match points.get(i).map(&key) {
        Some((x1, y1)) if x1 > x0 => y0 + (x - x0) * (y1 - y0) / (x1 - x0),
        Some(_) => y0,
        None => y0 + (x - x0),
    }
}

/// The side scrolled over, which the others line up with.
#[derive(Debug)]
struct Leader {
    side: usize,
    /// Where it shows from in its own layout.
    top: f64,
    /// Where in the view the pointer was.
    pointer: f64,
    /// Where it last scrolled the shared layout to.
    y: f64,
}

#[derive(Debug, Default)]
pub struct Fluid {
    maps: Vec<Map>,
    /// Where the shared layout ends, and each side's own, padding included.
    shared_end: f64,
    side_ends: Vec<f64>,
    leader: Option<Leader>,
    /// How far each side is still to glide, to line up.
    glide: Vec<f64>,
}

impl Fluid {
    /// `rows` has where each row starts, then where the last ends; `lines` the same for each
    /// side's lines. `padding` is the space after the last row, and after each side's last line.
    pub fn new(hunks: &[Hunk], rows: &[f64], lines: &[&[f64]], padding: f64, line_height: f64) -> Fluid {
        let at = |tops: &[f64], i: usize| tops.get(i).or(tops.last()).copied().unwrap_or(0.0);
        let sides = lines.len();

        // Runs of touching hunks.
        let mut runs: Vec<Hunk> = Vec::new();
        for hunk in hunks {
            match runs.last_mut() {
                Some(run) if run.rows.end == hunk.rows.start => {
                    run.rows.end = hunk.rows.end;
                    for (run_lines, lines) in run.lines.iter_mut().zip(&hunk.lines) {
                        run_lines.end = lines.end;
                    }
                }
                _ => runs.push(hunk.clone()),
            }
        }

        // Meeting at the start, around each run widened into the unchanged lines around it, and
        // at the end, with the unchanged lines between one to one. Widened, a side with few or
        // no lines in a run still moves across it as the others do, and none has to jump.
        let row_end = rows.len().saturating_sub(1);
        let mut maps: Vec<Map> = lines.iter().map(|tops| Map(vec![(at(rows, 0), at(tops, 0))])).collect();
        for (i, run) in runs.iter().enumerate() {
            let (top, bottom) = (at(rows, run.rows.start), at(rows, run.rows.end));
            // As far as the unchanged lines go: to the start or end, or halfway to the next run.
            let room_above = match i {
                0 => top - at(rows, 0),
                _ => (top - at(rows, runs[i - 1].rows.end)) / 2.0,
            };
            let room_below = match runs.get(i + 1) {
                Some(next) => (at(rows, next.rows.start) - bottom) / 2.0,
                None => at(rows, row_end) - bottom,
            };
            let heights = || lines.iter().zip(&run.lines).map(|(tops, r)| at(tops, r.end) - at(tops, r.start));
            let least = heights().fold(f64::INFINITY, f64::min);
            let most = heights().fold(0.0, f64::max);
            // Widened by margin, a run is (most + 2 margin) / (least + 2 margin) times as tall on
            // one side as another.
            let margin = ((most - MAX_RATIO * least) / (MAX_RATIO - 1.0) / 2.0).max(MIN_MARGIN_LINES * line_height);
            let above = margin.min(room_above).max(0.0);
            let below = margin.min(room_below).max(0.0);
            for ((map, tops), r) in maps.iter_mut().zip(lines).zip(&run.lines) {
                map.0.push((top - above, at(tops, r.start) - above));
                map.0.push((bottom + below, at(tops, r.end) + below));
            }
        }
        for (map, tops) in maps.iter_mut().zip(lines) {
            map.0.push((at(rows, row_end), at(tops, tops.len().saturating_sub(1))));
        }

        Fluid {
            maps,
            shared_end: at(rows, row_end) + padding,
            side_ends: lines.iter().map(|tops| at(tops, tops.len().saturating_sub(1)) + padding).collect(),
            leader: None,
            glide: vec![0.0; sides],
        }
    }

    /// Where a side shows from in its own layout, gliding or not, with the shared layout
    /// scrolled down to `y` in a view `height` tall.
    pub fn top(&self, side: usize, y: f64, height: f64) -> f64 {
        match self.glide.get(side) {
            Some(glide) => self.lined_up_top(side, y, height) + glide,
            None => y,
        }
    }

    /// Where a side shows from once lined up.
    fn lined_up_top(&self, side: usize, y: f64, height: f64) -> f64 {
        match &self.leader {
            None => {
                // Line the sides up at a point that moves from the top of the view to the bottom
                // as it scrolls down, so that they start and end together.
                let range = self.shared_end - height;
                let fraction = if range > 0.0 { (y / range).clamp(0.0, 1.0) } else { 0.0 };
                self.maps[side].side(y + fraction * height) - fraction * height
            }
            Some(leader) if leader.side == side => leader.top,
            Some(leader) => {
                // Line the side up with the leader at the pointer, but at the top of the view
                // when the leader's close to its start, and the bottom when it's close to its
                // end, so that the sides start and end together.
                let range = self.range(leader.side, height);
                let point = leader.pointer.min(leader.top).max(height - (range - leader.top)).clamp(0.0, height);
                let shared = self.maps[leader.side].shared(leader.top + point);
                (self.maps[side].side(shared) - point).clamp(0.0, self.range(side, height).max(0.0))
            }
        }
    }

    /// How far a side's own layout scrolls in a view `height` tall.
    fn range(&self, side: usize, height: f64) -> f64 {
        self.side_ends[side] - height
    }

    /// Scroll down by `delta` for a wheel over a side, with the pointer `pointer` down the view.
    /// The side moves with the wheel, and the others line up with it. Returns where to scroll
    /// the shared layout to, from `y`, as for the scroller.
    pub fn scroll(&mut self, side: usize, delta: f64, pointer: f64, y: f64, height: f64) -> f64 {
        let shared_range = (self.shared_end - height).max(0.0);
        // A side too short to scroll scrolls the shared layout.
        if side >= self.maps.len() || self.range(side, height) <= 0.0 {
            if self.leader.is_some() {
                self.lead(None, y, height);
            }
            return (y + delta).clamp(0.0, shared_range);
        }
        let leading = self.leader.as_ref().is_some_and(|l| l.side == side && (pointer - l.pointer).abs() < 1.0);
        if !leading {
            self.lead(Some((side, pointer)), y, height);
        }
        let range = self.range(side, height);
        let map = &self.maps[side];
        let Some(leader) = self.leader.as_mut() else { return y };
        leader.top = (leader.top + delta).clamp(0.0, range);
        // The shared layout, for the scroller, where it shows the leader from.
        let point = leader.pointer.clamp(0.0, height);
        leader.y = (map.shared(leader.top + point) - point).clamp(0.0, shared_range);
        leader.y
    }

    /// The shared layout was scrolled to `y`, perhaps some other way than for the wheel, as by
    /// the scroller: if so, the sides line up with it again.
    pub fn scrolled(&mut self, y: f64, height: f64) {
        if self.leader.as_ref().is_some_and(|l| (y - l.y).abs() >= SCROLLED_TOLERANCE) {
            self.lead(None, y, height);
        }
    }

    /// Line the sides up anew, with a leader and where the pointer is, or with the shared
    /// layout, gliding each from where it shows now.
    fn lead(&mut self, leader: Option<(usize, f64)>, y: f64, height: f64) {
        let tops: Vec<f64> = (0..self.glide.len()).map(|side| self.top(side, y, height)).collect();
        self.leader = leader.map(|(side, pointer)| Leader { side, top: tops[side], pointer, y });
        for (side, top) in tops.into_iter().enumerate() {
            let gap = top - self.lined_up_top(side, y, height);
            self.glide[side] = if gap.abs() < 0.5 { 0.0 } else { gap };
        }
    }

    pub fn gliding(&self) -> bool {
        self.glide.iter().any(|&gap| gap != 0.0)
    }

    /// Glide for `elapsed` seconds. Returns whether the sides are still gliding.
    pub fn glide(&mut self, elapsed: f64) -> bool {
        for gap in &mut self.glide {
            // Closing the gap fast, then slowly, but not too fast.
            let step = (gap.abs() * (1.0 - (-elapsed / GLIDE_TIME).exp())).min(MAX_GLIDE_SPEED * elapsed);
            *gap = if gap.abs() - step < 0.5 { 0.0 } else { *gap - step.copysign(*gap) };
        }
        self.gliding()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LINE: f64 = 16.0;
    const PADDING: f64 = 4.0;
    const HEIGHT: f64 = 30.0 * LINE;

    /// Tops for `count` lines of LINE points, after PADDING.
    fn tops(count: usize) -> Vec<f64> {
        (0..=count).map(|i| PADDING + i as f64 * LINE).collect()
    }

    /// 50 unchanged lines, 100 added to side B, then 50 more unchanged.
    fn added_block() -> Fluid {
        let hunks = [Hunk { rows: 50..150, lines: vec![50..50, 50..150] }];
        Fluid::new(&hunks, &tops(200), &[&tops(100), &tops(200)], PADDING, LINE)
    }

    #[test]
    fn maps_widen_runs_into_the_unchanged_lines() {
        let f = added_block();
        // Widened by 400 points either side, the run is 800 points tall on side A and 2400 on B.
        assert_eq!(f.maps[0].0, [(4.0, 4.0), (404.0, 404.0), (2804.0, 1204.0), (3204.0, 1604.0)]);
        assert_eq!(f.maps[1].0, [(4.0, 4.0), (404.0, 404.0), (2804.0, 2804.0), (3204.0, 3204.0)]);
        assert_eq!(f.maps[0].side(1604.0), 804.0);
        assert_eq!(f.maps[0].shared(804.0), 1604.0);
        assert_eq!(f.maps[0].side(4000.0), 2400.0);
    }

    #[test]
    fn leader_moves_with_the_wheel_and_the_others_keep_up_without_jumping() {
        let mut f = added_block();
        let mut y = 0.0;
        let mut last = f.top(1, y, HEIGHT);
        for step in 1..=200 {
            y = f.scroll(0, 10.0, HEIGHT / 2.0, y, HEIGHT);
            f.glide(1.0);
            let top = f.top(0, y, HEIGHT);
            let range = f.range(0, HEIGHT);
            assert!((top - (step as f64 * 10.0).min(range)).abs() < 1e-9);
            // At most MAX_RATIO times as fast, or near the start or end, where the sides line up
            // at a point moving to the edge of the view, 2 MAX_RATIO - 1 times.
            let follower = f.top(1, y, HEIGHT);
            let most = 10.0 * (2.0 * MAX_RATIO - 1.0);
            assert!(follower - last <= most + 1e-9, "side B jumped {} at step {step}", follower - last);
            last = follower;
        }
        // They end together.
        assert_eq!(f.top(1, y, HEIGHT), f.range(1, HEIGHT));
    }

    #[test]
    fn sides_start_together() {
        let mut f = added_block();
        let y = f.scroll(1, 2000.0, 100.0, 0.0, HEIGHT);
        let y = f.scroll(1, -5000.0, 100.0, y, HEIGHT);
        f.glide(1.0);
        assert_eq!((f.top(0, y, HEIGHT), f.top(1, y, HEIGHT)), (0.0, 0.0));
    }

    #[test]
    fn scrolling_some_other_way_lines_up_with_the_shared_layout_gliding() {
        let mut f = added_block();
        let y = f.scroll(0, 600.0, 100.0, 0.0, HEIGHT);
        let shown = f.top(1, y, HEIGHT);
        // Not scrolled any further: still led by side A.
        f.scrolled(y + 0.5, HEIGHT);
        assert!(f.leader.is_some());
        f.scrolled(y + 100.0, HEIGHT);
        assert!(f.leader.is_none());
        // Gliding from where side B showed.
        assert!(f.gliding());
        assert!((f.top(1, y + 100.0, HEIGHT) - shown).abs() < 1e-9);
        while f.glide(1.0 / 60.0) {}
        assert_eq!(f.top(1, y + 100.0, HEIGHT), f.lined_up_top(1, y + 100.0, HEIGHT));
    }

    #[test]
    fn a_side_too_short_to_scroll_scrolls_the_shared_layout() {
        let hunks = [Hunk { rows: 0..100, lines: vec![0..10, 0..100] }];
        let mut f = Fluid::new(&hunks, &tops(100), &[&tops(10), &tops(100)], PADDING, LINE);
        assert_eq!(f.scroll(0, 50.0, 0.0, 0.0, HEIGHT), 50.0);
        assert!(f.leader.is_none());
    }

    #[test]
    fn no_hunks() {
        let f = Fluid::new(&[], &tops(10), &[&tops(10), &tops(10)], PADDING, LINE);
        assert_eq!(f.top(0, 20.0, 100.0), 20.0);
        let empty = Fluid::new(&[], &[], &[&[], &[]], PADDING, LINE);
        assert_eq!(empty.top(1, 0.0, 100.0), 0.0);
        assert_eq!(empty.top(5, 7.0, 100.0), 7.0);
    }
}
