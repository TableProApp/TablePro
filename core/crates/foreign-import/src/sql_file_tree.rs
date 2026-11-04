use std::fs::{self, File};
use std::io::Read;
use std::path::{Path, PathBuf};

use tokio_util::sync::CancellationToken;

use crate::SavedQueryContent;

pub(crate) const MAXIMUM_ENTRY_COUNT: usize = 10_000;
// Leaves room for the app and shared-folder names above a file's own folders.
pub(crate) const MAXIMUM_DEPTH: usize = 30;
// A tree of folders with few matching files would otherwise be walked in full.
pub(crate) const MAXIMUM_DIRECTORY_COUNT: usize = 2_000;
const INSPECTED_BYTE_COUNT: u64 = 4_096;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SqlFileEntry {
    pub path: PathBuf,
    pub folder_path: Vec<String>,
    pub file_name: String,
    pub byte_count: u64,
}

impl SqlFileEntry {
    // The file name without its last extension, as the other apps show it.
    pub fn stem(&self) -> String {
        file_stem(&self.file_name)
    }
}

pub(crate) fn file_stem(file_name: &str) -> String {
    match file_name.rfind('.') {
        Some(0) | None => file_name.to_owned(),
        Some(dot) => file_name[..dot].to_owned(),
    }
}

pub(crate) fn entries(root: &Path, accepts: &dyn Fn(&str) -> bool, cancel: &CancellationToken) -> Vec<SqlFileEntry> {
    let mut found = Vec::new();
    let mut budget = MAXIMUM_DIRECTORY_COUNT;
    walk(root, &mut Vec::new(), accepts, cancel, &mut found, &mut budget);
    if found.len() >= MAXIMUM_ENTRY_COUNT || budget == 0 {
        tracing::warn!(entries = found.len(), "stopped listing saved query files");
    }
    found
}

fn walk(
    directory: &Path,
    folder_path: &mut Vec<String>,
    accepts: &dyn Fn(&str) -> bool,
    cancel: &CancellationToken,
    found: &mut Vec<SqlFileEntry>,
    budget: &mut usize,
) {
    if folder_path.len() > MAXIMUM_DEPTH || *budget == 0 || cancel.is_cancelled() {
        return;
    }
    *budget -= 1;
    let Ok(children) = fs::read_dir(directory) else {
        return;
    };
    let mut children: Vec<(String, PathBuf)> = children
        .filter_map(Result::ok)
        .filter_map(|child| child.file_name().into_string().ok().map(|name| (name, child.path())))
        .collect();
    children.sort_by(|left, right| left.0.cmp(&right.0));

    for (name, path) in children {
        if found.len() >= MAXIMUM_ENTRY_COUNT {
            return;
        }
        if name.starts_with('.') {
            continue;
        }
        // Never followed: a link could lead out of the app's folder or back into it.
        let Ok(metadata) = fs::symlink_metadata(&path) else {
            continue;
        };
        if metadata.file_type().is_symlink() {
            continue;
        }
        if metadata.is_dir() {
            folder_path.push(name);
            walk(&path, folder_path, accepts, cancel, found, budget);
            folder_path.pop();
        } else if metadata.is_file() && accepts(&name) {
            found.push(SqlFileEntry {
                path,
                folder_path: folder_path.clone(),
                file_name: name,
                byte_count: metadata.len(),
            });
        }
    }
}

pub(crate) fn content(entry: &SqlFileEntry, limit: u64) -> Option<SavedQueryContent> {
    if entry.byte_count > limit {
        return Some(SavedQueryContent::Oversized {
            byte_count: entry.byte_count,
        });
    }
    let file = File::open(&entry.path).ok()?;
    let mut data = Vec::new();
    file.take(limit.saturating_add(1)).read_to_end(&mut data).ok()?;
    if data.is_empty() {
        return None;
    }
    let read = u64::try_from(data.len()).unwrap_or(u64::MAX);
    // The file can grow between listing and reading.
    if read > limit {
        return Some(SavedQueryContent::Oversized {
            byte_count: entry.byte_count.max(read),
        });
    }
    text(&data).map(SavedQueryContent::Text)
}

