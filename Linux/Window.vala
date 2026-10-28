namespace Diffotron {
	/* A sidebar row: a file of the comparison, or the heading of the directory the files after it are in. */
	class SidebarRow : Gtk.ListBoxRow {
		public ssize_t entry { get; private set; }
		public string path { get; private set; }

		public SidebarRow.heading (string title) {
			entry = -1;
			path = "";
			activatable = false;
			selectable = false;
			var label = new Gtk.Label (title) { xalign = 0, ellipsize = Pango.EllipsizeMode.START, margin_top = 6 };
			label.add_css_class ("heading");
			label.add_css_class ("dim-label");
			child = label;
		}

		public SidebarRow.file (string title, size_t entry, string path, uint8 status) {
			this.entry = (ssize_t) entry;
			this.path = path;
			var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
			var mark = new Gtk.Label (null) { width_chars = 2 };
			mark.set_markup (status_mark (status));
			box.append (mark);
			box.append (new Gtk.Label (title) { xalign = 0, ellipsize = Pango.EllipsizeMode.MIDDLE, hexpand = true });
			box.tooltip_text = "%s: %s".printf (status_name (status), path);
			child = box;
		}

		static string status_mark (uint8 status) {
			switch (status) {
				case Dt.STATUS_MODIFIED: return "<span foreground=\"#9A5AE0\">△</span>";
				case Dt.STATUS_ADDED: return "<span foreground=\"#3FA34D\" weight=\"bold\">+</span>";
				case Dt.STATUS_REMOVED: return "<span foreground=\"#D9534F\" weight=\"bold\">−</span>";
				default: return "<span alpha=\"50%\">=</span>";
			}
		}

		static string status_name (uint8 status) {
			switch (status) {
				case Dt.STATUS_MODIFIED: return "Modified";
				case Dt.STATUS_ADDED: return "Added";
				case Dt.STATUS_REMOVED: return "Removed";
				default: return "Unchanged";
			}
		}
	}

	/* A comparison's window: its changed files in a sidebar, and the diff of the selected one beside it; for a merge, with the merged result below. */
	public class Window : Gtk.ApplicationWindow {
		public Document document { get; private set; }
		/* Whether the merge was last saved with no conflict markers left, for the process's exit status. */
		public bool merge_resolved { get; private set; default = false; }

		Gtk.Paned split;
		Gtk.ListBox list;
		Gtk.Label sidebar_title;
		Gtk.Spinner spinner;
		Gtk.Label[] pane_titles = new Gtk.Label[MAX_SIDES];
		DiffView diff_view;
		Gtk.Label message;
		Gtk.Label change_label;
		Gtk.Label conflict_label;
		Gtk.Button previous_button;
		Gtk.Button next_button;
		Gtk.CheckButton whitespace_check;
		Gtk.ToggleButton[] mode_buttons = new Gtk.ToggleButton[3];
		/* The diff above, and for a merge, the merged result below. */
		Gtk.Paned merge_split;
		Gtk.Box merge_pane;
		Gtk.Label merge_title;
		Gtk.TextView merge_text;
		MergeEditor merge_editor;
		bool shows_merge = false;
		/* The comparison generation whose merge the merged result was loaded from. */
		uint merge_generation = uint.MAX;
		/* Set while changing the merged result's selection, so as not to take that as choosing a change. */
		bool selecting_merge = false;
		/* The merged result's font, for its text view's class. */
		Gtk.CssProvider? merge_style = null;
		string merge_class = "merge-text-%u".printf (Random.next_int ());

		uint shown_generation = uint.MAX;
		ssize_t shown_entry = -1;
		string? shown_path = null;
		/* Shown instead of the diff, such as for binary files. */
		string? file_message = null;
		bool ignore_whitespace = false;
		bool closing = false;

		public Window (Application application) {
			Object (application: application);
			var settings = Settings.get_default ();
			set_default_size (settings.window_width, settings.window_height);
			if (settings.window_maximized) maximize ();
			document = new Document ();
			document.changed.connect (document_changed);
			build_views ();
			add_actions ();
			close_request.connect (close_requested);
			document_changed ();
		}

		/* Views */

		void build_views () {
			var header = new Gtk.HeaderBar ();
			var menu_button = new Gtk.MenuButton () { icon_name = "open-menu-symbolic", menu_model = main_menu (), primary = true };
			menu_button.tooltip_text = "Main Menu";
			header.pack_end (menu_button);
			var open_button = new Gtk.Button.from_icon_name ("document-open-symbolic") { tooltip_text = "Open Files…", action_name = "app.open" };
			header.pack_start (open_button);
			var sidebar_button = new Gtk.ToggleButton () { icon_name = "sidebar-show-symbolic", tooltip_text = "Toggle Sidebar", active = true };
			sidebar_button.bind_property ("active", this, "sidebar-visible", BindingFlags.BIDIRECTIONAL);
			header.pack_start (sidebar_button);
			set_titlebar (header);

			split = new Gtk.Paned (Gtk.Orientation.HORIZONTAL) {
				start_child = build_sidebar (),
				end_child = build_detail (),
				resize_start_child = false,
				shrink_start_child = false,
				shrink_end_child = false,
				position = 260
			};
			child = split;
		}

		public bool sidebar_visible {
			get { return split == null || split.start_child.visible; }
			set { if (split != null) split.start_child.visible = value; }
		}

		Gtk.Widget build_sidebar () {
			sidebar_title = new Gtk.Label ("") { xalign = 0, ellipsize = Pango.EllipsizeMode.END, hexpand = true };
			sidebar_title.add_css_class ("heading");
			spinner = new Gtk.Spinner ();
			var top = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) { margin_start = 12, margin_end = 12, margin_top = 8, margin_bottom = 8 };
			top.append (sidebar_title);
			top.append (spinner);

			list = new Gtk.ListBox () { selection_mode = Gtk.SelectionMode.BROWSE };
			list.add_css_class ("navigation-sidebar");
			list.row_selected.connect (() => show_selected_entry (false, false));
			var scroll = new Gtk.ScrolledWindow () { child = list, vexpand = true, hscrollbar_policy = Gtk.PolicyType.NEVER };

			var sidebar = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) { width_request = 180 };
			sidebar.append (top);
			sidebar.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
			sidebar.append (scroll);
			return sidebar;
		}

		Gtk.Widget build_detail () {
			/* Each title over its side, as DiffView lays them out: equal shares, with the connectors' width between. */
			var titles = new Gtk.Box (Gtk.Orientation.HORIZONTAL, (int) MIDDLE_WIDTH) {
				homogeneous = true, margin_start = 12, margin_end = 24, margin_top = 8, margin_bottom = 8
			};
			for (int side = 0; side < MAX_SIDES; side++) {
				pane_titles[side] = new Gtk.Label ("") { xalign = 0, ellipsize = Pango.EllipsizeMode.MIDDLE, hexpand = true };
				titles.append (pane_titles[side]);
			}

			var settings = Settings.get_default ();
			diff_view = new DiffView () { vexpand = true, hexpand = true };
			diff_view.font_family = settings.font_family;
			diff_view.font_size = settings.font_size;
			diff_view.wraps_lines = settings.wraps_lines;
			diff_view.mode = settings.mode;
			diff_view.current_hunk_changed.connect (current_hunk_changed);

			merge_split = new Gtk.Paned (Gtk.Orientation.VERTICAL) {
				start_child = diff_view, end_child = build_merge_pane (), shrink_start_child = false, shrink_end_child = false
			};

			message = new Gtk.Label ("") {
				wrap = true, justify = Gtk.Justification.CENTER, max_width_chars = 50, halign = Gtk.Align.CENTER,
				valign = Gtk.Align.CENTER, can_target = false
			};
			message.add_css_class ("title-4");
			message.add_css_class ("dim-label");
			var overlay = new Gtk.Overlay () { child = merge_split };
			overlay.add_overlay (message);

			var bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) { margin_start = 12, margin_end = 12, margin_top = 4, margin_bottom = 4 };
			var modes = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
			modes.add_css_class ("linked");
			string[] mode_names = { "Blocks", "Fluid", "Unified" };
			string[] mode_targets = { "blocks", "fluid", "unified" };
			for (int mode = 0; mode < 3; mode++) {
				mode_buttons[mode] = new Gtk.ToggleButton.with_label (mode_names[mode]) {
					action_name = "win.mode", action_target = new Variant.string (mode_targets[mode])
				};
				modes.append (mode_buttons[mode]);
			}
			bar.append (modes);
			bar.append (new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) { hexpand = true });
			whitespace_check = new Gtk.CheckButton.with_label ("Ignore whitespace") { action_name = "win.ignore-whitespace" };
			bar.append (whitespace_check);
			conflict_label = new Gtk.Label ("") { visible = false };
			bar.append (conflict_label);
			change_label = new Gtk.Label ("");
			change_label.add_css_class ("dim-label");
			bar.append (change_label);
			previous_button = new Gtk.Button.from_icon_name ("go-up-symbolic") { tooltip_text = "Previous Change", action_name = "win.previous-change" };
			next_button = new Gtk.Button.from_icon_name ("go-down-symbolic") { tooltip_text = "Next Change", action_name = "win.next-change" };
			bar.append (previous_button);
			bar.append (next_button);

			var detail = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
			detail.append (titles);
			detail.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
			detail.append (overlay);
			detail.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
			detail.append (bar);

			var drop = new Gtk.DropTarget (typeof (Gdk.FileList), Gdk.DragAction.COPY);
			drop.drop.connect ((value, x, y) => {
				var files = ((Gdk.FileList) value.get_boxed ()).get_files ();
				File[] dropped = {};
				foreach (var file in files) dropped += file;
				int side = x < detail.get_width () / 2 ? 0 : 1;
				return drop_files (dropped, dropped.length == 1 ? side : -1);
			});
			detail.add_controller (drop);
			return detail;
		}

		/* The merged result: a title, and the text to edit. Hidden but for a merge. */
		Gtk.Widget build_merge_pane () {
			merge_title = new Gtk.Label ("") { xalign = 0, ellipsize = Pango.EllipsizeMode.MIDDLE, margin_start = 12, margin_end = 12, margin_top = 6, margin_bottom = 6 };
			merge_text = new Gtk.TextView () { monospace = true, left_margin = 4, right_margin = 4, top_margin = 4, bottom_margin = 4 };
			merge_text.buffer.enable_undo = true;
			merge_text.buffer.notify["cursor-position"].connect (merge_cursor_moved);
			merge_text.buffer.modified_changed.connect (update_title);
			merge_editor = new MergeEditor (merge_text);
			merge_editor.notify["conflict-count"].connect (update_conflict_label);
			update_merge_font ();
			update_merge_wrapping ();

			merge_pane = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) { visible = false, height_request = 100 };
			merge_pane.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
			merge_pane.append (merge_title);
			merge_pane.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
			merge_pane.append (new Gtk.ScrolledWindow () { child = merge_text, vexpand = true });
			return merge_pane;
		}

		MenuModel main_menu () {
			var menu = new Menu ();
			var file = new Menu ();
			file.append ("New Window", "app.new-window");
			file.append ("Open Files…", "app.open");
			file.append ("Open Folders…", "app.open-folders");
			file.append ("Save", "win.save");
			menu.append_section (null, file);
			var view = new Menu ();
			view.append ("Blocks", "win.mode::blocks");
			view.append ("Fluid", "win.mode::fluid");
			view.append ("Unified", "win.mode::unified");
			menu.append_section (null, view);
			var options = new Menu ();
			options.append ("Wrap Lines", "win.wrap-lines");
			options.append ("Ignore Whitespace", "win.ignore-whitespace");
			options.append ("Increase Text Size", "win.larger-text");
			options.append ("Decrease Text Size", "win.smaller-text");
			options.append ("Font…", "app.font");
			menu.append_section (null, options);
			var navigate = new Menu ();
			navigate.append ("Previous Change", "win.previous-change");
			navigate.append ("Next Change", "win.next-change");
			navigate.append ("Previous File", "win.previous-file");
			navigate.append ("Next File", "win.next-file");
			menu.append_section (null, navigate);
			var merge = new Menu ();
			merge.append ("Previous Conflict", "win.previous-conflict");
			merge.append ("Next Conflict", "win.next-conflict");
			merge.append ("Take A", "win.take-a");
			merge.append ("Take B", "win.take-b");
			merge.append ("Take A then B", "win.take-a-then-b");
			merge.append ("Take B then A", "win.take-b-then-a");
			merge.append ("Reset Change", "win.reset-change");
			menu.append_submenu ("Merge", merge);
			var app = new Menu ();
			app.append ("About Diff-o-tron", "app.about");
			menu.append_section (null, app);
			return menu;
		}


		/* Actions */

		void add_action_named (string name, owned SimpleActionActivateCallback activate) {
			var action = new SimpleAction (name, null);
			action.activate.connect ((a, p) => activate (a, p));
			add_action (action);
		}

		public delegate void SimpleActionActivateCallback (SimpleAction action, Variant? parameter);

		void add_actions () {
			var settings = Settings.get_default ();
			var mode = new SimpleAction.stateful ("mode", VariantType.STRING, new Variant.string (mode_name (diff_view.mode)));
			mode.change_state.connect ((action, value) => {
				var chosen = mode_of (value.get_string ());
				if (shows_merge && chosen == Mode.UNIFIED) return;
				action.set_state (value);
				diff_view.mode = chosen;
				settings.mode = chosen;
				update_change_label ();
			});
			add_action (mode);

			var wrap = new SimpleAction.stateful ("wrap-lines", null, new Variant.boolean (diff_view.wraps_lines));
			wrap.activate.connect (() => {
				bool wraps = !wrap.get_state ().get_boolean ();
				wrap.set_state (new Variant.boolean (wraps));
				diff_view.wraps_lines = wraps;
				settings.wraps_lines = wraps;
				update_merge_wrapping ();
			});
			add_action (wrap);

			var whitespace = new SimpleAction.stateful ("ignore-whitespace", null, new Variant.boolean (false));
			whitespace.activate.connect (() => {
				ignore_whitespace = !ignore_whitespace;
				whitespace.set_state (new Variant.boolean (ignore_whitespace));
				show_selected_entry (true, false);
			});
			add_action (whitespace);

			add_action_named ("larger-text", () => set_text_size (diff_view.font_size + 1));
			add_action_named ("smaller-text", () => set_text_size (diff_view.font_size - 1));
			add_action_named ("previous-change", () => move_change (-1));
			add_action_named ("next-change", () => move_change (1));
			add_action_named ("previous-file", () => select_file_step (-1));
			add_action_named ("next-file", () => select_file_step (1));
			add_action_named ("previous-conflict", () => move_conflict (-1));
			add_action_named ("next-conflict", () => move_conflict (1));
			add_action_named ("take-a", () => take_versions ({ Dt.VERSION_A }));
			add_action_named ("take-b", () => take_versions ({ Dt.VERSION_B }));
			add_action_named ("take-a-then-b", () => take_versions ({ Dt.VERSION_A, Dt.VERSION_B }));
			add_action_named ("take-b-then-a", () => take_versions ({ Dt.VERSION_B, Dt.VERSION_A }));
			/* Back to how the merge first had it: a side's change, or the conflict between them. */
			add_action_named ("reset-change", () => take_versions ({ Dt.VERSION_MERGED }));
			add_action_named ("save", () => save_merge.begin ());
			update_actions ();
		}

		static string mode_name (Mode mode) {
			return mode == Mode.BLOCKS ? "blocks" : mode == Mode.UNIFIED ? "unified" : "fluid";
		}

		static Mode mode_of (string name) {
			return name == "blocks" ? Mode.BLOCKS : name == "unified" ? Mode.UNIFIED : Mode.FLUID;
		}

		void set_enabled (string name, bool enabled) {
			var action = lookup_action (name) as SimpleAction;
			if (action != null) action.set_enabled (enabled);
		}

		/* Enable the actions that work for what the window shows. */
		void update_actions () {
			bool has_diff = diff_view.diff != null;
			bool can_take = shows_merge && merge_editor.has_result && diff_view.current_hunk >= 0;
			/* Enabled with no change to move to, to show there's none. */
			set_enabled ("previous-change", has_diff);
			set_enabled ("next-change", has_diff);
			set_enabled ("previous-file", file_row_from (selected_index (), -1) >= 0);
			set_enabled ("next-file", file_row_from (selected_index (), 1) >= 0);
			set_enabled ("ignore-whitespace", !shows_merge);
			set_enabled ("save", shows_merge && merge_editor.has_result);
			set_enabled ("previous-conflict", shows_merge && merge_editor.has_result);
			set_enabled ("next-conflict", shows_merge && merge_editor.has_result);
			foreach (var name in new string[] { "take-a", "take-b", "take-a-then-b", "take-b-then-a", "reset-change" }) {
				set_enabled (name, can_take);
			}
			set_enabled ("larger-text", diff_view.font_size < MAX_FONT_SIZE);
			set_enabled ("smaller-text", diff_view.font_size > MIN_FONT_SIZE);
			mode_buttons[Mode.UNIFIED].sensitive = !shows_merge;
		}

		void set_text_size (double size) {
			if (size < MIN_FONT_SIZE || size > MAX_FONT_SIZE) return;
			diff_view.font_size = size;
			Settings.get_default ().font_size = size;
			update_merge_font ();
			update_actions ();
		}

		/* View › Font chose another font, for every window. */
		public void font_family_changed () {
			diff_view.font_family = Settings.get_default ().font_family;
			update_merge_font ();
		}

		/* The merged result in the diff's font, by a style for its text view's class, which is the window's own. */
		void update_merge_font () {
			if (merge_style == null) {
				merge_style = new Gtk.CssProvider ();
				Gtk.StyleContext.add_provider_for_display (get_display (), merge_style, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
				merge_text.add_css_class (merge_class);
			}
			string family = diff_view.font_family != "" ? diff_view.font_family : "monospace";
			merge_style.load_from_string ("textview.%s { font-family: \"%s\"; font-size: %gpt; }".printf (merge_class, family, diff_view.font_size));
		}

		/* The merged result wraps its lines as the diff does. */
		void update_merge_wrapping () {
			merge_text.wrap_mode = diff_view.wraps_lines ? Gtk.WrapMode.WORD_CHAR : Gtk.WrapMode.NONE;
		}


		/* Document state */

		void update_title () {
			string name = document.display_name ();
			title = shows_merge && merge_text.buffer.get_modified () ? "• " + name : name;
		}

		void document_changed () {
			update_title ();
			show_merge (document.is_merge);
			if (document.generation != shown_generation) {
				shown_generation = document.generation;
				reload_items (document.reloaded);
			}
			update_sidebar_title ();
			update_pane_titles ();
			update_message ();
			update_actions ();
		}

		/* Show the merged result under the diff, or not, and the controls that only work for comparisons. */
		void show_merge (bool show) {
			if (show == shows_merge) return;
			shows_merge = show;
			merge_pane.visible = show;
			if (show) {
				Idle.add (() => {
					merge_split.position = (int) (merge_split.get_height () * 0.55);
					return Source.REMOVE;
				});
				/* A merge has no unified view, and doesn't ignore whitespace, which would load it over. */
				if (diff_view.mode == Mode.UNIFIED) {
					diff_view.mode = Mode.FLUID;
					((SimpleAction) lookup_action ("mode")).set_state (new Variant.string ("fluid"));
				}
			}
			update_actions ();
		}

		/*
		 * List the comparison's files and show the first. When it's reloaded, keep
		 * showing the same file, if it's still there, where it was.
		 */
		void reload_items (bool keep) {
			string? kept_path = keep ? shown_path : null;
			list.remove_all ();
			unowned Dt.Comparison? comparison = document.comparison;
			size_t count = comparison != null ? comparison.item_count () : 0;
			for (size_t i = 0; i < count; i++) {
				var item = comparison.item (i);
				if (item.entry < 0) {
					list.append (new SidebarRow.heading (text (item.title)));
					continue;
				}
				var entry = comparison.entry ((size_t) item.entry);
				string title = text (item.title);
				/* Comparing two files: name them by their labels, when they have them. */
				if (comparison.count () == 1 && (document.label (0) != null || document.label (1) != null)) {
					string a = document.name (0), b = document.name (1);
					title = a == b ? a : "%s → %s".printf (a, b);
				}
				list.append (new SidebarRow.file (title, (size_t) item.entry, text (entry.path), entry.status));
			}

			int row = -1;
			for (int i = 0; kept_path != null && list.get_row_at_index (i) != null; i++) {
				var sidebar_row = (SidebarRow) list.get_row_at_index (i);
				if (sidebar_row.entry >= 0 && sidebar_row.path == kept_path) row = i;
			}
			bool same = row >= 0;
			if (!same) row = file_row_from (-1, 1);
			if (row >= 0) {
				list.select_row (list.get_row_at_index (row));
			}
			show_selected_entry (true, same);
		}

		void update_sidebar_title () {
			if (document.comparing) {
				sidebar_title.label = "Comparing…";
				spinner.start ();
				return;
			}
			spinner.stop ();
			if (document.comparison == null) {
				sidebar_title.label = "";
				return;
			}
			if (document.is_merge) {
				sidebar_title.label = "Merge";
				return;
			}
			int changed = 0;
			for (int i = 0; list.get_row_at_index (i) != null; i++) {
				if (((SidebarRow) list.get_row_at_index (i)).entry >= 0) changed++;
			}
			sidebar_title.label = changed == 1 ? "1 changed file" : "%d changed files".printf (changed);
		}

		/* A pane's title: its letter, and the name of its file. */
		static string pane_title (string letter, string name) {
			return "<b><span alpha=\"60%\">%s</span></b>   %s".printf (Markup.escape_text (letter), Markup.escape_text (name));
		}

		void update_pane_titles () {
			if (document.is_merge) {
				update_merge_titles ();
				return;
			}
			string[] letters = { "A", "B" };
			unowned Dt.Comparison? comparison = document.comparison;
			for (int side = 0; side < MAX_SIDES; side++) {
				pane_titles[side].visible = side < SIDE_COUNT;
				if (side >= SIDE_COUNT) continue;
				string name = "";
				string? path = null;
				if (comparison != null && shown_entry >= 0) {
					var entry = comparison.entry ((size_t) shown_entry);
					path = text (comparison.entry_path ((size_t) shown_entry, (uint8) side));
					string dir = text (entry.dir);
					string? label = document.label (side);
					if (path == "") {
						name = "Not present";
					} else if (label != null && comparison.count () == 1 && dir == "") {
						name = label;
					} else if (dir != "") {
						name = "%s › %s".printf (dir.replace ("/", " › "), Path.get_basename (path));
					} else {
						name = Path.get_basename (path);
					}
				} else if (document.file (side) != null) {
					name = document.name (side);
					path = document.file (side).get_path ();
				}
				pane_titles[side].set_markup (pane_title (letters[side], name));
				pane_titles[side].tooltip_text = path != null && path != "" ? path : null;
			}
		}

		/* A merge's sides are its base, A and B, and the merged result's saved to the output. */
		void update_merge_titles () {
			string[] letters = { "Base", "A", "B" };
			File?[] files = { document.base_file, document.file (0), document.file (1) };
			for (int side = 0; side < MAX_SIDES; side++) {
				string? label = side == 0 ? (document.base_label != "" ? document.base_label : null) : document.label (side - 1);
				string name = label ?? (files[side] != null ? files[side].get_basename () : "");
				pane_titles[side].visible = true;
				pane_titles[side].set_markup (pane_title (letters[side], name));
				pane_titles[side].tooltip_text = files[side] != null ? files[side].get_path () : null;
			}
			string output = document.output != null ? document.output.get_basename () : "";
			merge_title.set_markup (pane_title ("Merged", output));
			merge_title.tooltip_text = document.output != null ? document.output.get_path () : null;
		}

		void update_message () {
			string? text_shown = null;
			File? a = document.file (0), b = document.file (1);
			unowned Dt.Comparison? comparison = document.comparison;
			if (a == null && b == null) {
				text_shown = "Drop two files or folders here to compare them, or choose Open Files…";
			} else if (a == null || b == null) {
				text_shown = "Drop a file or folder on the %s to compare it with “%s”.".printf (a != null ? "right" : "left", (a ?? b).get_basename ());
			} else if (document.comparing) {
				text_shown = null;
			} else if (comparison != null && text (comparison.error ()) != "") {
				text_shown = text (comparison.error ());
			} else if (comparison != null && list.get_row_at_index (0) == null) {
				text_shown = "There are no differences.";
			} else {
				text_shown = file_message;
			}
			message.label = text_shown ?? "";
			message.visible = text_shown != null;
		}

		void update_change_label () {
			unowned Dt.FileDiff? diff = diff_view.diff;
			size_t count = diff != null ? diff.hunk_count () : 0;
			ssize_t current = diff_view.current_hunk;
			if (diff == null || file_message != null) {
				change_label.label = "";
			} else if (count == 0) {
				change_label.label = "No changes";
			} else {
				change_label.label = "Change %d of %d".printf ((int) current + 1, (int) count);
			}
			previous_button.sensitive = current > 0;
			next_button.sensitive = count > 0 && current + 1 < (ssize_t) count;
			update_conflict_label ();
			update_actions ();
		}

		/* A merge's conflicts left, in orange while there are any. */
		void update_conflict_label () {
			bool shown = shows_merge && merge_editor.has_result && file_message == null;
			conflict_label.visible = shown;
			if (!shown) return;
			size_t count = merge_editor.conflict_count;
			string label = count == 0 ? "No conflicts left" : count == 1 ? "1 conflict left" : "%d conflicts left".printf ((int) count);
			conflict_label.set_markup (count > 0 ? "<span foreground=\"#E07B00\">%s</span>".printf (label) : "<span alpha=\"60%\">%s</span>".printf (label));
		}


		/* Showing files */

		int selected_index () {
			var row = list.get_selected_row ();
			return row != null ? row.get_index () : -1;
		}

		int file_row_from (int row, int step) {
			for (int i = row + step; i >= 0; i += step) {
				var sidebar_row = list.get_row_at_index (i) as SidebarRow;
				if (sidebar_row == null) return -1;
				if (sidebar_row.entry >= 0) return i;
			}
			return -1;
		}

		/* Show the selected file's diff, unless it's already shown and force isn't set; keep: keep where it's scrolled to. */
		void show_selected_entry (bool force, bool keep) {
			var row = list.get_selected_row () as SidebarRow;
			ssize_t entry = row != null ? row.entry : -1;
			string? entry_path = row != null ? row.path : null;
			if (entry == shown_entry && !force) return;

			shown_entry = entry;
			shown_path = entry_path;
			file_message = null;
			if (document.is_merge) {
				show_merge_entry (entry);
				return;
			}
			unowned Dt.Comparison? comparison = document.comparison;
			Dt.FileDiff? diff = null;
			if (entry >= 0 && comparison != null) {
				var options = Dt.DiffOptions () { flags = ignore_whitespace ? Dt.IGNORE_WHITESPACE : 0, tab_width = TAB_WIDTH };
				diff = new Dt.FileDiff (comparison, (size_t) entry, options);
				uint32 flags = diff.flags ();
				if (text (diff.error ()) != "") {
					file_message = text (diff.error ());
				} else if ((flags & Dt.DIFF_BINARY) != 0) {
					file_message = (flags & Dt.DIFF_IDENTICAL) != 0 ? "The binary files are identical." : "The binary files differ.";
				}
			}
			for (int side = 0; side < MAX_SIDES; side++) {
				string path = side < SIDE_COUNT && comparison != null && entry >= 0 ? text (comparison.entry_path ((size_t) entry, (uint8) side)) : "";
				diff_view.files[side] = path != "" ? File.new_for_path (path) : null;
			}
			diff_view.set_diff ((owned) diff, keep);
			if (!keep) diff_view.scroll_to_current_hunk ();

			update_pane_titles ();
			update_change_label ();
			update_message ();
		}

		/*
		 * Show a merge of the document's files, its only entry. The merged result is
		 * loaded once for the comparison: a merge isn't reloaded, which would lose its edits.
		 */
		void show_merge_entry (ssize_t entry) {
			if (entry < 0 || document.comparison == null || document.base_file == null || document.file (0) == null || document.file (1) == null) {
				merge_generation = uint.MAX;
				diff_view.set_diff (null, false);
				merge_editor.load (null);
			} else if (merge_generation != document.generation) {
				merge_generation = document.generation;
				File[] files = { document.base_file, document.file (0), document.file (1) };
				var options = Dt.DiffOptions () { flags = 0, tab_width = TAB_WIDTH };
				var diff = new Dt.FileDiff.merge (files[0].get_path (), files[1].get_path (), files[2].get_path (), options);
				for (int side = 0; side < MAX_SIDES; side++) diff_view.files[side] = files[side];
				selecting_merge = true;
				if (text (diff.error ()) != "") {
					file_message = text (diff.error ());
					merge_editor.load (null);
				} else {
					merge_editor.load (diff);
				}
				diff_view.set_diff ((owned) diff, false);
				selecting_merge = false;
				current_hunk_changed ();
				diff_view.scroll_to_current_hunk ();
			}
			update_pane_titles ();
			update_change_label ();
			update_message ();
		}

		bool drop_files (File[] files, int side) {
			/* A merge's files are git's, to merge as it asked. */
			if (files.length == 0 || document.is_merge) return false;
			if (side < 0 || files.length > 1) {
				document.set_files (files);
			} else {
				document.set_file (side, files[0]);
			}
			return true;
		}

		public void open_files (File[] files, string[]? labels = null) {
			document.set_files (files, labels);
		}

		public void open_merge (File base_file, File a, File b, File output, string[]? labels) {
			document.set_merge (base_file, a, b, output, labels);
		}

		void select_file_step (int step) {
			int row = file_row_from (selected_index (), step);
			if (row >= 0) list.select_row (list.get_row_at_index (row));
		}

		void move_change (int step) {
			unowned Dt.FileDiff? diff = diff_view.diff;
			if (diff == null) return;
			ssize_t hunk = diff_view.current_hunk + step;
			if (hunk < 0 || hunk >= (ssize_t) diff.hunk_count ()) {
				/* Nowhere further to go: show where the current hunk is instead. */
				diff_view.scroll_to_current_hunk ();
				diff_view.flash_current_hunk ();
				return;
			}
			diff_view.current_hunk = hunk;
			diff_view.scroll_to_current_hunk ();
			current_hunk_changed ();
		}

		/* Show the current change in the merged result too. */
		void current_hunk_changed () {
			update_change_label ();
			if (!shows_merge) return;
			ssize_t hunk = diff_view.current_hunk;
			merge_editor.current_hunk = hunk;
			if (hunk >= 0) merge_editor.scroll_to_hunk (hunk);
		}

		/* Editing a change in the merged result makes it the current one. */
		void merge_cursor_moved () {
			if (selecting_merge || !shows_merge) return;
			Gtk.TextIter cursor;
			merge_text.buffer.get_iter_at_mark (out cursor, merge_text.buffer.get_insert ());
			ssize_t hunk = merge_editor.hunk_at (cursor);
			if (hunk < 0 || hunk == diff_view.current_hunk) return;
			diff_view.current_hunk = hunk;
			diff_view.scroll_to_current_hunk ();
			merge_editor.current_hunk = hunk;
			update_change_label ();
		}

		/* Move to the next conflict still unresolved in the merged result, skipping the other changes. */
		void move_conflict (int step) {
			unowned Dt.FileDiff? diff = diff_view.diff;
			if (!shows_merge || diff == null) return;
			ssize_t count = (ssize_t) diff.hunk_count ();
			ssize_t current = diff_view.current_hunk;
			if (current < 0) current = step > 0 ? -1 : count;
			for (ssize_t hunk = current + step; hunk >= 0 && hunk < count; hunk += step) {
				if (merge_editor.hunk_has_conflict_markers (hunk)) {
					diff_view.current_hunk = hunk;
					diff_view.scroll_to_current_hunk ();
					current_hunk_changed ();
					return;
				}
			}
			/* No conflict further on: show where the current change is instead. */
			diff_view.scroll_to_current_hunk ();
			diff_view.flash_current_hunk ();
		}

		void take_versions (uint8[] versions) {
			ssize_t hunk = diff_view.current_hunk;
			if (!shows_merge || !merge_editor.has_result || hunk < 0) return;
			selecting_merge = true;
			merge_editor.replace_hunk (hunk, versions);
			selecting_merge = false;
			merge_editor.scroll_to_hunk (hunk);
		}


		/* Saving and closing */

		/* Write the merged result to the output file. */
		async bool save_merge () {
			if (!shows_merge || document.output == null) return false;
			try {
				merge_editor.save (document.output);
				merge_resolved = !merge_editor.has_conflict_markers ();
				update_title ();
				return true;
			} catch (Error e) {
				var alert = new Gtk.AlertDialog ("The merge couldn't be saved.");
				alert.detail = e.message;
				alert.show (this);
				return false;
			}
		}

		/* A merge with unsaved changes asks whether to save them first. */
		bool close_requested () {
			var settings = Settings.get_default ();
			settings.window_maximized = maximized;
			if (!maximized) {
				settings.window_width = get_width ();
				settings.window_height = get_height ();
			}
			if (closing || !shows_merge || !merge_text.buffer.get_modified ()) {
				document.close ();
				return false;
			}
			var alert = new Gtk.AlertDialog ("Do you want to save the merge of “%s”?", document.display_name ());
			alert.detail = "Your changes will be lost if you don't save them.";
			alert.buttons = { "Don't Save", "Cancel", "Save" };
			alert.cancel_button = 1;
			alert.default_button = 2;
			alert.choose.begin (this, null, (obj, res) => {
				int choice = 1;
				try {
					choice = alert.choose.end (res);
				} catch (Error e) {}
				if (choice == 1) return;
				if (choice == 2) {
					save_merge.begin ((obj2, res2) => {
						if (save_merge.end (res2)) close_now ();
					});
					return;
				}
				close_now ();
			});
			return true;
		}

		void close_now () {
			closing = true;
			close ();
		}

	}
}
