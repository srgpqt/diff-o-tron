use std::fs;
use std::io;
use std::ops::Range;
use std::path::Path;

use unicode_width::UnicodeWidthChar;

/// How many leading bytes to scan for a NUL when deciding a file is binary (same as git).
const BINARY_SNIFF_LEN: usize = 8000;

/// The contents of one side of a file comparison, split into lines.
#[derive(Debug, Default)]
pub struct Text {
    pub content: String,
    /// Byte ranges of each line in `content`, including its terminator.
    pub lines: Vec<Range<usize>>,
    pub binary: bool,
    /// The raw bytes, kept only for binary files so they can still be compared.
    pub bytes: Vec<u8>,
}

impl Text {
    /// Load a file. A symlink is read as its target path, as git does.
    pub fn load(path: &Path) -> io::Result<Text> {
        let meta = fs::symlink_metadata(path)?;
        if meta.file_type().is_symlink() {
            let target = fs::read_link(path)?;
            return Ok(Text::from_bytes(target.to_string_lossy().into_owned().into_bytes()));
        }
        Ok(Text::from_bytes(fs::read(path)?))
    }

    pub fn from_bytes(bytes: Vec<u8>) -> Text {
        let sniff = &bytes[..bytes.len().min(BINARY_SNIFF_LEN)];
        if sniff.contains(&0) {
            return Text { binary: true, bytes, ..Text::default() };
        }
        let content = match String::from_utf8(bytes) {
            Ok(s) => s,
            // Not UTF-8: show it as Latin-1, which maps every byte to a character.
            Err(e) => e.into_bytes().iter().map(|&b| b as char).collect(),
        };
        let mut lines = Vec::new();
        let mut start = 0;
        for line in content.split_inclusive('\n') {
            lines.push(start..start + line.len());
            start += line.len();
        }
        Text { content, lines, binary: false, bytes: Vec::new() }
    }

    /// A line including its terminator, as used for matching lines.
    pub fn raw_line(&self, index: usize) -> &str {
        &self.content[self.lines[index].clone()]
    }

    /// A line without its terminator, as displayed.
    pub fn line(&self, index: usize) -> &str {
        let raw = self.raw_line(index);
        let raw = raw.strip_suffix('\n').unwrap_or(raw);
        raw.strip_suffix('\r').unwrap_or(raw)
    }

    pub fn raw_lines(&self) -> impl Iterator<Item = &str> {
        (0..self.lines.len()).map(|i| self.raw_line(i))
    }

    pub fn same_contents(&self, other: &Text) -> bool {
        self.binary == other.binary && self.content == other.content && self.bytes == other.bytes
    }
}

/// The display width of a line in columns, expanding tabs to `tab_width` stops.
pub fn columns(line: &str, tab_width: u32) -> u32 {
    let tab_width = tab_width.max(1);
    let mut col = 0;
    for c in line.chars() {
        if c == '\t' {
            col = (col / tab_width + 1) * tab_width;
        } else {
            col += c.width().unwrap_or(0) as u32;
        }
    }
    col
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_lines_keeping_terminators() {
        let t = Text::from_bytes(b"a\r\nb\n\nc".to_vec());
        assert_eq!(t.raw_lines().collect::<Vec<_>>(), ["a\r\n", "b\n", "\n", "c"]);
        assert_eq!((0..4).map(|i| t.line(i)).collect::<Vec<_>>(), ["a", "b", "", "c"]);
    }

    #[test]
    fn empty_file_has_no_lines() {
        assert!(Text::from_bytes(Vec::new()).lines.is_empty());
    }

    #[test]
    fn detects_binary() {
        let t = Text::from_bytes(vec![b'a', 0, b'b']);
        assert!(t.binary);
        assert!(t.lines.is_empty());
    }

    #[test]
    fn decodes_non_utf8_as_latin1() {
        let t = Text::from_bytes(vec![b'c', b'a', b'f', 0xe9]);
        assert_eq!(t.line(0), "café");
    }

    #[test]
    fn counts_columns() {
        assert_eq!(columns("ab", 4), 2);
        assert_eq!(columns("\tx", 4), 5);
        assert_eq!(columns("ab\tx", 4), 5);
        assert_eq!(columns("日本", 4), 4);
    }
}
