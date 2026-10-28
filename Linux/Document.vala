namespace Diffotron {
	/*
	 * A comparison of the files or folders at its sides' paths, compared in the
	 * background and again when they change; or a merge of two files, A and B,
	 * against their base, saved to a third.
	 */
	public class Document : Object {
		/* A file or folder per side, or null. */
		File?[] files = new File?[SIDE_COUNT];
		/* A label per side, empty for none. */
		string[] labels = { "", "" };

		public bool is_merge { get; private set; default = false; }
		public File? base_file { get; private set; }
		/* The base's label, or "" for none. */
		public string base_label { get; private set; default = ""; }
		public File? output { get; private set; }

		Dt.Comparison? _comparison = null;
		public unowned Dt.Comparison? comparison { get { return _comparison; } }
		public bool comparing { get; private set; default = false; }
		/* Incremented whenever the comparison is replaced. */
		public uint generation { get; private set; default = 0; }
		/* Whether the comparison was last replaced by reloading the same files, after they changed. */
		public bool reloaded { get; private set; default = false; }

		/* The comparison or its sides changed. */
		public signal void changed ();

		/* Watching the sides, to reload when they change. */
		FileMonitor[] monitors = {};
		uint reload_source = 0;
		bool reloading = false;
		/* A reload asked for while comparing, to run when that's done. */
		bool reload_when_compared = false;

		public File? file (int side) {
			return side < SIDE_COUNT ? files[side] : null;
		}

		/* Shown instead of a side's name, such as its path in the repository from git; null for none. */
		public string? label (int side) {
			return side < SIDE_COUNT && labels[side] != "" ? labels[side] : null;
		}

		/* The side's label, or else its file name. */
		public string name (int side) {
			return label (side) ?? (files[side] != null ? files[side].get_basename () : "");
		}

		public bool is_empty () {
			return files[0] == null && files[1] == null;
		}

		public string display_name () {
			string? a = files[0] != null ? name (0) : null;
			string? b = files[1] != null ? name (1) : null;
			if (a != null && b != null) return a == b ? a : "%s ↔ %s".printf (a, b);
			return a ?? b ?? "New Comparison";
		}

		public void set_file (int side, File file) {
			if (side >= SIDE_COUNT) return;
			files[side] = file;
			labels[side] = "";
			files_changed ();
		}

		/* Sets the sides, and their labels (empty strings for none), from the first of each. */
		public void set_files (File[] new_files, string[]? new_labels = null) {
			for (int side = 0; side < SIDE_COUNT && side < new_files.length; side++) {
				files[side] = new_files[side];
				labels[side] = new_labels != null && side < new_labels.length ? new_labels[side] : "";
			}
			files_changed ();
		}

		/* A merge of a and b against base, saved to output; labels: the base's, A's and B's, empty for none. */
		public void set_merge (File base_file, File a, File b, File output, string[]? labels) {
			is_merge = true;
			this.base_file = base_file;
			this.output = output;
			base_label = labels != null && labels.length > 0 ? labels[0] : "";
			set_files ({ a, b }, labels != null && labels.length >= 3 ? new string[] { labels[1], labels[2] } : null);
		}

		/* Start comparing in the background once every side is set, and watch the sides for changes. */
		void files_changed () {
			generation++;
			_comparison = null;
			reloaded = false;
			reloading = false;
			reload_when_compared = false;
			comparing = files[0] != null && files[1] != null;
			watch_sides ();
			if (comparing) compare (false);
			changed ();
		}

		void watch_sides () {
			foreach (var monitor in monitors) monitor.cancel ();
			monitors = {};
			/* A merge isn't reloaded, which would lose the merged result's edits. */
			if (is_merge) return;
			foreach (var file in files) {
				if (file == null) continue;
				try {
					var monitor = file.monitor (FileMonitorFlags.WATCH_MOVES, null);
					monitor.changed.connect (() => side_changed ());
					monitors += monitor;
				} catch (Error e) {
					warning ("Can't watch %s: %s", file.get_path (), e.message);
				}
			}
		}

		/* Reload a moment after the last of a burst of changes. */
		void side_changed () {
			if (reload_source != 0) Source.remove (reload_source);
			reload_source = Timeout.add (RELOAD_DELAY, () => {
				reload_source = 0;
				reload ();
				return Source.REMOVE;
			});
		}

		void reload () {
			if (files[0] == null || files[1] == null) return;
			if (comparing || reloading) {
				reload_when_compared = true;
				return;
			}
			reloading = true;
			compare (true);
		}

		/*
		 * Compare the sides in the background. Reloading keeps showing the current
		 * comparison until the new one's ready, and keeps it if a side is gone, as
		 * git difftool's temporary files are once it's done.
		 */
		void compare (bool reloading_files) {
			uint compared_generation = generation;
			string path_a = files[0].get_path ();
			string path_b = files[1].get_path ();
			new Thread<void*> ("compare", () => {
				var result = new Dt.Comparison (path_a, path_b);
				Idle.add (() => {
					compared (compared_generation, (owned) result, reloading_files);
					return Source.REMOVE;
				});
				return null;
			});
		}

		void compared (uint compared_generation, owned Dt.Comparison? result, bool reloading_files) {
			if (compared_generation != generation) return;
			if (reloading_files) {
				reloading = false;
				if (_comparison != null && text (result.error ()) != "") result = null;
			}
			if (result != null) {
				_comparison = (owned) result;
				generation++;
				comparing = false;
				reloaded = reloading_files;
				changed ();
			}
			if (reload_when_compared) {
				reload_when_compared = false;
				reload ();
			}
		}

		public void close () {
			foreach (var monitor in monitors) monitor.cancel ();
			monitors = {};
			if (reload_source != 0) Source.remove (reload_source);
			reload_source = 0;
		}
	}
}
