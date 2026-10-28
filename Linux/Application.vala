namespace Diffotron {
	[CCode (cname = "APP_VERSION")]
	extern const string APP_VERSION;

	const string WEBSITE = "https://github.com/srgpqt/diff-o-tron";

	const string USAGE = """usage: diff-o-tron [-L | --label LABEL]... [PATH_A PATH_B]
       diff-o-tron -o | --output MERGED [-L | --label LABEL]... BASE FILE_A FILE_B

Compare two files or folders, or merge the changes two files made to their base.

  -o, --output MERGED  merge FILE_A's and FILE_B's changes to BASE, to save to
                       MERGED; exit with 1 unless it was last saved with no
                       conflicts left
  -L, --label LABEL    show LABEL instead of a path's name: given once for every
                       side, or else for each side in turn

Each comparison opens in a window of its own, and the command returns when its
windows are closed. To use it with git difftool and git mergetool:

  [diff]
      tool = diff-o-tron
  [difftool "diff-o-tron"]
      cmd = diff-o-tron --label \"$MERGED\" \"$LOCAL\" \"$REMOTE\"
  [merge]
      tool = diff-o-tron
  [mergetool "diff-o-tron"]
      cmd = diff-o-tron --label \"$MERGED\" --output \"$MERGED\" \"$BASE\" \"$LOCAL\" \"$REMOTE\"
      trustExitCode = true
""";

	/*
	 * The app: a window per comparison. Each run is a process of its own, which
	 * returns when its windows close, as git's difftool and mergetool expect.
	 */
	public class Application : Gtk.Application {
		/* For a merge, whether it was saved with no conflicts left: the exit status. */
		public int exit_status { get; private set; default = 0; }

		public Application () {
			Object (application_id: "com.srgpqt.DiffOTron", flags: ApplicationFlags.HANDLES_COMMAND_LINE | ApplicationFlags.NON_UNIQUE);
		}

		protected override void startup () {
			base.startup ();
			add_action_named ("new-window", () => new_window ().present ());
			add_action_named ("open", () => open_dialog.begin (false));
			add_action_named ("open-folders", () => open_dialog.begin (true));
			add_action_named ("font", () => choose_font.begin ());
			add_action_named ("website", open_website);
			add_action_named ("about", show_about);
			add_action_named ("quit", () => {
				foreach (var window in get_windows ()) window.close ();
			});

			set_accels_for_action ("app.new-window", { "<Control>n" });
			set_accels_for_action ("app.open", { "<Control>o" });
			set_accels_for_action ("app.open-folders", { "<Control><Shift>o" });
			set_accels_for_action ("app.quit", { "<Control>q" });
			set_accels_for_action ("window.close", { "<Control>w" });
			set_accels_for_action ("win.save", { "<Control>s" });
			set_accels_for_action ("win.mode::blocks", { "<Control>1" });
			set_accels_for_action ("win.mode::fluid", { "<Control>2" });
			set_accels_for_action ("win.mode::unified", { "<Control>3" });
			set_accels_for_action ("win.wrap-lines", { "<Control><Shift>k" });
			set_accels_for_action ("win.ignore-whitespace", { "<Control><Shift>apostrophe" });
			set_accels_for_action ("win.larger-text", { "<Control>plus", "<Control>equal" });
			set_accels_for_action ("win.smaller-text", { "<Control>minus" });
			set_accels_for_action ("win.previous-change", { "<Control>Up" });
			set_accels_for_action ("win.next-change", { "<Control>Down" });
			set_accels_for_action ("win.previous-file", { "<Control><Shift>Up" });
			set_accels_for_action ("win.next-file", { "<Control><Shift>Down" });
			set_accels_for_action ("win.previous-conflict", { "<Alt>Up" });
			set_accels_for_action ("win.next-conflict", { "<Alt>Down" });
			set_accels_for_action ("win.take-a", { "<Alt>Left" });
			set_accels_for_action ("win.take-b", { "<Alt>Right" });
			set_accels_for_action ("win.take-a-then-b", { "<Alt><Shift>Right" });
			set_accels_for_action ("win.take-b-then-a", { "<Alt><Shift>Left" });
			set_accels_for_action ("win.reset-change", { "<Alt>BackSpace" });
		}

		delegate void Activate ();

		void add_action_named (string name, owned Activate activate) {
			var action = new SimpleAction (name, null);
			action.activate.connect (() => activate ());
			add_action (action);
		}

		Window new_window () {
			return new Window (this);
		}

		/* The frontmost window if it's empty, or else a new one. */
		Window empty_window () {
			var current = active_window as Window;
			if (current != null && current.document.is_empty ()) return current;
			return new_window ();
		}

		protected override void activate () {
			empty_window ().present ();
		}

		protected override int command_line (ApplicationCommandLine command_line) {
			string[] args = command_line.get_arguments ();
			string[] paths = {};
			string[] labels = {};
			string? output = null;
			bool options = true;
			for (int i = 1; i < args.length; i++) {
				string arg = args[i];
				if (options && arg == "--") {
					options = false;
				} else if (options && (arg == "-o" || arg == "--output")) {
					if (++i >= args.length || output != null) return usage (command_line, 2);
					output = args[i];
				} else if (options && (arg == "-L" || arg == "--label")) {
					if (++i >= args.length) return usage (command_line, 2);
					labels += args[i];
				} else if (options && (arg == "-h" || arg == "--help")) {
					command_line.print ("%s", USAGE);
					return 0;
				} else if (options && arg.length > 1 && arg.has_prefix ("-")) {
					command_line.printerr ("diff-o-tron: unknown option %s\n\n", arg);
					return usage (command_line, 2);
				} else {
					paths += arg;
				}
			}

			/* A merge's sides are its base, A and B. */
			int sides = output != null ? 3 : 2;
			if ((paths.length != 0 && paths.length != sides) || (output != null && paths.length == 0) || labels.length > sides) {
				return usage (command_line, 2);
			}
			string fill = labels.length == 1 ? labels[0] : "";
			while (labels.length < sides) labels += fill;
			File[] files = {};
			foreach (var path in paths) files += command_line.create_file_for_arg (path);

			var window = empty_window ();
			if (output != null) {
				window.open_merge (files[0], files[1], files[2], command_line.create_file_for_arg (output), labels);
				window.close_request.connect (() => {
					exit_status = window.merge_resolved ? 0 : 1;
					return false;
				});
			} else if (files.length == 2) {
				window.open_files (files, labels);
			}
			window.present ();
			return 0;
		}

		static int usage (ApplicationCommandLine command_line, int status) {
			command_line.printerr ("%s", USAGE);
			return status;
		}

		/* Choose the files, or the folders, to compare. */
		async void open_dialog (bool folders) {
			var dialog = new Gtk.FileDialog () { title = folders ? "Choose Two Folders to Compare" : "Choose Two Files to Compare", accept_label = "Compare" };
			try {
				var model = folders ? yield dialog.select_multiple_folders (active_window, null) : yield dialog.open_multiple (active_window, null);
				File[] files = {};
				for (uint i = 0; i < model.get_n_items (); i++) files += (File) model.get_item (i);
				if (files.length == 0) return;
				var window = empty_window ();
				window.open_files (files);
				window.present ();
			} catch (Error e) {
				/* Cancelled. */
			}
		}

		/* View › Font: a monospaced font family for every window, and from now on. */
		async void choose_font () {
			var settings = Settings.get_default ();
			var dialog = new Gtk.FontDialog () { title = "Choose a Font for the Comparisons" };
			/* The layout counts columns, so proportional fonts would break it. */
			dialog.filter = new Gtk.CustomFilter ((item) => {
				var family = item as Pango.FontFamily;
				var face = item as Pango.FontFace;
				if (face != null) family = face.get_family ();
				return family == null || family.is_monospace ();
			});
			Pango.FontFamily? initial = null;
			if (settings.font_family != "") {
				var map = Pango.CairoFontMap.get_default ();
				initial = map.get_family (settings.font_family);
			}
			try {
				var family = yield dialog.choose_family (active_window, initial, null);
				settings.font_family = family.get_name ();
				foreach (var window in get_windows ()) (window as Window)?.font_family_changed ();
			} catch (Error e) {
				/* Cancelled. */
			}
		}

		/* The app's website, in the default browser. */
		void open_website () {
			new Gtk.UriLauncher (WEBSITE).launch.begin (active_window, null);
		}

		/* The About dialog, with the credits the licenses of the software built in require. */
		void show_about () {
			var about = new Gtk.AboutDialog () {
				transient_for = active_window,
				modal = true,
				program_name = "Diff-o-tron",
				version = APP_VERSION,
				comments = "Compare files and folders, and merge their changes.",
				license_type = Gtk.License.CUSTOM,
				wrap_license = true
			};
			/* The credits and logo are next to the binary. */
			string directory = ".";
			try {
				directory = Path.get_dirname (FileUtils.read_link ("/proc/self/exe"));
			} catch (FileError e) {}
			try {
				string html;
				FileUtils.get_contents (Path.build_filename (directory, "credits.html"), out html);
				about.license = credits_text (html);
			} catch (Error e) {
				about.license = "Diff-o-tron is built with git-delta (MIT License) and other open-source software.";
			}
			try {
				about.logo = Gdk.Texture.from_filename (Path.build_filename (directory, "diff-o-tron.svg"));
			} catch (Error e) {}
			about.present ();
		}

		/* The credits' HTML as plain text, a paragraph per block. */
		static string credits_text (string html) {
			try {
				string text = new Regex ("<!--.*?-->", RegexCompileFlags.DOTALL).replace (html, -1, 0, "");
				text = new Regex ("<(h[1-6]|p|li|pre)[^>]*>").replace (text, -1, 0, "\n\n");
				text = new Regex ("<[^>]+>").replace (text, -1, 0, "");
				text = new Regex ("[ \t]*\n[ \t]*").replace (text, -1, 0, "\n");
				text = new Regex ("\n{3,}").replace (text, -1, 0, "\n\n");
				return text.replace ("&amp;", "&").replace ("&lt;", "<").replace ("&gt;", ">").replace ("&quot;", "\"").strip ();
			} catch (RegexError e) {
				return html;
			}
		}

		public static int main (string[] args) {
			var app = new Application ();
			int status = app.run (args);
			return status != 0 ? status : app.exit_status;
		}
	}
}