// Counting must stay cheap, so only a small file is opened to rule out one that is blank.
pub(crate) fn is_countable(entry: &SqlFileEntry) -> bool {
    if entry.byte_count == 0 {
        return false;
    }
    if entry.byte_count > INSPECTED_BYTE_COUNT {
        return true;
    }
    fs::read(&entry.path).ok().is_some_and(|data| text(&data).is_some())
}

pub(crate) fn text(data: &[u8]) -> Option<String> {
    let text = std::str::from_utf8(data).ok()?;
    let text = text.strip_prefix('\u{FEFF}').unwrap_or(text);
    if text.trim().is_empty() {
        None
    } else {
        Some(text.to_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(path: &Path, contents: &[u8]) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("a folder");
        }
        fs::write(path, contents).expect("a file");
    }

    fn all(_: &str) -> bool {
        true
    }

    #[test]
    fn files_are_listed_in_byte_order_of_names_with_their_folders_skipping_hidden_ones() {
        let root = tempfile::tempdir().expect("a temp dir");
        write(&root.path().join("b.sql"), b"SELECT 2");
        write(&root.path().join("a.sql"), b"SELECT 1");
        write(&root.path().join("Reports/Daily/sales.sql"), b"SELECT 3");
        write(&root.path().join(".hidden.sql"), b"SELECT 4");
        write(&root.path().join(".git/x.sql"), b"SELECT 5");
        let listed = entries(root.path(), &all, &CancellationToken::new());
        let names: Vec<(&[String], &str)> = listed
            .iter()
            .map(|entry| (entry.folder_path.as_slice(), entry.file_name.as_str()))
            .collect();
        assert_eq!(
            names,
            [
                (&["Reports".to_owned(), "Daily".to_owned()] as &[String], "sales.sql"),
                (&[] as &[String], "a.sql"),
                (&[] as &[String], "b.sql"),
            ]
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_symbolic_link_is_never_followed() {
        let root = tempfile::tempdir().expect("a temp dir");
        let outside = tempfile::tempdir().expect("a temp dir");
        write(&outside.path().join("secret.sql"), b"SELECT 1");
        std::os::unix::fs::symlink(outside.path(), root.path().join("linked")).expect("a link");
        std::os::unix::fs::symlink(outside.path().join("secret.sql"), root.path().join("file.sql")).expect("a link");
        assert!(entries(root.path(), &all, &CancellationToken::new()).is_empty());
    }

    #[test]
    fn content_is_text_oversized_or_nothing() {
        let root = tempfile::tempdir().expect("a temp dir");
        write(&root.path().join("bom.sql"), "\u{FEFF}SELECT 1".as_bytes());
        write(&root.path().join("blank.sql"), b"  \n\t");
        write(&root.path().join("big.sql"), &[b'x'; 30]);
        write(&root.path().join("binary.sql"), &[0xff, 0xfe, 0x00]);
        let listed = entries(root.path(), &all, &CancellationToken::new());
        let by_name = |name: &str| listed.iter().find(|entry| entry.file_name == name).expect("an entry");
        assert_eq!(
            content(by_name("bom.sql"), 20),
            Some(SavedQueryContent::Text("SELECT 1".to_owned()))
        );
        assert_eq!(content(by_name("blank.sql"), 20), None);
        assert_eq!(content(by_name("binary.sql"), 20), None);
        assert_eq!(
            content(by_name("big.sql"), 20),
            Some(SavedQueryContent::Oversized { byte_count: 30 })
        );
        assert!(!is_countable(by_name("blank.sql")));
        assert!(is_countable(by_name("bom.sql")));
    }

    #[test]
    fn the_stem_drops_only_the_last_extension() {
        assert_eq!(file_stem("report.daily.sql"), "report.daily");
        assert_eq!(file_stem("console"), "console");
    }
}
