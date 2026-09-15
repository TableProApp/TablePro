//! Per-column widths the user dragged, remembered per connection and
//! table.
//!
//! The cache is the authority while the app runs and the file catches
//! up behind it, so a drag never waits on the disk.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use tablepro_session::runtime::{LatestWinsWriter, Tasks};
use tablepro_storage::StoragePaths;
use uuid::Uuid;

type Widths = HashMap<String, i32>;
type Tables = HashMap<String, Widths>;
type Connections = HashMap<String, Tables>;

/// Lives on the GTK thread and hands snapshots to a writer that runs
/// off it.
#[derive(Clone)]
pub struct ColumnWidthStore {
    inner: Rc<Inner>,
}

struct Inner {
    cache: RefCell<Connections>,
    writer: LatestWinsWriter<Connections>,
}

impl ColumnWidthStore {
    /// Reads the file once at startup. It is a few kilobytes, so this
    /// is cheaper than making every later read fallible.
    pub fn load(paths: &StoragePaths, tasks: &Tasks) -> Self {
        let path = paths.column_widths_file();
        let cache = read(&path);
        let writer = LatestWinsWriter::spawn(tasks, move |widths: &Connections| {
            super::write_json(&path, widths, "column widths");
        });
        Self {
            inner: Rc::new(Inner {
                cache: RefCell::new(cache),
                writer,
            }),
        }
    }

    pub fn width(&self, connection_id: Uuid, table: &str, column: &str) -> Option<i32> {
        let cache = self.inner.cache.borrow();
        cache.get(&connection_id.to_string())?.get(table)?.get(column).copied()
    }

    /// A non-positive width is what an unrealized column reports, and
    /// an unchanged one has nothing to save.
    pub fn record(&self, connection_id: Uuid, table: &str, column: &str, width: i32) {
        if width <= 0 || self.width(connection_id, table, column) == Some(width) {
            return;
        }
        let snapshot = {
            let mut cache = self.inner.cache.borrow_mut();
            cache
                .entry(connection_id.to_string())
                .or_default()
                .entry(table.to_owned())
                .or_default()
                .insert(column.to_owned(), width);
            cache.clone()
        };
        self.inner.writer.put(snapshot);
    }

    /// Drops everything for a connection the user deleted, so the file
    /// does not grow with entries nothing can reach.
    pub fn forget_connection(&self, connection_id: Uuid) {
        let snapshot = {
            let mut cache = self.inner.cache.borrow_mut();
            if cache.remove(&connection_id.to_string()).is_none() {
                return;
            }
            cache.clone()
        };
        self.inner.writer.put(snapshot);
    }
}

fn read(path: &std::path::Path) -> Connections {
    let Ok(bytes) = std::fs::read(path) else {
        return HashMap::new();
    };
    match serde_json::from_slice(&bytes) {
        Ok(widths) => widths,
        Err(error) => {
            // Starting over loses remembered widths, which the user can
            // redo by dragging. Refusing to start would not be.
            tracing::warn!(%error, path = %path.display(), "unreadable column widths; starting fresh");
            HashMap::new()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::paused_tasks;

    fn store(root: &tempfile::TempDir) -> ColumnWidthStore {
        let paths = StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.TablePro.Devel");
        ColumnWidthStore::load(&paths, &paused_tasks())
    }

    #[tokio::test]
    async fn record_then_width_answers_without_reading_the_disk() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root);
        let id = Uuid::new_v4();

        store.record(id, "users", "name", 240);

        assert_eq!(store.width(id, "users", "name"), Some(240));
        assert_eq!(store.width(id, "users", "email"), None);
        assert_eq!(store.width(Uuid::new_v4(), "users", "name"), None);
    }

    #[tokio::test]
    async fn a_non_positive_width_is_not_recorded() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root);
        let id = Uuid::new_v4();

        store.record(id, "users", "name", 240);
        store.record(id, "users", "name", 0);
        store.record(id, "users", "name", -1);

        assert_eq!(
            store.width(id, "users", "name"),
            Some(240),
            "an unrealized column overwrote a real width"
        );
    }

    #[tokio::test]
    async fn forget_connection_drops_only_that_connection() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root);
        let kept = Uuid::new_v4();
        let dropped = Uuid::new_v4();
        store.record(kept, "users", "name", 100);
        store.record(dropped, "users", "name", 200);

        store.forget_connection(dropped);

        assert_eq!(store.width(kept, "users", "name"), Some(100));
        assert_eq!(store.width(dropped, "users", "name"), None);
    }

    #[tokio::test]
    async fn a_recorded_width_reaches_the_file() {
        let root = tempfile::tempdir().expect("tempdir");
        let paths = StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.TablePro.Devel");
        let store = ColumnWidthStore::load(&paths, &paused_tasks());
        let id = Uuid::new_v4();
        let path = paths.column_widths_file();

        store.record(id, "users", "name", 240);

        let on_disk = read_when_written(&path).await;
        assert_eq!(on_disk[&id.to_string()]["users"]["name"], 240);
    }

    /// The write runs on a blocking thread, so the file appears a
    /// moment after `record` returns. `file_set_contents_full` renames
    /// into place, so a file that exists is complete.
    async fn read_when_written(path: &std::path::Path) -> Connections {
        for _ in 0..500 {
            if let Ok(bytes) = std::fs::read(path) {
                return serde_json::from_slice(&bytes).expect("the writer produced valid json");
            }
            tokio::time::sleep(std::time::Duration::from_millis(2)).await;
        }
        panic!("nothing was written to {}", path.display());
    }

    #[tokio::test]
    async fn an_unreadable_file_starts_fresh() {
        let root = tempfile::tempdir().expect("tempdir");
        let paths = StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.TablePro.Devel");
        let path = paths.column_widths_file();
        std::fs::create_dir_all(path.parent().expect("parent")).expect("create");
        std::fs::write(&path, b"{ not json").expect("seed");

        let store = ColumnWidthStore::load(&paths, &paused_tasks());

        assert_eq!(store.width(Uuid::new_v4(), "users", "name"), None);
    }
}
