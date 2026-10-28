use std::cmp::Ordering;
use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};

use crate::text::read_contents;

/// Names never compared when walking directories.
const IGNORED_NAMES: &[&str] = &[".git", ".hg", ".svn", ".DS_Store"];

/// Compared as a missing file, as git passes it for added and deleted files.
const NULL_DEVICE: &str = "/dev/null";

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    Same = 0,
    Modified = 1,
    /// Only on side B.
    Added = 2,
    /// Only on side A.
    Removed = 3,
}

/// A file present on either or both sides of a comparison.
#[derive(Debug)]
pub struct Entry {
    /// Path relative to the compared roots, with `/` separators.
    pub path: String,
    /// Length of the directory part of `path`, without the trailing `/`.
    pub dir_len: usize,
    pub a: Option<PathBuf>,
    pub b: Option<PathBuf>,
    /// The full paths of `a` and `b` for display, empty when absent.
    pub display: [String; 2],
    pub status: Status,
}

impl Entry {
    fn new(path: String, a: Option<PathBuf>, b: Option<PathBuf>) -> Entry {
        let status = match (&a, &b) {
            (Some(a), Some(b)) if same_contents(a, b) => Status::Same,
            (Some(_), Some(_)) => Status::Modified,
            (Some(_), None) => Status::Removed,
            _ => Status::Added,
        };
        let dir_len = path.rfind('/').unwrap_or(0);
        let display = |p: &Option<PathBuf>| p.as_ref().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
        let display = [display(&a), display(&b)];
        Entry { path, dir_len, a, b, display, status }
    }

    pub fn dir(&self) -> &str {
        &self.path[..self.dir_len]
    }

    pub fn name(&self) -> &str {
        self.path[self.dir_len..].trim_start_matches('/')
    }
}

/// The files of two compared paths, each either a file or a directory.
#[derive(Debug, Default)]
pub struct Comparison {
    pub roots: [PathBuf; 2],
    /// Sorted by path, with each directory's files before its subdirectories, so files of the
    /// same directory are adjacent.
    pub entries: Vec<Entry>,
    pub error: Option<String>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    File,
    Dir,
}

/// The kind of `path`, not following symlinks unless `follow` is set.
fn kind(path: &Path, follow: bool) -> Option<Kind> {
    let meta = if follow { fs::metadata(path) } else { fs::symlink_metadata(path) };
    meta.ok().map(|m| if m.is_dir() { Kind::Dir } else { Kind::File })
}

impl Comparison {
    pub fn new(a: &Path, b: &Path) -> Comparison {
        let mut cmp = Comparison { roots: [a.to_path_buf(), b.to_path_buf()], ..Comparison::default() };
        let (ka, kb) = match (fs::metadata(a), fs::metadata(b)) {
            (Ok(ma), Ok(mb)) => (ma.is_dir(), mb.is_dir()),
            (Err(e), _) => return cmp.fail(a, e),
            (_, Err(e)) => return cmp.fail(b, e),
        };
        let name = |p: &Path| p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        match (ka, kb) {
            (true, true) => cmp.walk(Some(a), Some(b), ""),
            (false, false) => {
                let present = |p: &Path| (p != Path::new(NULL_DEVICE)).then(|| p.to_path_buf());
                let (pa, pb) = (present(a), present(b));
                let (na, nb) = (name(a), name(b));
                let path = match (&pa, &pb) {
                    (None, _) => nb,
                    (_, None) => na,
                    _ if na == nb => na,
                    _ => format!("{na} → {nb}"),
                };
                cmp.push(path, pa, pb);
            }
            // Like diff(1): compare the file with the file of the same name in the directory.
            (false, true) => {
                let other = b.join(name(a));
                let other = kind(&other, true).is_some_and(|k| k == Kind::File).then_some(other);
                cmp.push(name(a), Some(a.to_path_buf()), other);
            }
            (true, false) => {
                let other = a.join(name(b));
                let other = kind(&other, true).is_some_and(|k| k == Kind::File).then_some(other);
                cmp.push(name(b), other, Some(b.to_path_buf()));
            }
        }
        cmp
    }

    fn fail(mut self, path: &Path, e: std::io::Error) -> Comparison {
        self.error = Some(format!("{}: {e}", path.display()));
        self
    }

    fn push(&mut self, path: String, a: Option<PathBuf>, b: Option<PathBuf>) {
        self.entries.push(Entry::new(path, a, b));
    }

