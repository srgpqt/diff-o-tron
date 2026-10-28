namespace Diffotron {
	/* The gap between a side and the next: bands joining each hunk on one to the same hunk on the other. */
	public class DiffConnector : Gtk.Widget {
		weak DiffView owner;
		int side;

		public DiffConnector (DiffView owner, int side) {
			Object (overflow: Gtk.Overflow.HIDDEN);
			this.owner = owner;
			this.side = side;
		}

		public override void snapshot (Gtk.Snapshot snapshot) {
			var colors = Colors.for_widget (this);
			double width = get_width ();
			double height = get_height ();
			DiffView.fill (snapshot, colors.middle, 0, 0, width, height);
			/* Nothing to join to a side with no lines. */
			if (owner.side_is_empty (side) || owner.side_is_empty (side + 1)) return;
			if (owner.mode != Mode.FLUID) {
				owner.draw_hunks (snapshot, width, height, owner.vertical_offset (), true);
				return;
			}

			/* Join each hunk on the side before to the same hunk on the side after: all their bands, then their edges over them. */
			unowned Dt.FileDiff diff = owner.diff;
			unowned Dt.Layout layout = owner.layout;
			size_t count = diff.hunk_count ();
			int next = side + 1;
			double offset = owner.vertical_offset () + owner.shift (side);
			double next_offset = owner.vertical_offset () + owner.shift (next);
			var cairo = snapshot.append_cairo (Graphene.Rect () { origin = { 0, 0 }, size = { (float) width, (float) height } });
			for (int pass = 0; pass < 2; pass++) {
				for (size_t i = 0; i < count; i++) {
					var hunk = diff.hunk (i);
					uint32 start, end, next_start, next_end;
					owner.hunk_lines (hunk, side, out start, out end);
					owner.hunk_lines (hunk, next, out next_start, out next_end);
					double top = layout.y ((uint8) side, start) - offset;
					double bottom = layout.y ((uint8) side, end) - offset;
					double next_top = layout.y ((uint8) next, next_start) - next_offset;
					double next_bottom = layout.y ((uint8) next, next_end) - next_offset;
					if (double.max (bottom, next_bottom) < -1 || double.min (top, next_top) > height + 1) continue;

					if (pass == 0) {
						cairo.move_to (0, top);
						cairo.line_to (width, next_top);
						cairo.line_to (width, next_bottom);
						cairo.line_to (0, bottom);
						cairo.close_path ();
						set_color (cairo, colors.line_color (hunk.kind, (ssize_t) i == owner.current_hunk));
						cairo.fill ();
						continue;
					}

					/*
					 * Edges along the hunks' outlines: the top's first pixel row, the bottom's
					 * last. Where the hunk before ends on both sides, its bottom edge is this
					 * one's top.
					 */
					bool touching = false;
					if (i > 0) {
						var previous = diff.hunk (i - 1);
						uint32 previous_start, previous_end, previous_next_start, previous_next_end;
						owner.hunk_lines (previous, side, out previous_start, out previous_end);
						owner.hunk_lines (previous, next, out previous_next_start, out previous_next_end);
						touching = previous_end == start && previous_next_end == next_start;
					}
					cairo.set_line_width (1);
					if (!touching) {
						cairo.move_to (0, top + 0.5);
						cairo.line_to (width, next_top + 0.5);
					}
					cairo.move_to (0, double.max (top, bottom - 1) + 0.5);
					cairo.line_to (width, double.max (next_top, next_bottom - 1) + 0.5);
					set_color (cairo, colors.edge[hunk.kind]);
					cairo.stroke ();
				}
			}
		}

		static void set_color (Cairo.Context cairo, Gdk.RGBA color) {
			cairo.set_source_rgba (color.red, color.green, color.blue, color.alpha);
		}
	}
}
