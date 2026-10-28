namespace Diffotron {
	/*
	 * A merge's merged result, in a text view: tells the core's Dt.MergeResult of
	 * each edit, which keeps track of where each change is, colors the changes,
	 * replaces them with versions of them, and saves the result. The core counts
	 * in UTF-16 code units, and GTK in characters.
	 */
	public class MergeEditor : Object {
		public Gtk.TextView view { get; private set; }
		unowned Gtk.TextBuffer buffer;
		/* A copy of the text, told of each edit, with where the changes are in it; null with no merge. */
		Dt.MergeResult? result = null;
		bool loading = false;
		uint highlight_source = 0;
		Gtk.TextTag[] tags = new Gtk.TextTag[4];

		/* The change shown as current, or -1. */
		ssize_t _current_hunk = -1;
		public ssize_t current_hunk {
			get { return _current_hunk; }
			set {
				_current_hunk = value;
				queue_highlight ();
			}
		}
		/* How many changes are conflicts still unresolved, counted as the changes are colored. */
		public size_t conflict_count { get; private set; default = 0; }
		public bool has_result { get { return result != null; } }

		public MergeEditor (Gtk.TextView view) {
			this.view = view;
			buffer = view.buffer;
			string[] names = { "change", "current-change", "conflict", "current-conflict" };
			for (int i = 0; i < tags.length; i++) tags[i] = buffer.create_tag (names[i]);
			buffer.insert_text.connect (inserting);
			buffer.delete_range.connect (deleting);
		}

		/* Start the text over with the merged result of a merge, as it starts, or with none for null. */
		public void load (Dt.FileDiff? merge) {
			result = merge != null ? new Dt.MergeResult (merge) : null;
			string merged = result != null ? from_utf16 (result.text ()) : "";
			loading = true;
			buffer.begin_irreversible_action ();
			buffer.set_text (merged, -1);
			buffer.end_irreversible_action ();
			loading = false;
			buffer.set_modified (false);
			Gtk.TextIter start;
			buffer.get_start_iter (out start);
			buffer.place_cursor (start);
			queue_highlight ();
		}

		/* UTF-16 */

		static string from_utf16 (Dt.Str16 text) {
			var builder = new StringBuilder.sized (text.len);
			for (size_t i = 0; i < text.len; i++) {
				unichar c = text.ptr[i];
				if (c >= 0xD800 && c < 0xDC00 && i + 1 < text.len) {
					unichar low = text.ptr[i + 1];
					if (low >= 0xDC00 && low < 0xE000) {
						c = 0x10000 + ((c - 0xD800) << 10) + (low - 0xDC00);
						i++;
					}
				}
				builder.append_unichar (c);
			}
			return builder.str;
		}

		static uint16[] to_utf16 (string text) {
			uint16[] units = {};
			int index = 0;
			unichar c;
			while (text.get_next_char (ref index, out c)) {
				if (c > 0xFFFF) {
					units += (uint16) (0xD800 + ((c - 0x10000) >> 10));
					units += (uint16) (0xDC00 + ((c - 0x10000) & 0x3FF));
				} else {
					units += (uint16) c;
				}
			}
			return units;
		}

		/* How many UTF-16 code units a string takes. */
		static size_t utf16_length (string text) {
			size_t length = 0;
			int index = 0;
			unichar c;
			while (text.get_next_char (ref index, out c)) length += c > 0xFFFF ? 2 : 1;
			return length;
		}

		/* Where a position in the buffer is, in UTF-16 code units. */
		size_t utf16_offset (Gtk.TextIter iter) {
			Gtk.TextIter start;
			buffer.get_start_iter (out start);
			return utf16_length (buffer.get_text (start, iter, true));
		}

		/* The buffer's character offsets of positions in UTF-16 code units, in order, found in one pass. */
		int[] char_offsets (size_t[] positions) {
			var offsets = new int[positions.length];
			string all = buffer.text;
			size_t units = 0;
			int chars = 0, index = 0, next = 0;
			unichar c;
			while (next < positions.length) {
				while (next < positions.length && positions[next] <= units) offsets[next++] = chars;
				if (!all.get_next_char (ref index, out c)) break;
				units += c > 0xFFFF ? 2 : 1;
				chars++;
			}
			while (next < positions.length) offsets[next++] = chars;
			return offsets;
		}


		/* Editing */

		/* Tell the result of each edit, which moves the changes with the text. */
		void inserting (ref Gtk.TextIter location, string text, int length) {
			if (loading || result == null) return;
			string inserted = length < 0 ? text : text.substring (0, length);
			result.replace (utf16_offset (location), 0, to_utf16 (inserted));
			queue_highlight ();
		}

		void deleting (Gtk.TextIter start, Gtk.TextIter end) {
			if (loading || result == null) return;
			size_t from = utf16_offset (start);
			result.replace (from, utf16_length (buffer.get_text (start, end, true)), new uint16[0]);
			queue_highlight ();
		}

		/* The change a position in the buffer is in, or -1. */
		public ssize_t hunk_at (Gtk.TextIter iter) {
			return result != null ? result.hunk_at (utf16_offset (iter)) : -1;
		}

		/* Where a change's text is in the buffer, if there's such a change. */
		bool hunk_iters (ssize_t hunk, out Gtk.TextIter start, out Gtk.TextIter end) {
			buffer.get_start_iter (out start);
			buffer.get_start_iter (out end);
			size_t from = 0, length = 0;
			if (result == null || hunk < 0 || !result.hunk_range ((size_t) hunk, out from, out length)) return false;
			var offsets = char_offsets ({ from, from + length });
			buffer.get_iter_at_offset (out start, offsets[0]);
			buffer.get_iter_at_offset (out end, offsets[1]);
			return true;
		}

		public void scroll_to_hunk (ssize_t hunk) {
			Gtk.TextIter start, end;
			if (hunk_iters (hunk, out start, out end)) view.scroll_to_iter (start, 0.1, false, 0, 0);
		}

		/* Undoably replace a change's text with versions of it (Dt.VERSION_*), one after another. */
		public void replace_hunk (ssize_t hunk, uint8[] versions) {
			Gtk.TextIter start, end;
			if (!hunk_iters (hunk, out start, out end)) return;
			var replacement = new StringBuilder ();
			foreach (var version in versions) replacement.append (text (result.version ((size_t) hunk, version)));
			int offset = start.get_offset ();
			buffer.begin_user_action ();
			buffer.delete (ref start, ref end);
			buffer.insert (ref start, replacement.str, -1);
			buffer.end_user_action ();
			Gtk.TextIter cursor;
			buffer.get_iter_at_offset (out cursor, offset);
			buffer.place_cursor (cursor);
		}

		/* Whether a change is a conflict still unresolved: one with git's conflict markers in it. */
		public bool hunk_has_conflict_markers (ssize_t hunk) {
			return result != null && hunk >= 0 && result.unresolved ((size_t) hunk);
		}

		/* Whether a line of the text starts with git's conflict marker, as an unresolved conflict's does. */
		public bool has_conflict_markers () {
			return result != null && result.has_conflict_markers ();
		}

		/* Write the text to a file, in place, as the file was: in its encoding, with its line breaks. */
		public bool save (File file) throws Error {
			if (result == null) throw new IOError.FAILED ("There's no merged result to save.");
			if (!result.save (file.get_path ())) throw new IOError.FAILED ("%s", text (result.error ()));
			buffer.set_modified (false);
			return true;
		}


		/* Colors */

		void queue_highlight () {
			if (highlight_source != 0) return;
			highlight_source = Idle.add (() => {
				highlight_source = 0;
				highlight ();
				return Source.REMOVE;
			});
		}

		/* Color the changes: conflicts with their markers still in them, and the rest. And count the conflicts. */
		void highlight () {
			var colors = Colors.for_widget (view);
			tags[0].paragraph_background_rgba = colors.line[Dt.LINE_CHANGED];
			tags[1].paragraph_background_rgba = colors.current_line[Dt.LINE_CHANGED];
			tags[2].paragraph_background_rgba = colors.line[Dt.LINE_CONFLICT];
			tags[3].paragraph_background_rgba = colors.current_line[Dt.LINE_CONFLICT];
			Gtk.TextIter start, end;
			buffer.get_bounds (out start, out end);
			foreach (var tag in tags) buffer.remove_tag (tag, start, end);

			size_t count = result != null ? result.hunk_count () : 0;
			var positions = new size_t[count * 2];
			for (size_t hunk = 0; hunk < count; hunk++) {
				size_t from = 0, length = 0;
				result.hunk_range (hunk, out from, out length);
				positions[hunk * 2] = from;
				positions[hunk * 2 + 1] = from + length;
			}
			var offsets = char_offsets (positions);
			for (size_t hunk = 0; hunk < count; hunk++) {
				if (offsets[hunk * 2] >= offsets[hunk * 2 + 1]) continue;
				Gtk.TextIter from, to;
				buffer.get_iter_at_offset (out from, offsets[hunk * 2]);
				buffer.get_iter_at_offset (out to, offsets[hunk * 2 + 1]);
				int tag = (result.unresolved (hunk) ? 2 : 0) + ((ssize_t) hunk == _current_hunk ? 1 : 0);
				buffer.apply_tag (tags[tag], from, to);
			}
			conflict_count = result != null ? result.conflict_count () : 0;
		}

	}
}