    /// Add the files under the directories `a` and `b`, either of which may be missing.
    fn walk(&mut self, a: Option<&Path>, b: Option<&Path>, rel: &str) {
        let mut names: Vec<OsString> = [a, b].into_iter().flatten().flat_map(read_dir_names).collect();
        names.sort_by(compare_names);
        names.dedup();

        let children: Vec<_> = names
            .iter()
            .map(|name| {
                let child_a = a.map(|a| a.join(name));
                let child_b = b.map(|b| b.join(name));
                let kind_a = child_a.as_deref().and_then(|p| kind(p, false));
                let kind_b = child_b.as_deref().and_then(|p| kind(p, false));
                let rel = if rel.is_empty() {
                    name.to_string_lossy().into_owned()
                } else {
                    format!("{rel}/{}", name.to_string_lossy())
                };
                (rel, child_a, kind_a, child_b, kind_b)
            })
            .collect();

        // Files before subdirectories, so each directory's files are adjacent. A file on one side
        // and a directory on the other appear as both.
        for (rel, child_a, kind_a, child_b, kind_b) in &children {
            let file_a = child_a.clone().filter(|_| *kind_a == Some(Kind::File));
            let file_b = child_b.clone().filter(|_| *kind_b == Some(Kind::File));
            if file_a.is_some() || file_b.is_some() {
                self.push(rel.clone(), file_a, file_b);
            }
        }
        for (rel, child_a, kind_a, child_b, kind_b) in &children {
            let dir_a = child_a.as_deref().filter(|_| *kind_a == Some(Kind::Dir));
            let dir_b = child_b.as_deref().filter(|_| *kind_b == Some(Kind::Dir));
            if dir_a.is_some() || dir_b.is_some() {
                self.walk(dir_a, dir_b, rel);
            }
        }
    }
}

fn read_dir_names(dir: &Path) -> Vec<OsString> {
    let Ok(entries) = fs::read_dir(dir) else { return Vec::new() };
    entries.filter_map(|e| e.ok().map(|e| e.file_name())).filter(|n| !IGNORED_NAMES.iter().any(|i| n == i)).collect()
}

/// Case-insensitive, then case-sensitive so the order is total.
fn compare_names(x: &OsString, y: &OsString) -> Ordering {
    let (x, y) = (x.to_string_lossy(), y.to_string_lossy());
    x.to_lowercase().cmp(&y.to_lowercase()).then_with(|| x.cmp(&y))
}

fn same_contents(a: &Path, b: &Path) -> bool {
    if let (Ok(ma), Ok(mb)) = (fs::metadata(a), fs::metadata(b))
        && ma.is_file()
        && mb.is_file()
        && ma.len() != mb.len()
    {
        return false;
    }
    match (read_contents(a), read_contents(b)) {
        (Ok(a), Ok(b)) => a == b,
        _ => false,
    }
}

/// A row of a comparison's listing of its files, as a sidebar shows it: a file, or the heading of
/// the directory the files after it are in.
#[derive(Debug, PartialEq)]
pub struct Item {
    /// The file's name, or the directory's path, its parts separated by ` › `.
    pub title: String,
    /// The file's entry, or `None` for a directory's heading.
    pub entry: Option<usize>,
}

