namespace Diffotron {
	/* One side's line numbers, which stay put when the side scrolls sideways. */
	public class DiffGutter : Gtk.Widget {
		weak DiffView owner;
		int side;

		public DiffGutter (DiffView owner, int side) {
			Object (overflow: Gtk.Overflow.HIDDEN);
			this.owner = owner;
			this.side = side;
		}

		public override void snapshot (Gtk.Snapshot snapshot) {
			var colors = Colors.for_widget (this);
			double width = get_width ();
			double height = get_height ();
			DiffView.fill (snapshot, colors.background, 0, 0, width, height);
			unowned Dt.FileDiff? diff = owner.diff;
			if (diff == null) return;
			unowned Dt.Layout layout = owner.layout;
			size_t first, last;

			if (owner.mode == Mode.UNIFIED) {
				/* A column of line numbers for each side, each run of changed lines marked with its side's letter. */
				double offset = owner.vertical_offset ();
				double column = owner.unified_column_width;
				layout.range (Dt.TABLE_UNIFIED, offset, offset + height, out first, out last);
				for (size_t row = first; row < last; row++) {
					bool current = owner.unified_row_in_current_hunk (row);
					bool group_start = owner.unified_group_starts_at_row (row);
					double top = layout.y (Dt.TABLE_UNIFIED, row) - offset;
					double row_height = layout.y (Dt.TABLE_UNIFIED, row + 1) - offset - top;
					for (int line_side = 0; line_side < SIDE_COUNT; line_side++) {
						int32 line = diff.unified_line (row, (uint8) line_side);
						if (line < 0) continue;
						double x = line_side * column;
						draw_line (snapshot, line, line_side, x, top, column, row_height, current);
						if (group_start) draw_text (snapshot, line_side == 0 ? "A" : "B", x + 4, top, false, column);
					}
				}
				owner.draw_unified_groups (snapshot, first, last, width, offset);
				owner.draw_flash (snapshot, side, width, offset);
				return;
			}

			if (owner.mode == Mode.FLUID) {
				double offset = owner.vertical_offset () + owner.shift (side);
				layout.range ((uint8) side, offset, offset + height, out first, out last);
				for (size_t line = first; line < last; line++) {
					double top = layout.y ((uint8) side, line) - offset;
					double bottom = layout.y ((uint8) side, line + 1) - offset;
					draw_line (snapshot, (int32) line, side, 0, top, width, bottom - top, owner.line_in_current_hunk (line, side));
				}
				owner.draw_side_hunks (snapshot, side, width, height, offset);
				owner.draw_flash (snapshot, side, width, offset);
				return;
			}

			double offset = owner.vertical_offset ();
			layout.range (Dt.TABLE_ROWS, offset, offset + height, out first, out last);
			for (size_t row = first; row < last; row++) {
				double top = layout.y (Dt.TABLE_ROWS, row) - offset;
				double bottom = layout.y (Dt.TABLE_ROWS, row + 1) - offset;
				draw_line (snapshot, diff.row_line (row, (uint8) side), side, 0, top, width, bottom - top, owner.row_in_current_hunk (row));
			}
			if (!owner.side_is_empty (side)) owner.draw_hunks (snapshot, width, height, offset, false);
			owner.draw_flash (snapshot, side, width, offset);
		}

		/* A line's number, at the top of its frame, or filler for none, on the line's background. */
		void draw_line (Gtk.Snapshot snapshot, int32 line_index, int line_side, double x, double top, double width, double height, bool current) {
			var colors = Colors.for_widget (this);
			if (line_index < 0) {
				DiffView.fill (snapshot, colors.filler, x, top, width, height);
				return;
			}
			var line = owner.diff.line ((uint8) line_side, line_index);
			if (line.kind != Dt.LINE_EQUAL && line.kind < KIND_COUNT) {
				DiffView.fill (snapshot, colors.line_color (line.kind, current), x, top, width, height);
			}
			draw_text (snapshot, "%d".printf (line_index + 1), x, top, true, width);
		}

		/* Text in the numbers' font, from x, or right-aligned in the width from x, on the line from top. */
		void draw_text (Gtk.Snapshot snapshot, string label, double x, double top, bool right_aligned, double width) {
			var layout = new Pango.Layout (get_pango_context ());
			layout.set_font_description (owner.number_font);
			layout.set_text (label, -1);
			int text_width, text_height;
			layout.get_pixel_size (out text_width, out text_height);
			double text_x = right_aligned ? x + width - GUTTER_PADDING - text_width : x;
			/* On the text's baseline, though the numbers are smaller. */
			double text_y = top + owner.text_inset + (owner.font_line_height - text_height) / 2;
			var color = get_color ();
			color.alpha *= 0.5f;
			snapshot.save ();
			snapshot.translate (Graphene.Point () { x = (float) text_x, y = (float) text_y });
			snapshot.append_layout (layout, color);
			snapshot.restore ();
		}
	}
}
