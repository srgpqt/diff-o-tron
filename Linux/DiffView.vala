namespace Diffotron {
	/*
	 * Draws a file diff as side-by-side panes. A DiffView lays out, for each
	 * side, a gutter of line numbers and a pane of the side's text with a
	 * scrollbar under it, with connectors between the sides, and a scrollbar for
	 * all of them at the right. Each side scrolls sideways on its own, and up
	 * and down together with the others, through the core's layout (Dt.Layout).
	 */
	public class DiffView : Gtk.Widget {
		/* How long the current hunk flashes, and scrolling to a hunk within a view takes, in seconds. */
		const double FLASH_DURATION = 0.4;
		const double SCROLL_TO_HUNK_DURATION = 0.2;
		/* Momentum after the fingers lift from a touchpad: how fast it slows, and when it stops. */
		const double MOMENTUM_TIME = 0.35;
		const double MIN_MOMENTUM_SPEED = 20;

		Dt.FileDiff? _diff = null;
		/* Where the lines and rows are, and Fluid mode's scrolling. */
		Dt.Layout _layout;
		public unowned Dt.FileDiff? diff { get { return _diff; } }
		public unowned Dt.Layout layout { get { return _layout; } }

		/* The files shown, for the panes' context menus: one per side, or null for none. */
		public File?[] files = new File?[MAX_SIDES];
		/* The sides the diff has: 2, or 3 for a merge. */
		public int side_count { get; private set; default = SIDE_COUNT; }
		/* Index of the highlighted hunk, or -1. */
		ssize_t _current_hunk = -1;
		public ssize_t current_hunk {
			get { return _current_hunk; }
			set {
				_current_hunk = value;
				redraw_all ();
			}
		}
		/* Emitted when a click changes current_hunk. */
		public signal void current_hunk_changed ();

		Mode _mode = Mode.FLUID;
		bool _wraps_lines = true;
		double _font_size = DEFAULT_FONT_SIZE;
		string _font_family = "";

		/* Font metrics, for the panes and gutters. */
		public Pango.FontDescription font { get; private set; }
		public Pango.FontDescription number_font { get; private set; }
		public Pango.TabArray tabs { get; private set; }
		public double line_height { get; private set; }
		public double font_line_height { get; private set; }
		public double text_inset { get; private set; }
		public double char_width { get; private set; }
		public double gutter_width { get; private set; }
		/* In Unified mode, the width of each side's column of line numbers in the gutter. */
		public double unified_column_width { get; private set; }
		/* The widest line of any side. */
		public uint32 max_columns { get; private set; }
		size_t max_lines = 0;
		/* The width lines are wrapped to, or 0 when they aren't. */
		public double wrap_width { get; private set; }

		DiffPane[] panes = new DiffPane[MAX_SIDES];
		DiffGutter[] gutters = new DiffGutter[MAX_SIDES];
		DiffConnector[] connectors = new DiffConnector[MAX_SIDES - 1];
		Gtk.Scrollbar[] hbars = new Gtk.Scrollbar[MAX_SIDES];
		Gtk.Scrollbar vbar;
		/* The shared layout's scroll position, and each side's sideways. */
		public Gtk.Adjustment vadjustment { get; private set; }
		Gtk.Adjustment[] hadjustments = new Gtk.Adjustment[MAX_SIDES];
		/* The panes' height, which the vertical scrolling's page is. */
		double view_height = 0;

		/* Set while scrolling for the wheel, so as not to take that as scrolling the shared layout. */
		bool wheeling = false;
		/* Whether fingers are on the touchpad, and the momentum after they lift, in points a second down. */
		bool in_gesture = false;
		int momentum_side = 0;
		double momentum_speed = 0;
		/* How lit up the current hunk is, from 1 when it starts flashing down to 0, and since when. */
		public double flash { get; private set; default = 0; }
		int64 flash_start = 0;
		/* Scrolling to a hunk: from where to where, since when. */
		double scroll_from = 0;
		double scroll_to = 0;
		int64 scroll_start = -1;
		uint tick_id = 0;
		int64 last_frame = 0;

		public DiffView () {
			Object (overflow: Gtk.Overflow.HIDDEN);
		}

		construct {
			_layout = new Dt.Layout (null, null, TOP_PADDING, 0);
			vadjustment = new Gtk.Adjustment (0, 0, 0, 1, 1, 0);
			vadjustment.value_changed.connect (vertical_scroll_changed);
			for (int side = 0; side < MAX_SIDES; side++) {
				var adjustment = new Gtk.Adjustment (0, 0, 0, 1, 1, 0);
				adjustment.value_changed.connect (() => redraw_all ());
				hadjustments[side] = adjustment;
				gutters[side] = new DiffGutter (this, side);
				gutters[side].set_parent (this);
				panes[side] = new DiffPane (this, side);
				panes[side].set_parent (this);
				hbars[side] = new Gtk.Scrollbar (Gtk.Orientation.HORIZONTAL, adjustment);
				hbars[side].set_parent (this);
				foreach (Gtk.Widget widget in new Gtk.Widget[] { panes[side], gutters[side] }) {
					add_scrolling (widget, side);
				}
				if (side + 1 < MAX_SIDES) {
					connectors[side] = new DiffConnector (this, side);
					connectors[side].set_parent (this);
				}
			}
			vbar = new Gtk.Scrollbar (Gtk.Orientation.VERTICAL, vadjustment);
			vbar.set_parent (this);
			update_font ();
			update_side_views ();
		}

		public override void dispose () {
			for (int side = 0; side < MAX_SIDES; side++) {
				panes[side]?.unparent ();
				gutters[side]?.unparent ();
				hbars[side]?.unparent ();
				if (side + 1 < MAX_SIDES) connectors[side]?.unparent ();
			}
			vbar?.unparent ();
			base.dispose ();
		}

		public Gtk.Adjustment hadjustment (int side) {
			return hadjustments[side];
		}

		public DiffPane pane (int side) {
			return panes[side];
		}

		/* Settings */

		public Mode mode {
			get { return _mode; }
			set {
				if (value == _mode) return;
				_mode = value;
				update_side_views ();
				/* Unified mode is wider, so lines wrap differently. */
				layout_lines ();
				foreach (var pane in panes) pane.mode_changed ();
				redraw_all ();
				scroll_to_current_hunk ();
			}
		}

		public bool wraps_lines {
			get { return _wraps_lines; }
			set {
				if (value == _wraps_lines) return;
				_wraps_lines = value;
				relayout_lines ();
			}
		}

		public double font_size {
			get { return _font_size; }
			set {
				_font_size = value;
				update_font ();
			}
		}

		/* The font family, or "" for the desktop's monospaced font. */
		public string font_family {
			get { return _font_family; }
			set {
				_font_family = value;
				update_font ();
			}
		}

		void update_font () {
			var description = Pango.FontDescription.from_string (_font_family != "" ? _font_family : "Monospace");
			description.set_size ((int) (_font_size * Pango.SCALE));
			font = description;
			var numbers = description.copy ();
			numbers.set_size ((int) ((_font_size - 1) * Pango.SCALE));
			number_font = numbers;

			var context = get_pango_context ();
			var metrics = context.get_metrics (description, null);
			font_line_height = (double) (metrics.get_ascent () + metrics.get_descent ()) / Pango.SCALE;
			line_height = Math.ceil (font_line_height * 1.3);
			text_inset = Math.floor ((line_height - font_line_height) / 2);
			var probe = new Pango.Layout (context);
			probe.set_font_description (description);
			probe.set_text ("0", -1);
			int width, height;
			probe.get_pixel_size (out width, out height);
			char_width = width;
			var tab_array = new Pango.TabArray (1, true);
			tab_array.set_tab (0, Pango.TabAlign.LEFT, (int) (char_width * TAB_WIDTH));
			tabs = tab_array;
			update_gutter_width ();
			relayout_lines ();
		}

		void update_gutter_width () {
			int digits = 3;
			for (size_t n = max_lines; n >= 1000; n /= 10) digits++;
			gutter_width = Math.ceil (digits * char_width + 2 * GUTTER_PADDING);
			/* Room for the side's letter before the line number. */
			unified_column_width = gutter_width + UNIFIED_LETTER_WIDTH;
			queue_allocate ();
		}


		/* The diff */

		/*
		 * Show a new diff, keeping where the view is scrolled to and the nearest
		 * hunk current if keep is set, as when the same files are reloaded.
		 */
		public void set_diff (owned Dt.FileDiff? diff, bool keep) {
			var anchor = keep ? scroll_anchor () : Dt.ScrollAnchor () { valid = false };
			/* Where the current hunk starts, in the current mode's rows, to find the nearest hunk in the new diff. */
			bool unified = _mode == Mode.UNIFIED;
			ssize_t hunk_row = -1;
			if (keep && _diff != null && current_hunk >= 0 && current_hunk < (ssize_t) _diff.hunk_count ()) {
				var hunk = _diff.hunk ((size_t) current_hunk);
				hunk_row = unified ? hunk.unified_start : hunk.row_start;
			}

			_diff = (owned) diff;
			flash = 0;
			current_hunk = _diff != null && _diff.hunk_count () > 0 ? 0 : -1;
			if (hunk_row >= 0 && current_hunk >= 0) current_hunk = _diff.nearest_hunk (unified, (size_t) hunk_row);
			side_count = _diff != null ? (int) _diff.side_count () : SIDE_COUNT;
			update_side_views ();
			max_lines = 0;
			max_columns = 0;
			for (int side = 0; _diff != null && side < side_count; side++) {
				size_t count = _diff.line_count ((uint8) side);
				if (count > max_lines) max_lines = count;
				for (size_t i = 0; i < count; i++) {
					uint32 columns = _diff.line ((uint8) side, i).columns;
					if (columns > max_columns) max_columns = columns;
				}
			}
			update_gutter_width ();
			layout_lines ();
			foreach (var pane in panes) pane.diff_changed ();
			if (!keep) {
				vadjustment.value = 0;
				foreach (var adjustment in hadjustments) adjustment.value = 0;
			}
			restore_scroll_anchor (anchor);
			redraw_all ();
		}

		/* Make a hunk clicked current, if it's one. */
		public void select_hunk (ssize_t hunk) {
			if (hunk < 0) return;
			current_hunk = hunk;
			current_hunk_changed ();
		}

		public bool side_is_empty (int side) {
			return _diff == null || _diff.line_count ((uint8) side) == 0;
		}

		/* The lines a hunk covers on a side. */
		public void hunk_lines (Dt.Hunk hunk, int side, out uint32 start, out uint32 end) {
			start = side < MAX_SIDES ? hunk.start[side] : 0;
			end = side < MAX_SIDES ? hunk.end[side] : 0;
		}

		public bool row_in_current_hunk (size_t row) {
			if (_diff == null || current_hunk < 0 || current_hunk >= (ssize_t) _diff.hunk_count ()) return false;
			var hunk = _diff.hunk ((size_t) current_hunk);
			return row >= hunk.row_start && row < hunk.row_end;
		}

		public bool line_in_current_hunk (size_t line, int side) {
			if (_diff == null || current_hunk < 0 || current_hunk >= (ssize_t) _diff.hunk_count ()) return false;
			uint32 start, end;
			hunk_lines (_diff.hunk ((size_t) current_hunk), side, out start, out end);
			return line >= start && line < end;
		}

		public bool unified_row_in_current_hunk (size_t row) {
			if (_diff == null || current_hunk < 0 || current_hunk >= (ssize_t) _diff.hunk_count ()) return false;
			var hunk = _diff.hunk ((size_t) current_hunk);
			return row >= hunk.unified_start && row < hunk.unified_end;
		}

		/* In Unified mode, the side and line a row shows: side A's for an unchanged line. */
		public bool unified_row (size_t row, out int side, out size_t line) {
			for (int s = 0; _diff != null && s < SIDE_COUNT; s++) {
				int32 index = _diff.unified_line (row, (uint8) s);
				if (index >= 0) {
					side = s;
					line = index;
					return true;
				}
			}
			side = 0;
			line = 0;
			return false;
		}

		/* Whether a row starts a run of changed lines of the same kind, from the same side. */
		public bool unified_group_starts_at_row (size_t row) {
			ssize_t group = _diff != null ? _diff.unified_group (row) : -1;
			return group >= 0 && (row == 0 || _diff.unified_group (row - 1) != group);
		}


		/* Layout */

		/* The layout's table of the current mode's rows. */
		public uint8 mode_table () {
			return _mode == Mode.UNIFIED ? Dt.TABLE_UNIFIED : Dt.TABLE_ROWS;
		}

		/* Where the current mode's rows end. */
		public double content_bottom () {
			return _layout.bottom (mode_table ());
		}

		/* The width to wrap lines to: that of the narrowest side showing, or 0 when not wrapping. */
		double current_wrap_width () {
			if (!_wraps_lines) return 0;
			int sides = _mode == Mode.UNIFIED ? 1 : side_count;
			double width = double.MAX;
			for (int side = 0; side < sides; side++) width = double.min (width, panes[side].get_width ());
			/* At least a few characters, while the views are still being sized. */
			return double.max (width - 2 * TEXT_PADDING, 8 * char_width);
		}

		/* Lay out the lines again, keeping what's in view where it is. */
		void relayout_lines () {
			var anchor = scroll_anchor ();
			layout_lines ();
			restore_scroll_anchor (anchor);
			redraw_all ();
		}

		/* A Pango layout of text in the diff's font, wrapped to the wrap width. */
		public Pango.Layout text_layout (string text) {
			var text_layout = new Pango.Layout (get_pango_context ());
			text_layout.set_font_description (font);
			text_layout.set_tabs (tabs);
			text_layout.set_spacing ((int) ((line_height - font_line_height) * Pango.SCALE));
			if (wrap_width > 0) {
				text_layout.set_width ((int) (wrap_width * Pango.SCALE));
				text_layout.set_wrap (Pango.WrapMode.WORD_CHAR);
			}
			text_layout.set_text (text, -1);
			return text_layout;
		}

		/* How tall a side's line is: a line height, or several when it wraps. */
		double height_of_line (size_t index, int side) {
			if (wrap_width <= 0) return line_height;
			var line = _diff.line ((uint8) side, index);
			/* Most lines fit; only measure those that might not. */
			if ((line.columns + 1) * char_width <= wrap_width) return line_height;
			return int.max (text_layout (text (line.text)).get_line_count (), 1) * line_height;
		}

		/* Lay out every line for the current mode's wrap width. */
		void layout_lines () {
			stop_gliding ();
			wrap_width = current_wrap_width ();
			/* How tall each line is, for every side views can show: those the diff hasn't, none. */
			size_t[] counts = new size_t[MAX_SIDES];
			size_t total = 0;
			for (int side = 0; side < MAX_SIDES; side++) {
				counts[side] = _diff != null ? _diff.line_count ((uint8) side) : 0;
				total += counts[side];
			}
			var heights = new double[total + 1];
			void*[] pointers = new void*[MAX_SIDES];
			size_t start = 0;
			for (int side = 0; side < MAX_SIDES; side++) {
				for (size_t i = 0; i < counts[side]; i++) heights[start + i] = height_of_line (i, side);
				pointers[side] = &heights[start];
				start += counts[side];
			}
			_layout = new Dt.Layout (_diff, pointers, TOP_PADDING, line_height);
			update_scrolling ();
		}

		/* The scrollbars' ranges, as the layout and the views' sizes are. */
		void update_scrolling () {
			double bottom = double.max (view_height, content_bottom ());
			vadjustment.configure (vadjustment.value.clamp (0, double.max (bottom - view_height, 0)), 0, bottom, line_height,
				double.max (view_height - line_height, line_height), view_height);
			for (int side = 0; side < MAX_SIDES; side++) {
				double width = panes[side].get_width ();
				uint32 columns = _mode == Mode.UNIFIED ? max_columns : panes[side].max_columns;
				double content = _wraps_lines ? width : double.max (width, 2 * TEXT_PADDING + columns * char_width);
				var adjustment = hadjustments[side];
				adjustment.configure (adjustment.value.clamp (0, double.max (content - width, 0)), 0, content, char_width,
					double.max (width - char_width, char_width), width);
				hbars[side].opacity = content > width + 0.5 ? 1 : 0;
				hbars[side].can_target = content > width + 0.5;
			}
		}

		/*
		 * What to keep in place on the screen while the layout changes: the current
		 * hunk if it's in view, or else the point in the middle of the view.
		 */
		Dt.ScrollAnchor scroll_anchor () {
			return _layout.anchor (mode_table (), current_hunk, vadjustment.value, view_height);
		}

		void restore_scroll_anchor (Dt.ScrollAnchor anchor) {
			if (!anchor.valid) return;
			vadjustment.value = _layout.anchor_top (mode_table (), anchor);
		}

		/* Show the views of the sides there are: just side A's in Unified mode, which shows both. */
		void update_side_views () {
			int shown = _mode == Mode.UNIFIED ? 1 : side_count;
			for (int side = 0; side < MAX_SIDES; side++) {
				gutters[side].visible = side < shown;
				panes[side].visible = side < shown;
				hbars[side].visible = side < shown;
				if (side + 1 < MAX_SIDES) connectors[side].visible = side + 1 < shown;
			}
			queue_allocate ();
		}

		public override Gtk.SizeRequestMode get_request_mode () {
			return Gtk.SizeRequestMode.CONSTANT_SIZE;
		}

		public override void measure (Gtk.Orientation orientation, int for_size, out int minimum, out int natural,
				out int minimum_baseline, out int natural_baseline) {
			minimum = 100;
			natural = 400;
			minimum_baseline = -1;
			natural_baseline = -1;
		}

		static void place (Gtk.Widget widget, double x, double y, double width, double height) {
			var transform = new Gsk.Transform ().translate (Graphene.Point () { x = (float) x, y = (float) y });
			widget.allocate ((int) double.max (width, 0), (int) double.max (height, 0), -1, transform);
		}

		/* Each side gets an equal share of the width, after the connectors between them. */
		public override void size_allocate (int width, int height, int baseline) {
			int minimum, natural, ignored_minimum, ignored_natural;
			vbar.measure (Gtk.Orientation.HORIZONTAL, -1, out minimum, out natural, out ignored_minimum, out ignored_natural);
			double vbar_width = natural;
			hbars[0].measure (Gtk.Orientation.VERTICAL, -1, out minimum, out natural, out ignored_minimum, out ignored_natural);
			/* The horizontal scrollbars lie over the bottom of their panes, shown only when there's sideways to scroll. */
			double hbar_height = natural;
			double text_height = height;
			double sides_width = double.max (width - vbar_width, 0);
			place (vbar, sides_width, 0, vbar_width, text_height);

			if (_mode == Mode.UNIFIED) {
				/* Side A's views show both sides; the others are hidden. */
				double gutter = double.min (2 * unified_column_width, sides_width);
				place (gutters[0], 0, 0, gutter, text_height);
				place (panes[0], gutter, 0, sides_width - gutter, text_height);
				place (hbars[0], gutter, text_height - hbar_height, sides_width - gutter, hbar_height);
			} else {
				double share = Math.floor ((sides_width - (side_count - 1) * MIDDLE_WIDTH) / side_count);
				double x = 0;
				for (int side = 0; side < side_count; side++) {
					double side_width = side + 1 == side_count ? sides_width - x : share;
					double gutter = double.min (gutter_width, side_width);
					place (gutters[side], x, 0, gutter, text_height);
					place (panes[side], x + gutter, 0, side_width - gutter, text_height);
					place (hbars[side], x + gutter, text_height - hbar_height, side_width - gutter, hbar_height);
					x += side_width;
					if (side + 1 < side_count) {
						place (connectors[side], x, 0, MIDDLE_WIDTH, height);
						x += MIDDLE_WIDTH;
					}
				}
			}

			view_height = text_height;
			/* Wrapped lines wrap again at another width. */
			if (_wraps_lines && Math.fabs (current_wrap_width () - wrap_width) >= 0.5) {
				relayout_lines ();
			} else {
				update_scrolling ();
			}
		}

		public void redraw_all () {
			for (int side = 0; side < MAX_SIDES; side++) {
				panes[side].queue_draw ();
				gutters[side].queue_draw ();
				if (side + 1 < MAX_SIDES) connectors[side].queue_draw ();
			}
		}

		/* The bottom corner below the vertical scrollbar, in the panes' background. */
		public override void snapshot (Gtk.Snapshot snapshot) {
			var colors = Colors.for_widget (this);
			snapshot.append_color (colors.background, Graphene.Rect () { origin = { 0, 0 }, size = { get_width (), get_height () } });
			base.snapshot (snapshot);
		}


		/* Scrolling */

		/* How far the shared layout's scrolled down. */
		public double vertical_offset () {
			return vadjustment.value;
		}

		/* How far a side's scrolled sideways. */
		public double horizontal_offset (int side) {
			return hadjustments[side].value;
		}

		/*
		 * In Fluid mode, how far down a side's own layout is from the shared one,
		 * so that a line at y in it shows at y - shift - vertical_offset(); 0 otherwise.
		 */
		public double shift (int side) {
			if (_mode != Mode.FLUID || _diff == null) return 0;
			double y = vadjustment.value;
			return _layout.fluid_top ((uint8) side, y, view_height) - y;
		}

		void vertical_scroll_changed () {
			/* Scrolled some other way than by the wheel, as by the scrollbar: the sides line up with the shared layout again. */
			if (_mode == Mode.FLUID && !wheeling) {
				_layout.fluid_scrolled (vadjustment.value, view_height);
				if (_layout.fluid_gliding ()) start_ticking ();
			}
			redraw_all ();
		}

		/* Scroll for the wheel or touchpad over a side's pane or gutter. */
		void add_scrolling (Gtk.Widget widget, int side) {
			var scroll = new Gtk.EventControllerScroll (Gtk.EventControllerScrollFlags.BOTH_AXES | Gtk.EventControllerScrollFlags.KINETIC);
			scroll.scroll_begin.connect (() => {
				in_gesture = true;
				momentum_speed = 0;
			});
			scroll.scroll_end.connect (() => {
				in_gesture = false;
				release_scrolling ();
			});
			scroll.scroll.connect ((dx, dy) => {
				double step = scroll.get_unit () == Gdk.ScrollUnit.WHEEL ? Math.pow (double.max (view_height, 1), 2.0 / 3.0) : 1;
				uint8 phase = in_gesture ? Dt.SCROLL_GESTURE : Dt.SCROLL_WHEEL;
				scroll_side (side, dx * step, dy * step, phase);
				return true;
			});
			scroll.decelerate.connect ((velocity_x, velocity_y) => {
				if (_mode != Mode.FLUID || Math.fabs (velocity_y) < MIN_MOMENTUM_SPEED) return;
				momentum_side = side;
				momentum_speed = velocity_y;
				start_ticking ();
			});
			widget.add_controller (scroll);
		}

		/* Where the pointer was over a side's pane, for Fluid mode's scrolling to line up the sides at. */
		double pointer_y (int side) {
			return panes[side].pointer_y;
		}

		/*
		 * Scroll for the wheel over a side, by dx and dy down. In Fluid mode, the
		 * side's own layout moves with the wheel, and the other sides keep up with
		 * it; otherwise every side scrolls the same.
		 */
		void scroll_side (int side, double dx, double dy, uint8 phase) {
			if (Math.fabs (dx) >= 0.01) {
				var adjustment = hadjustments[_mode == Mode.UNIFIED ? 0 : side];
				adjustment.value = (adjustment.value + dx).clamp (0, double.max (adjustment.upper - adjustment.page_size, 0));
			}
			if (Math.fabs (dy) < 0.01) return;
			if (_mode != Mode.FLUID || _diff == null || side >= side_count) {
				double range = double.max (vadjustment.upper - vadjustment.page_size, 0);
				vadjustment.value = (vadjustment.value + dy).clamp (0, range);
				return;
			}
			double y = _layout.fluid_scroll ((uint8) side, dy, phase, pointer_y (side), vadjustment.value, view_height);
			wheeling = true;
			vadjustment.value = y;
			wheeling = false;
			if (_layout.fluid_gliding ()) start_ticking ();
			redraw_all ();
		}

		/* The touchpad let go, or momentum ran out: a side stretched past its start or end springs back. */
		void release_scrolling () {
			if (_mode != Mode.FLUID) return;
			_layout.fluid_release ();
			if (_layout.fluid_gliding ()) start_ticking ();
		}

		/* Stop the sides gliding, as when they're laid out anew, lined up. */
		void stop_gliding () {
			momentum_speed = 0;
		}

		/* Bring the current hunk into view: smoothly within a view, or else at once, with the sides lined up at once. */
		public void scroll_to_current_hunk () {
			if (current_hunk < 0) return;
			double y;
			if (!_layout.scroll_to_hunk (mode_table (), (size_t) current_hunk, vadjustment.value, view_height, out y)) return;
			y = y.clamp (0, double.max (vadjustment.upper - vadjustment.page_size, 0));
			if (Math.fabs (y - vadjustment.value) > view_height) {
				_layout.fluid_line_up ();
				scroll_start = -1;
				vadjustment.value = y;
				redraw_all ();
				return;
			}
			scroll_from = vadjustment.value;
			scroll_to = y;
			scroll_start = 0;
			start_ticking ();
		}

		/* Light up the current hunk for a moment, as when there's no hunk further on to move to. */
		public void flash_current_hunk () {
			flash = 1;
			flash_start = 0;
			start_ticking ();
			redraw_all ();
		}

		/* Run the animations, a frame at a time, until they're done: gliding, momentum, scrolling to a hunk, flashing. */
		void start_ticking () {
			if (tick_id != 0) return;
			last_frame = 0;
			tick_id = add_tick_callback ((widget, clock) => {
				int64 now = clock.get_frame_time ();
				double elapsed = last_frame > 0 ? (now - last_frame) / 1e6 : 1.0 / 60;
				last_frame = now;
				bool running = false;

				if (momentum_speed != 0) {
					scroll_side (momentum_side, 0, momentum_speed * elapsed, Dt.SCROLL_MOMENTUM);
					momentum_speed *= Math.exp (-elapsed / MOMENTUM_TIME);
					if (Math.fabs (momentum_speed) < MIN_MOMENTUM_SPEED) {
						momentum_speed = 0;
						release_scrolling ();
					}
					running = true;
				}
				if (_mode == Mode.FLUID && _layout.fluid_gliding ()) {
					running = _layout.fluid_glide (elapsed) || running;
					redraw_all ();
				}
				if (scroll_start >= 0) {
					if (scroll_start == 0) scroll_start = now;
					double t = double.min ((now - scroll_start) / 1e6 / SCROLL_TO_HUNK_DURATION, 1);
					/* Easing in and out. */
					double eased = t * t * (3 - 2 * t);
					vadjustment.value = scroll_from + (scroll_to - scroll_from) * eased;
					if (t >= 1) scroll_start = -1;
					running = true;
				}
				if (flash > 0) {
					if (flash_start == 0) flash_start = now;
					/* Fading out fast, then slowly. */
					double t = (now - flash_start) / 1e6 / FLASH_DURATION;
					flash = t < 1 ? (1 - t) * (1 - t) : 0;
					redraw_all ();
					running = running || flash > 0;
				}
				if (!running) tick_id = 0;
				return running ? Source.CONTINUE : Source.REMOVE;
			});
		}


		/* Drawing shared by the parts */

		/* Outline the hunks of the rows in a width, drawn offset up, with bands filling them if bands is set. */
		public void draw_hunks (Gtk.Snapshot snapshot, double width, double height, double offset, bool bands) {
			if (_diff == null) return;
			var colors = Colors.for_widget (this);
			size_t count = _diff.hunk_count ();
			for (size_t i = 0; i < count; i++) {
				var hunk = _diff.hunk (i);
				double top = _layout.y (Dt.TABLE_ROWS, hunk.row_start) - offset;
				double bottom = _layout.y (Dt.TABLE_ROWS, hunk.row_end) - offset;
				if (bottom < -1 || top > height + 1) continue;
				if (bands) fill (snapshot, colors.line_color (hunk.kind, (ssize_t) i == current_hunk), 0, top, width, bottom - top);
				/* Where the hunk before ends, its bottom edge is this one's top. */
				if (i == 0 || _diff.hunk (i - 1).row_end != hunk.row_start) fill (snapshot, colors.edge[hunk.kind], 0, top, width, 1);
				fill (snapshot, colors.edge[hunk.kind], 0, bottom - 1, width, 1);
			}
		}

		/* In Fluid mode, outline a side's hunks in a width, its own layout drawn offset up. */
		public void draw_side_hunks (Gtk.Snapshot snapshot, int side, double width, double height, double offset) {
			if (side_is_empty (side)) return;
			var colors = Colors.for_widget (this);
			size_t count = _diff.hunk_count ();
			for (size_t i = 0; i < count; i++) {
				var hunk = _diff.hunk (i);
				uint32 start, end;
				hunk_lines (hunk, side, out start, out end);
				double top = _layout.y ((uint8) side, start) - offset;
				double bottom = _layout.y ((uint8) side, end) - offset;
				if (bottom < -1 || top > height + 1) continue;
				/*
				 * A hunk with no lines on this side is a single line where they'd be.
				 * Where the hunk before ends, its bottom edge is this one's top.
				 */
				uint32 previous_start = 0, previous_end = uint32.MAX;
				if (i > 0) hunk_lines (_diff.hunk (i - 1), side, out previous_start, out previous_end);
				if (previous_end != start) fill (snapshot, colors.edge[hunk.kind], 0, top, width, 1);
				if (bottom - top >= 2) fill (snapshot, colors.edge[hunk.kind], 0, bottom - 1, width, 1);
			}
		}

		/* In Unified mode, outline the runs of changed lines in the rows from first up to last, drawn offset up. */
		public void draw_unified_groups (Gtk.Snapshot snapshot, size_t first, size_t last, double width, double offset) {
			var colors = Colors.for_widget (this);
			for (size_t row = first; row < last; row++) {
				ssize_t group = _diff.unified_group (row);
				if (group < 0) continue;
				var color = colors.edge[group % 8];
				/* Where a run before ends, its bottom edge is this one's top. */
				bool touching = row > 0 && _diff.unified_group (row - 1) >= 0;
				if (unified_group_starts_at_row (row) && !touching) fill (snapshot, color, 0, _layout.y (Dt.TABLE_UNIFIED, row) - offset, width, 1);
				if (_diff.unified_group (row + 1) != group) {
					fill (snapshot, color, 0, _layout.y (Dt.TABLE_UNIFIED, row + 1) - offset - 1, width, 1);
				}
			}
		}

		/* While the current hunk is flashing, light up its part of a side in a width, drawn offset up. */
		public void draw_flash (Gtk.Snapshot snapshot, int side, double width, double offset) {
			if (flash <= 0 || _diff == null || current_hunk < 0 || current_hunk >= (ssize_t) _diff.hunk_count ()) return;
			if (_mode != Mode.UNIFIED && side_is_empty (side)) return;
			var hunk = _diff.hunk ((size_t) current_hunk);
			double top, bottom;
			if (_mode == Mode.UNIFIED) {
				top = _layout.y (Dt.TABLE_UNIFIED, hunk.unified_start);
				bottom = _layout.y (Dt.TABLE_UNIFIED, hunk.unified_end);
			} else if (_mode == Mode.FLUID) {
				uint32 start, end;
				hunk_lines (hunk, side, out start, out end);
				top = _layout.y ((uint8) side, start);
				bottom = _layout.y ((uint8) side, end);
			} else {
				top = _layout.y (Dt.TABLE_ROWS, hunk.row_start);
				bottom = _layout.y (Dt.TABLE_ROWS, hunk.row_end);
			}
			/* A hunk with no lines on this side lights up the line where they'd be. */
			if (bottom - top < 2) {
				top -= 1;
				bottom = top + 2;
			}
			var color = Colors.for_widget (this).accent;
			color.alpha = (float) (0.35 * flash);
			fill (snapshot, color, 0, top - offset, width, bottom - top);
		}

		public static void fill (Gtk.Snapshot snapshot, Gdk.RGBA color, double x, double y, double width, double height) {
			if (width <= 0 || height <= 0) return;
			snapshot.append_color (color, Graphene.Rect () { origin = { (float) x, (float) y }, size = { (float) width, (float) height } });
		}

	}
}
