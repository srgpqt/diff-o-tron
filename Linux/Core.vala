/*
 * What the Linux front end's files share: the core library's strings, the
 * layout's measurements, the diff colors, and the settings.
 */
namespace Diffotron {
	/* The number of compared sides; a merge has its base too. */
	public const int SIDE_COUNT = 2;
	public const int MAX_SIDES = 3;
	public const uint32 TAB_WIDTH = 4;

	public const double TOP_PADDING = 4;
	public const double GUTTER_PADDING = 8;
	public const double TEXT_PADDING = 8;
	public const double UNIFIED_LETTER_WIDTH = 14;
	/* The width of the gap between sides. */
	public const double MIDDLE_WIDTH = 40;
	public const double DEFAULT_FONT_SIZE = 11;
	public const double MIN_FONT_SIZE = 8;
	public const double MAX_FONT_SIZE = 36;
	/* How long to wait after a burst of changes to files before reloading them, in milliseconds. */
	public const uint RELOAD_DELAY = 300;

	/* DiffView.mode */
	public enum Mode {
		BLOCKS, /* the sides' lines aligned, with filler where a side has none */
		FLUID,  /* each side's lines together, with connectors joining the changes */
		UNIFIED /* one column of lines, the changed ones from either side */
	}

	/* A core library string, which isn't NUL-terminated, as a string. */
	public string text (Dt.Str s) {
		if (s.len == 0) return "";
		return ((string) s.ptr).substring (0, (long) s.len);
	}

	/* The number of DtLine.kind values, which also color hunks by DtHunk.kind. */
	public const int KIND_COUNT = 5;

	/* The diff colors, for light and dark themes: see Colors.for_widget. */
	public class Colors {
		public Gdk.RGBA[] line = new Gdk.RGBA[KIND_COUNT];
		/* For the lines of the current hunk. */
		public Gdk.RGBA[] current_line = new Gdk.RGBA[KIND_COUNT];
		public Gdk.RGBA[] emphasis = new Gdk.RGBA[KIND_COUNT];
		public Gdk.RGBA[] edge = new Gdk.RGBA[KIND_COUNT];
		public Gdk.RGBA filler;
		public Gdk.RGBA middle;
		public Gdk.RGBA background;
		/* For the current hunk's flash, and the selection. */
		public Gdk.RGBA accent;

		static Colors? light_colors = null;
		static Colors? dark_colors = null;

		static Gdk.RGBA rgb (uint32 hex) {
			return Gdk.RGBA () {
				red = (float) ((hex >> 16) & 0xff) / 255.0f,
				green = (float) ((hex >> 8) & 0xff) / 255.0f,
				blue = (float) (hex & 0xff) / 255.0f,
				alpha = 1
			};
		}

		Colors (bool dark) {
			/* The same colors as macOS/DiffView.m's, light then dark. */
			uint32[,] table = {
				{ 0xECE8FD, 0x37324F, 0xDED7FB, 0x433C62, 0xC6BAF6, 0x5D50A0, 0x9A8AE8, 0x7D6BD6 }, /* changed */
				{ 0xFCE6E6, 0x432729, 0xF8D5D5, 0x552F32, 0xF1B3B3, 0x7A3C43, 0xE08080, 0xB0545C }, /* removed */
				{ 0xE3F5DC, 0x253A26, 0xD2EDC8, 0x2D4830, 0xB2E2A0, 0x3D6E40, 0x7CC46A, 0x4F9A55 }, /* added */
				{ 0xFFEBD6, 0x4A3320, 0xFCDCBC, 0x5A3D22, 0xF7C08C, 0x7A5130, 0xF0A050, 0xC07830 }  /* conflict */
			};
			int choice = dark ? 1 : 0;
			for (int kind = 1; kind < KIND_COUNT; kind++) {
				line[kind] = rgb (table[kind - 1, 0 + choice]);
				current_line[kind] = rgb (table[kind - 1, 2 + choice]);
				emphasis[kind] = rgb (table[kind - 1, 4 + choice]);
				edge[kind] = rgb (table[kind - 1, 6 + choice]);
			}
			filler = rgb (dark ? 0x262628 : 0xF4F4F6);
			middle = rgb (dark ? 0x232325 : 0xF7F7F9);
			background = rgb (dark ? 0x1E1E1E : 0xFFFFFF);
			accent = rgb (0x3584E4);
		}