impl Comparison {
    /// The files to list: those that changed, or the one compared if it's just two files, each
    /// directory's under its heading.
    pub fn listing(&self) -> Vec<Item> {
        let mut items = Vec::new();
        let mut last_dir = "";
        for (i, entry) in self.entries.iter().enumerate() {
            if entry.status == Status::Same && self.entries.len() > 1 {
                continue;
            }
            let dir = entry.dir();
            if !dir.is_empty() && dir != last_dir {
                items.push(Item { title: dir.replace('/', " › "), entry: None });
            }
            last_dir = dir;
            items.push(Item { title: entry.name().to_string(), entry: Some(i) });
        }
        items
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    /// A fresh directory with the given files, removed when dropped.
    struct TempTree(PathBuf);

    impl TempTree {
        fn new(files: &[(&str, &str)]) -> TempTree {
            static COUNTER: AtomicU32 = AtomicU32::new(0);
            let n = COUNTER.fetch_add(1, Ordering::Relaxed);
            let root = std::env::temp_dir().join(format!("diffotron-test-{}-{n}", std::process::id()));
            let _ = fs::remove_dir_all(&root);
            fs::create_dir_all(&root).unwrap();
            for (path, contents) in files {
                let path = root.join(path);
                fs::create_dir_all(path.parent().unwrap()).unwrap();
                fs::write(path, contents).unwrap();
            }
            TempTree(root)
        }
    }

    impl Drop for TempTree {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn summary(cmp: &Comparison) -> Vec<(&str, Status)> {
        cmp.entries.iter().map(|e| (e.path.as_str(), e.status)).collect()
    }

    #[test]
    fn compares_directories() {
        let a = TempTree::new(&[("same.txt", "x"), ("Docs/b.md", "1"), ("gone.txt", ""), ("Lib/x/y.c", "")]);
        let b = TempTree::new(&[("same.txt", "x"), ("Docs/b.md", "2"), ("Docs/a.md", ""), (".git/HEAD", "")]);
        let cmp = Comparison::new(&a.0, &b.0);
        assert_eq!(cmp.error, None);
        assert_eq!(
            summary(&cmp),
            [
                ("gone.txt", Status::Removed),
                ("same.txt", Status::Same),
                ("Docs/a.md", Status::Added),
                ("Docs/b.md", Status::Modified),
                ("Lib/x/y.c", Status::Removed),
            ]
        );
        assert_eq!((cmp.entries[4].dir(), cmp.entries[4].name()), ("Lib/x", "y.c"));
        assert_eq!((cmp.entries[0].dir(), cmp.entries[0].name()), ("", "gone.txt"));

        // Listed without the unchanged file, each directory's files under its heading.
        let item = |title: &str, entry| Item { title: title.into(), entry };
        assert_eq!(
            cmp.listing(),
            [
                item("gone.txt", Some(0)),
                item("Docs", None),
                item("a.md", Some(2)),
                item("b.md", Some(3)),
                item("Lib › x", None),
                item("y.c", Some(4)),
            ]
        );
    }

    #[test]
    fn compares_two_files() {
        let t = TempTree::new(&[("a.txt", "1"), ("b.txt", "2")]);
        let cmp = Comparison::new(&t.0.join("a.txt"), &t.0.join("b.txt"));
        assert_eq!(summary(&cmp), [("a.txt → b.txt", Status::Modified)]);
        // Two files are listed even if they're the same.
        let same = TempTree::new(&[("a.txt", "1"), ("b.txt", "1")]);
        let cmp = Comparison::new(&same.0.join("a.txt"), &same.0.join("b.txt"));
        assert_eq!(cmp.listing(), [Item { title: "a.txt → b.txt".into(), entry: Some(0) }]);
    }

    #[test]
    fn compares_file_with_directory() {
        let a = TempTree::new(&[("f.txt", "1")]);
        let b = TempTree::new(&[("f.txt", "1")]);
        let cmp = Comparison::new(&a.0.join("f.txt"), &b.0);
        assert_eq!(summary(&cmp), [("f.txt", Status::Same)]);
    }

    #[test]
    fn file_replaced_by_directory() {
        let a = TempTree::new(&[("x", "1")]);
        let b = TempTree::new(&[("x/y", "2")]);
        let cmp = Comparison::new(&a.0, &b.0);
        assert_eq!(summary(&cmp), [("x", Status::Removed), ("x/y", Status::Added)]);
    }

    #[test]
    fn null_device_is_a_missing_file() {
        let t = TempTree::new(&[("new.txt", "1")]);
        let cmp = Comparison::new(Path::new(NULL_DEVICE), &t.0.join("new.txt"));
        assert_eq!(summary(&cmp), [("new.txt", Status::Added)]);
        let cmp = Comparison::new(&t.0.join("new.txt"), Path::new(NULL_DEVICE));
        assert_eq!(summary(&cmp), [("new.txt", Status::Removed)]);
    }

    #[cfg(unix)]
    #[test]
    fn follows_symlinks_to_files() {
        // As `git difftool --dir-diff` makes for working tree files.
        let a = TempTree::new(&[("f.txt", "1")]);
        let b = TempTree::new(&[("real/f.txt", "1")]);
        std::os::unix::fs::symlink(b.0.join("real/f.txt"), b.0.join("f.txt")).unwrap();
        let cmp = Comparison::new(&a.0, &b.0);
        assert_eq!(summary(&cmp), [("f.txt", Status::Same), ("real/f.txt", Status::Added)]);
    }

    #[test]
    fn missing_root_is_an_error() {
        let a = TempTree::new(&[]);
        let cmp = Comparison::new(&a.0.join("nope"), &a.0);
        assert!(cmp.error.is_some());
        assert!(cmp.entries.is_empty());
    }
}
