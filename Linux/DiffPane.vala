namespace Diffotron {
	/* A caret position in one side's text: a line, and a byte offset into it. */
	struct TextPosition {
		int line;
		int index;

		public bool before (TextPosition other) {
			return line < other.line || (line == other.line && index < other.index);
		}

		public bool equals (TextPosition other) {
			return line == other.line && index == other.index;
		}
	}

	/* What a click selects, which dragging or shift-clicking then extends the selection by. */
	enum Granularity {
		CHARACTERS,
		WORDS, /* for a double click */
		LINES  /* for a triple click */
	}

	/*
	 * One side's text, as the DiffView lays it out for its mode, scrolled to where
	 * it says: its lines, its changes, and the selection, which Ctrl+C copies.
	 */
	public class DiffPane : Gtk.Widget {
		const TextPosition NO_POSITION = { -1, 0 };

		weak DiffView owner;
		int side;
		/* The widest line, in columns. */
		public uint32 max_columns { get; private set; }
		/* Where the pointer last was, down from the top, for Fluid mode's scrolling. */
		public double pointer_y { get; private set; }

		/* The selection, from anchor where it started to head, or none when anchor.line < 0. */
		TextPosition anchor = NO_POSITION;
		TextPosition head = NO_POSITION;
		/*
		 * What stays selected as the selection's extended by granularity, from
		 * unit_start to unit_end: what the click starting it selected, or after a
		 * shift-click, the end the click left in place.
		 */
		TextPosition unit_start = NO_POSITION;
		TextPosition unit_end = NO_POSITION;
		Granularity granularity = Granularity.CHARACTERS;
		/* While dragging out the selection: from where, and past the top or bottom, scrolling. */
		double drag_x = 0;
		double drag_y = 0;
		bool dragging = false;
		uint autoscroll_id = 0;
		/* The file the context menu is for, and its actions. */
		File? menu_file = null;
		SimpleActionGroup actions = new SimpleActionGroup ();

		public DiffPane (DiffView owner, int side) {
			Object (focusable: true, overflow: Gtk.Overflow.HIDDEN);
			this.owner = owner;
			this.side = side;
			set_cursor_from_name ("text");

			var motion = new Gtk.EventControllerMotion ();
			motion.motion.connect ((x, y) => pointer_y = y);
			add_controller (motion);

			var click = new Gtk.GestureClick ();
			click.pressed.connect (pressed);
			add_controller (click);
			var drag = new Gtk.GestureDrag ();
			drag.drag_begin.connect ((x, y) => {
				drag_x = x;
				drag_y = y;
				dragging = true;
			});
			drag.drag_update.connect ((dx, dy) => {
				double start_x, start_y;
				drag.get_start_point (out start_x, out start_y);
				drag_x = start_x + dx;
				drag_y = start_y + dy;
				drag_to_point ();
			});
			drag.drag_end.connect (() => dragging = false);
			add_controller (drag);

			var menu_click = new Gtk.GestureClick () { button = Gdk.BUTTON_SECONDARY };
			menu_click.pressed.connect ((n, x, y) => show_context_menu (x, y));
			add_controller (menu_click);

			var shortcuts = new Gtk.ShortcutController ();
			shortcuts.add_shortcut (new Gtk.Shortcut (Gtk.ShortcutTrigger.parse_string ("<Control>c"),
				new Gtk.CallbackAction (() => { copy (); return true; })));
			shortcuts.add_shortcut (new Gtk.Shortcut (Gtk.ShortcutTrigger.parse_string ("<Control>a"),
				new Gtk.CallbackAction (() => { select_all (); return true; })));
			add_controller (shortcuts);

			add_action (actions, "copy", () => copy ());
			add_action (actions, "copy-path", () => {
				if (menu_file != null) get_clipboard ().set_text (menu_file.get_path ());
			});
			add_action (actions, "open", () => {
				if (menu_file != null) new Gtk.FileLauncher (menu_file).launch.begin (get_root () as Gtk.Window, null);
			});
			add_action (actions, "show-in-folder", () => {
				if (menu_file != null) new Gtk.FileLauncher (menu_file).open_containing_folder.begin (get_root () as Gtk.Window, null);
			});
			insert_action_group ("pane", actions);
		}

		delegate void Activate ();

		static void add_action (SimpleActionGroup group, string name, owned Activate activate) {
			var action = new SimpleAction (name, null);
			action.activate.connect (() => activate ());
			group.add_action (action);
		}

		public void diff_changed () {
			anchor = NO_POSITION;
			head = NO_POSITION;
			max_columns = 0;
			unowned Dt.FileDiff? diff = owner.diff;
			size_t count = diff != null ? diff.line_count ((uint8) side) : 0;
			for (size_t i = 0; i < count; i++) {
				uint32 columns = diff.line ((uint8) side, i).columns;
				if (columns > max_columns) max_columns = columns;
			}
			queue_draw ();
		}

		/* Selections are of a mode's lines, which another mode lays out differently. */
		public void mode_changed () {
			clear_selection ();
		}

		/* Text */

		/* The lines the pane shows and selects: its side's, or in Unified mode, the unified rows. */
		int line_count () {
			unowned Dt.FileDiff? diff = owner.diff;
			if (diff == null) return 0;
			if (owner.mode == Mode.UNIFIED) return (int) diff.unified_count ();
			return (int) diff.line_count ((uint8) side);
		}

		string text_of_line (int line) {
			unowned Dt.FileDiff? diff = owner.diff;
			if (diff == null || line < 0) return "";
			int line_side = side;
			size_t index = line;
			if (owner.mode == Mode.UNIFIED && !owner.unified_row (line, out line_side, out index)) return "";
			return text (diff.line ((uint8) line_side, index).text);
		}


		/* Drawing */

		public override void snapshot (Gtk.Snapshot snapshot) {
			var colors = Colors.for_widget (this);
			double width = get_width ();
			double height = get_height ();
			DiffView.fill (snapshot, colors.background, 0, 0, width, height);
			unowned Dt.FileDiff? diff = owner.diff;
			if (diff == null) return;
			unowned Dt.Layout layout = owner.layout;
			double y = owner.vertical_offset ();
			size_t first, last;

			if (owner.mode == Mode.UNIFIED) {
				layout.range (Dt.TABLE_UNIFIED, y, y + height, out first, out last);
				for (size_t row = first; row < last; row++) {
					int line_side;
					size_t line;
					if (!owner.unified_row (row, out line_side, out line)) continue;
					double top = layout.y (Dt.TABLE_UNIFIED, row) - y;
					double bottom = layout.y (Dt.TABLE_UNIFIED, row + 1) - y;
					draw_line (snapshot, (int32) line, line_side, (int) row, top, bottom - top, owner.unified_row_in_current_hunk (row));
				}
				owner.draw_unified_groups (snapshot, first, last, width, y);
				owner.draw_flash (snapshot, side, width, y);
				return;
			}

			if (owner.mode == Mode.FLUID) {
				double offset = y + owner.shift (side);
				layout.range ((uint8) side, offset, offset + height, out first, out last);
				for (size_t line = first; line < last; line++) {
					double top = layout.y ((uint8) side, line) - offset;
					double bottom = layout.y ((uint8) side, line + 1) - offset;
					draw_line (snapshot, (int32) line, side, (int) line, top, bottom - top, owner.line_in_current_hunk (line, side));
				}
				owner.draw_side_hunks (snapshot, side, width, height, offset);
				owner.draw_flash (snapshot, side, width, offset);
				return;
			}

			layout.range (Dt.TABLE_ROWS, y, y + height, out first, out last);
			for (size_t row = first; row < last; row++) {
				double top = layout.y (Dt.TABLE_ROWS, row) - y;
				double bottom = layout.y (Dt.TABLE_ROWS, row + 1) - y;
				int32 line = diff.row_line (row, (uint8) side);
				draw_line (snapshot, line, side, line, top, bottom - top, owner.row_in_current_hunk (row));
			}
			if (!owner.side_is_empty (side)) owner.draw_hunks (snapshot, width, height, y, false);
			owner.draw_flash (snapshot, side, width, y);
		}

		/*
		 * A side's line, from top, or filler for none. A wrapped line takes
		 * several lines. selection_line is where the selection has it.
		 */
		void draw_line (Gtk.Snapshot snapshot, int32 line_index, int line_side, int selection_line, double top, double height, bool current) {
			var colors = Colors.for_widget (this);
			double width = get_width ();
			if (line_index < 0) {
				DiffView.fill (snapshot, colors.filler, 0, top, width, height);
				return;
			}
			var line = owner.diff.line ((uint8) line_side, line_index);
			bool changed = line.kind != Dt.LINE_EQUAL && line.kind < KIND_COUNT;
			if (changed) DiffView.fill (snapshot, colors.line_color (line.kind, current), 0, top, width, height);

			var layout = owner.text_layout (text (line.text));
			double text_x = TEXT_PADDING - owner.horizontal_offset (owner.mode == Mode.UNIFIED ? 0 : side);
			double line_height = owner.line_height;
			int from = 0, to = 0;
			bool through_end = false;
			bool selected = selection_in_line (selection_line, out from, out to, out through_end);
			var selection_color = colors.accent;
			selection_color.alpha = has_focus ? 0.35f : 0.18f;

			snapshot.push_clip (Graphene.Rect () { origin = { 0, (float) top }, size = { (float) width, (float) height } });
			int index = 0;
			unowned SList<Pango.LayoutLine> lines = layout.get_lines_readonly ();
			int count = (int) lines.length ();
			foreach (unowned Pango.LayoutLine layout_line in lines) {
				int start = layout_line.start_index;
				int end = start + layout_line.length;
				bool last = index + 1 == count;
				double y = top + index * line_height;

				for (uint32 i = 0; changed && i < line.span_count; i++) {
					var span = line.spans[i];
					int span_start = int.max ((int) span.start, start);
					int span_end = int.min ((int) span.end, end);
					if (span_start >= span_end) continue;
					var ranges = x_ranges (layout_line, span_start, span_end);
					for (int r = 0; r + 1 < ranges.length; r += 2) {
						DiffView.fill (snapshot, colors.emphasis[line.kind], text_x + ranges[r], y + owner.text_inset,
							ranges[r + 1] - ranges[r], owner.font_line_height);
					}
				}

				/*
				 * The selection on this line of the text: through to the edge where it
				 * goes on past it, onto the next line or past the line break.
				 */
				if (selected && (last ? from <= end : from < end && to > start)) {
					int selection_start = int.max (from, start);
					bool to_edge = last ? through_end : to > end;
					int selection_end = int.min (to, end);
					double x0 = text_x + x_at (layout_line, selection_start);
					double x1 = to_edge ? width : text_x + x_at (layout_line, selection_end);
					if (x1 > x0) DiffView.fill (snapshot, selection_color, x0, y, x1 - x0, line_height);
				}
				index++;
			}
			snapshot.save ();
			snapshot.translate (Graphene.Point () { x = (float) text_x, y = (float) (top + owner.text_inset) });
			snapshot.append_layout (layout, get_color ());
			snapshot.restore ();
			snapshot.pop ();
		}

		/* Where a byte offset is along a laid-out line, in points from the line's start. */
		static double x_at (Pango.LayoutLine line, int index) {
			int x;
			line.index_to_x (index, false, out x);
			return (double) x / Pango.SCALE;
		}

		/*
		 * The stretches along a laid-out line of the text from start to end, in
		 * points from the line's start: each one's start, then its end.
		 */
		static double[] x_ranges (Pango.LayoutLine line, int start, int end) {
			int[] ranges;
			line.get_x_ranges (start, end, out ranges);
			/* Pango counts the ranges, which Vala takes for the array's length, but each is two numbers. */
			int count = ranges.length * 2;
			var result = new double[count];
			for (int i = 0; i < count; i++) result[i] = (double) ranges[i] / Pango.SCALE;
			return result;
		}


		/* Selection */

		bool has_selection () {
			return anchor.line >= 0 && !anchor.equals (head);
		}

		void clear_selection () {
			if (anchor.line < 0) return;
			anchor = NO_POSITION;
			head = NO_POSITION;
			queue_draw ();
		}

		/* The selection's start and end, in order. */
		void selection_bounds (out TextPosition start, out TextPosition end) {
			bool forward = anchor.before (head);
			start = forward ? anchor : head;
			end = forward ? head : anchor;
		}

		/* The selected part of a line, and whether the selection continues past its end. */
		bool selection_in_line (int line, out int from, out int to, out bool through_end) {
			from = 0;
			to = 0;
			through_end = false;
			if (!has_selection ()) return false;
			TextPosition start, end;
			selection_bounds (out start, out end);
			if (line < start.line || line > end.line) return false;
			from = line == start.line ? start.index : 0;
			to = line == end.line ? end.index : int.MAX;
			through_end = line < end.line;
			return true;
		}

		string selected_text () {
			if (!has_selection ()) return "";
			TextPosition start, end;
			selection_bounds (out start, out end);
			var builder = new StringBuilder ();
			for (int line = start.line; line <= end.line; line++) {
				string line_text = text_of_line (line);
				int from = line == start.line ? int.min (start.index, line_text.length) : 0;
				int to = line == end.line ? int.min (end.index, line_text.length) : line_text.length;
				if (to > from) builder.append (line_text.substring (from, to - from));
				if (line < end.line) builder.append ("\n");
			}
			return builder.str;
		}

		void select (TextPosition from, TextPosition to) {
			anchor = from;
			head = to;
			for (int other = 0; other < MAX_SIDES; other++) {
				if (other != side) owner.pane (other).clear_selection ();
			}
			queue_draw ();
		}

		public void copy () {
			if (has_selection ()) get_clipboard ().set_text (selected_text ());
		}

		public void select_all () {
			int lines = line_count ();
			if (lines == 0) return;
			TextPosition start = { 0, 0 };
			TextPosition end = { lines - 1, text_of_line (lines - 1).length };
			granularity = Granularity.CHARACTERS;
			unit_start = start;
			unit_end = start;
			select (start, end);
		}

		/* The byte offset in a line's text nearest x, on the wrapped line dy down from its top. */
		int index_in_text (string line_text, double x, double dy) {
			var layout = owner.text_layout (line_text);
			int index, trailing;
			layout.xy_to_index ((int) (x * Pango.SCALE), (int) (double.max (dy - owner.text_inset, 0) * Pango.SCALE), out index, out trailing);
			/* Past the middle of a character, the position after it. */
			for (int i = 0; i < trailing && index < line_text.length; i++) {
				unichar c;
				line_text.get_next_char (ref index, out c);
			}
			return int.min (index, line_text.length);
		}

		/* The caret position nearest a point. */
		TextPosition position_at (double x, double y) {
			unowned Dt.FileDiff? diff = owner.diff;
			if (diff == null) return NO_POSITION;
			int lines = line_count ();
			if (lines == 0) return NO_POSITION;
			unowned Dt.Layout layout = owner.layout;
			int last_line = lines - 1;
			TextPosition start = { 0, 0 };
			TextPosition end = { last_line, text_of_line (last_line).length };
			double offset = owner.vertical_offset ();
			double text_x = x - TEXT_PADDING + owner.horizontal_offset (owner.mode == Mode.UNIFIED ? 0 : side);

			int line;
			double top;
			if (owner.mode == Mode.UNIFIED) {
				ssize_t row = layout.index_at (Dt.TABLE_UNIFIED, y + offset);
				if (row < 0) return start;
				if (row > last_line) return end;
				line = (int) row;
				top = layout.y (Dt.TABLE_UNIFIED, row) - offset;
			} else if (owner.mode == Mode.FLUID) {
				double shift = owner.shift (side);
				ssize_t found = layout.index_at ((uint8) side, y + offset + shift);
				if (found < 0) return start;
				if (found > last_line) return end;
				line = (int) found;
				top = layout.y ((uint8) side, found) - offset - shift;
			} else {
				size_t rows = diff.row_count ();
				ssize_t row = layout.index_at (Dt.TABLE_ROWS, y + offset);
				if (row < 0) return start;
				if (row >= (ssize_t) rows) return end;
				line = diff.row_line (row, (uint8) side);
				top = layout.y (Dt.TABLE_ROWS, row) - offset;
				if (line < 0) {
					/* A filler row: the end of the line before it, or else the start of the line after. */
					for (ssize_t r = row - 1; r >= 0; r--) {
						int32 before = diff.row_line (r, (uint8) side);
						if (before >= 0) return { before, text_of_line (before).length };
					}
					for (size_t r = row + 1; r < rows; r++) {
						int32 after = diff.row_line (r, (uint8) side);
						if (after >= 0) return { after, 0 };
					}
					return NO_POSITION;
				}
			}
			return { line, index_in_text (text_of_line (line), text_x, y - top) };
		}

		void pressed (Gtk.GestureClick click, int n_press, double x, double y) {
			grab_focus ();
			unowned Dt.FileDiff? diff = owner.diff;
			if (diff == null) return;
			unowned Dt.Layout layout = owner.layout;
			double offset = owner.vertical_offset ();
			if (owner.mode == Mode.FLUID) {
				ssize_t line = layout.index_at ((uint8) side, y + offset + owner.shift (side));
				if (line >= 0) owner.select_hunk (layout.hunk_at ((uint8) side, line));
			} else if (owner.mode == Mode.UNIFIED) {
				ssize_t row = layout.index_at (Dt.TABLE_UNIFIED, y + offset);
				if (row >= 0) owner.select_hunk (layout.hunk_at (Dt.TABLE_UNIFIED, row));
			} else {
				ssize_t row = layout.index_at (Dt.TABLE_ROWS, y + offset);
				if (row >= 0) owner.select_hunk (layout.hunk_at (Dt.TABLE_ROWS, row));
			}

			bool extend = (click.get_current_event_state () & Gdk.ModifierType.SHIFT_MASK) != 0 && anchor.line >= 0;
			var position = position_at (x, y);
			if (position.line < 0) {
				clear_selection ();
				return;
			}

			/*
			 * A double click selects a word, and a triple click a line; dragging from
			 * either, or shift-clicking, selects whole words or lines. Shift-clicking
			 * moves the end of the selection nearest the click to it, by what the
			 * selection was made with when clicking once.
			 */
			granularity = n_press >= 3 ? Granularity.LINES
				: n_press == 2 ? Granularity.WORDS
				: extend ? granularity
				: Granularity.CHARACTERS;
			if (extend) {
				TextPosition start, end;
				selection_bounds (out start, out end);
				bool move_start = position.before (start)
					|| (!end.before (position) && distance (start, position) < distance (position, end));
				/* The other end stays put, and the selection extends from it. */
				unit_start = move_start ? end : start;
				unit_end = unit_start;
				extend_selection_to (position);
			} else {
				unit_at (position, out unit_start, out unit_end);
				select (unit_start, unit_end);
			}
		}

		/* The character class of a word's characters, spaces, and other characters, each a unit of its own. */
		static int char_class (unichar c) {
			if (c.isalnum () || c == '_') return 0;
			if (c.isspace ()) return 1;
			return 2;
		}

		/* What the selection's granularity selects at a position: the position itself, its word, or its line. */
		void unit_at (TextPosition position, out TextPosition start, out TextPosition end) {
			string line_text = text_of_line (position.line);
			switch (granularity) {
				case Granularity.WORDS:
					/* The word, or the run of spaces, a double click selects; any other character on its own. */
					int index = int.min (position.index, line_text.length);
					if (index == line_text.length && index > 0) index = previous_char (line_text, index);
					int word_start = index, word_end = index;
					if (index < line_text.length) {
						unichar c = line_text.get_char (index);
						int kind = char_class (c);
						word_end = index;
						line_text.get_next_char (ref word_end, out c);
						if (kind != 2) {
							while (word_start > 0 && char_class (line_text.get_char (previous_char (line_text, word_start))) == kind) {
								word_start = previous_char (line_text, word_start);
							}
							while (word_end < line_text.length && char_class (line_text.get_char (word_end)) == kind) {
								line_text.get_next_char (ref word_end, out c);
							}
						}
					}
					start = { position.line, word_start };
					end = { position.line, word_end };
					break;
				case Granularity.LINES:
					/* The whole line, through its line break when there's a next line. */
					start = { position.line, 0 };
					end = { position.line, line_text.length };
					if (position.line + 1 < line_count ()) end = { position.line + 1, 0 };
					break;
				default:
					start = position;
					end = position;
					break;
			}
		}

		static int previous_char (string s, int index) {
			unowned string rest = s.offset (index);
			unowned string? previous = rest.prev_char ();
			return previous != null ? (int) ((char*) previous - (char*) s) : 0;
		}

		/* How many characters there are from a position to one after it, counting each line break as one. */
		int distance (TextPosition from, TextPosition to) {
			if (from.line == to.line) return int.max (to.index - from.index, 0);
			int result = text_of_line (from.line).length - from.index + 1;
			for (int line = from.line + 1; line < to.line; line++) result += text_of_line (line).length + 1;
			return result + to.index;
		}

		/* Select from what stays selected to the unit at a position, keeping both whole. */
		void extend_selection_to (TextPosition position) {
			TextPosition start, end;
			unit_at (position, out start, out end);
			bool backward = start.before (unit_start);
			TextPosition first = backward ? start : unit_start;
			TextPosition last = unit_end.before (end) ? end : unit_end;
			select (backward ? last : first, backward ? first : last);
		}

		/* Extend the selection to where the pointer's dragged, scrolling while it's past the top or bottom. */
		void drag_to_point () {
			var position = position_at (drag_x, drag_y);
			if (position.line >= 0 && !position.equals (head)) extend_selection_to (position);
			bool outside = drag_y < 0 || drag_y > get_height ();
			if (outside && autoscroll_id == 0) {
				autoscroll_id = add_tick_callback (() => {
					double past = drag_y < 0 ? drag_y : drag_y - get_height ();
					if (!dragging || past == 0 || (drag_y >= 0 && drag_y <= get_height ())) {
						autoscroll_id = 0;
						return Source.REMOVE;
					}
					var adjustment = owner.vadjustment;
					adjustment.value = (adjustment.value + past / 4).clamp (0, double.max (adjustment.upper - adjustment.page_size, 0));
					var dragged = position_at (drag_x, drag_y);
					if (dragged.line >= 0) extend_selection_to (dragged);
					return Source.CONTINUE;
				});
			}
		}


		/* Context menu */

		void show_context_menu (double x, double y) {
			grab_focus ();
			menu_file = owner.files[side];
			var menu = new Menu ();
			var edit = new Menu ();
			edit.append ("Copy", "pane.copy");
			menu.append_section (null, edit);
			if (menu_file != null) {
				var file = new Menu ();
				file.append ("Open “%s”".printf (menu_file.get_basename ()), "pane.open");
				file.append ("Show in Folder", "pane.show-in-folder");
				file.append ("Copy Path", "pane.copy-path");
				menu.append_section (null, file);
			}
			var popover = new Gtk.PopoverMenu.from_model (menu);
			popover.set_parent (this);
			popover.has_arrow = false;
			popover.pointing_to = Gdk.Rectangle () { x = (int) x, y = (int) y, width = 1, height = 1 };
			popover.closed.connect (() => Idle.add (() => {
				popover.unparent ();
				return false;
			}));
			((SimpleAction) actions.lookup_action ("copy")).set_enabled (has_selection ());
			popover.popup ();
		}

	}
}