		/* The colors for a widget's theme: dark when its text is light. */
		public static unowned Colors for_widget (Gtk.Widget widget) {
			var color = widget.get_color ();
			bool dark = 0.299 * color.red + 0.587 * color.green + 0.114 * color.blue > 0.5;
			if (dark) {
				if (dark_colors == null) dark_colors = new Colors (true);
				return dark_colors;
			}
			if (light_colors == null) light_colors = new Colors (false);
			return light_colors;
		}

		/* The background of a changed line, or the band joining a hunk across sides. */
		public Gdk.RGBA line_color (uint8 kind, bool in_current_hunk) {
			return in_current_hunk ? current_line[kind] : line[kind];
		}
	}

	/*
	 * The settings new windows start with, as they were last changed: in
	 * ~/.config/diff-o-tron/settings.ini.
	 */
	public class Settings : Object {
		public Mode mode { get; set; default = Mode.FLUID; }
		public bool wraps_lines { get; set; default = true; }
		public double font_size { get; set; default = DEFAULT_FONT_SIZE; }
		/* The font family, or "" for the desktop's monospaced font. */
		public string font_family { get; set; default = ""; }
		public int window_width { get; set; default = 1200; }
		public int window_height { get; set; default = 780; }
		public bool window_maximized { get; set; default = false; }

		static Settings? instance = null;
		const string GROUP = "Diff-o-tron";

		public static Settings get_default () {
			if (instance == null) {
				instance = new Settings ();
				instance.load ();
				instance.notify.connect (() => instance.save ());
			}
			return instance;
		}

		static string path () {
			return Path.build_filename (Environment.get_user_config_dir (), "diff-o-tron", "settings.ini");
		}

		void load () {
			var file = new KeyFile ();
			try {
				file.load_from_file (path (), KeyFileFlags.NONE);
			} catch (Error e) {
				return;
			}
			try { mode = (Mode) file.get_integer (GROUP, "Mode").clamp (Mode.BLOCKS, Mode.UNIFIED); } catch (Error e) {}
			try { wraps_lines = file.get_boolean (GROUP, "WrapLines"); } catch (Error e) {}
			try { font_size = file.get_double (GROUP, "TextSize").clamp (MIN_FONT_SIZE, MAX_FONT_SIZE); } catch (Error e) {}
			try { font_family = file.get_string (GROUP, "FontFamily"); } catch (Error e) {}
			try { window_width = file.get_integer (GROUP, "WindowWidth"); } catch (Error e) {}
			try { window_height = file.get_integer (GROUP, "WindowHeight"); } catch (Error e) {}
			try { window_maximized = file.get_boolean (GROUP, "WindowMaximized"); } catch (Error e) {}
		}

		void save () {
			var file = new KeyFile ();
			file.set_integer (GROUP, "Mode", mode);
			file.set_boolean (GROUP, "WrapLines", wraps_lines);
			file.set_double (GROUP, "TextSize", font_size);
			file.set_string (GROUP, "FontFamily", font_family);
			file.set_integer (GROUP, "WindowWidth", window_width);
			file.set_integer (GROUP, "WindowHeight", window_height);
			file.set_boolean (GROUP, "WindowMaximized", window_maximized);
			try {
				DirUtils.create_with_parents (Path.get_dirname (path ()), 0755);
				file.save_to_file (path ());
			} catch (Error e) {
				warning ("Can't save the settings: %s", e.message);
			}
		}
	}
}
