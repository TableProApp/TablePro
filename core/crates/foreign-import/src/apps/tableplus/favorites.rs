use std::collections::HashSet;
use std::fs::{self, File};
use std::io::Read;
use std::path::{Component, Path, PathBuf};

use tokio_util::sync::CancellationToken;

use crate::app::check_cancel;
use crate::sql_file_tree::{self, SqlFileEntry};
use crate::{ForeignImportError, ForeignSavedQuery};

const KEYWORD_FILE_SUFFIX: &str = ".tag";
const MAXIMUM_KEYWORD_FILE_BYTE_COUNT: u64 = 4_096;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Root {
    pub path: PathBuf,
    pub folder_path: Vec<String>,
}

// The app's own folder first, then each shared folder under its own name.
pub(super) fn roots(favorite_root: PathBuf, shared_folders: Vec<PathBuf>) -> Vec<Root> {
    let mut seen = HashSet::from([standardized(&favorite_root)]);
    let mut roots = vec![Root {
        path: favorite_root,
        folder_path: Vec::new(),
    }];
    for folder in shared_folders {
        if !seen.insert(standardized(&folder)) {
            continue;
        }
        let name = folder
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default();
        roots.push(Root {
            path: folder,
            folder_path: vec![name],
        });
    }
    roots
}

pub(super) fn saved_queries(
    roots: &[Root],
    limit: u64,
    reads_keywords: bool,
    cancel: &CancellationToken,
) -> Result<Vec<ForeignSavedQuery>, ForeignImportError> {
    let mut queries = Vec::new();
    for root in roots {
        for entry in entries(&root.path, cancel) {
            check_cancel(cancel)?;
            let Some(content) = sql_file_tree::content(&entry, limit) else {
                continue;
            };
            queries.push(ForeignSavedQuery {
                name: entry.stem(),
                content,
                keyword: if reads_keywords { keyword(&entry) } else { None },
                folder_path: root.folder_path.iter().chain(&entry.folder_path).cloned().collect(),
                source_connection_id: None,
                is_auto_named: false,
            });
        }
    }
    check_cancel(cancel)?;
    Ok(queries)
}

pub(super) fn count(roots: &[Root]) -> usize {
    let cancel = CancellationToken::new();
    roots
        .iter()
        .map(|root| {
            entries(&root.path, &cancel)
                .iter()
                .filter(|entry| sql_file_tree::is_countable(entry))
                .count()
        })
        .sum()
}

fn entries(root: &Path, cancel: &CancellationToken) -> Vec<SqlFileEntry> {
    sql_file_tree::entries(root, &|name| !name.ends_with(KEYWORD_FILE_SUFFIX), cancel)
}

// A favorite holds a comma-separated list; a saved query keeps one keyword, and it cannot hold a space.
fn keyword(entry: &SqlFileEntry) -> Option<String> {
    let tag_path = entry
        .path
        .with_file_name(format!("{}{KEYWORD_FILE_SUFFIX}", entry.file_name));
    // A link or a pipe beside a favorite is never opened.
    if !fs::symlink_metadata(&tag_path).ok()?.is_file() {
        return None;
    }
    let mut data = Vec::new();
    File::open(&tag_path)
        .ok()?
        .take(MAXIMUM_KEYWORD_FILE_BYTE_COUNT)
        .read_to_end(&mut data)
        .ok()?;
    let list = std::str::from_utf8(&data).ok()?;
    list.split(',')
        .map(str::trim)
        .find(|keyword| !keyword.is_empty() && !keyword.chars().any(char::is_whitespace))
        .map(str::to_owned)
}

// A path with `.` and `..` folded away, without touching the disk.
pub(super) fn standardized(path: &Path) -> PathBuf {
    let mut folded = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                folded.pop();
            }
            other => folded.push(other),
        }
    }
    folded
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(path: &Path, contents: &str) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("a folder");
        }
        fs::write(path, contents).expect("a file");
    }

    fn entry_for(path: &Path) -> SqlFileEntry {
        SqlFileEntry {
            path: path.to_path_buf(),
            folder_path: Vec::new(),
            file_name: path.file_name().expect("a name").to_string_lossy().into_owned(),
            byte_count: 0,
        }
    }

    #[test]
    fn a_shared_folder_already_listed_is_not_listed_twice() {
        let listed = roots(
            PathBuf::from("/q/Favorite"),
            vec![
                PathBuf::from("/q/./Favorite/"),
                PathBuf::from("/team/queries"),
                PathBuf::from("/team/x/../queries"),
            ],
        );
        assert_eq!(
            listed,
            [
                Root {
                    path: PathBuf::from("/q/Favorite"),
                    folder_path: Vec::new()
                },
                Root {
                    path: PathBuf::from("/team/queries"),
                    folder_path: vec!["queries".to_owned()]
                },
            ]
        );
    }

    #[test]
    fn the_first_keyword_without_a_space_wins() {
        let root = tempfile::tempdir().expect("a temp dir");
        let query = root.path().join("top.sql");
        write(&query, "SELECT 1");
        write(&root.path().join("top.sql.tag"), " , Tp Space Kw,tpok ,later");
        assert_eq!(keyword(&entry_for(&query)).as_deref(), Some("tpok"));
        write(&root.path().join("top.sql.tag"), "kw\u{00A0}nbsp,\n");
        assert_eq!(keyword(&entry_for(&query)), None);
        fs::remove_file(root.path().join("top.sql.tag")).expect("removed");
        assert_eq!(keyword(&entry_for(&query)), None);
    }

    #[test]
    fn a_keyword_file_cut_inside_a_character_reads_as_none() {
        let root = tempfile::tempdir().expect("a temp dir");
        let query = root.path().join("q.sql");
        write(&query, "SELECT 1");
        let mut text = "a".repeat(4_095);
        text.push('é');
        write(&root.path().join("q.sql.tag"), &text);
        assert_eq!(keyword(&entry_for(&query)), None);
    }

    #[cfg(unix)]
    #[test]
    fn a_linked_keyword_file_is_not_read() {
        let root = tempfile::tempdir().expect("a temp dir");
        let query = root.path().join("q.sql");
        write(&query, "SELECT 1");
        write(&root.path().join("secret.txt"), "token");
        std::os::unix::fs::symlink(root.path().join("secret.txt"), root.path().join("q.sql.tag")).expect("a link");
        assert_eq!(keyword(&entry_for(&query)), None);
    }
}
