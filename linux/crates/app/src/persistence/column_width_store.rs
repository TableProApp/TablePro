use std::rc::Rc;

use tablepro_session::runtime::Tasks;
use uuid::Uuid;

use super::StateFile;
use super::column_widths_document::ColumnWidthsDocument;

/// The widths the user dragged, remembered per connection, schema and
/// table.
#[derive(Clone)]
pub struct ColumnWidthStore {
    file: Rc<StateFile<ColumnWidthsDocument>>,
}

impl ColumnWidthStore {
    pub fn load(path: std::path::PathBuf, tasks: &Tasks) -> Self {
        Self {
            file: Rc::new(StateFile::load(path, tasks)),
        }
    }

    pub fn width(&self, connection_id: Uuid, schema: Option<&str>, table: &str, column: &str) -> Option<i32> {
        self.file.read(|document| {
            document
                .connections
                .get(&connection_id.to_string())?
                .get(schema_key(schema))?
                .get(table)?
                .get(column)
                .copied()
        })
    }

    /// A non-positive width is what an unrealized column reports, and
    /// an unchanged one has nothing to save.
    pub fn record(&self, connection_id: Uuid, schema: Option<&str>, table: &str, column: &str, width: i32) {
        if width <= 0 {
            return;
        }
        self.file.update(|document| {
            let slot = document
                .connections
                .entry(connection_id.to_string())
                .or_default()
                .entry(schema_key(schema).to_owned())
                .or_default()
                .entry(table.to_owned())
                .or_default()
                .entry(column.to_owned())
                .or_default();
            if *slot == width {
                return false;
            }
            *slot = width;
            true
        });
    }

    /// Drop everything for a connection the user deleted, so the file
    /// does not grow with entries nothing can reach.
    pub fn forget_connection(&self, connection_id: Uuid) {
        self.file
            .update(|document| document.connections.remove(&connection_id.to_string()).is_some());
    }

    pub fn flush(&self) -> impl Future<Output = ()> + Send + use<> {
        self.file.flush()
    }
}

/// `None` is stored as the empty string so every JSON key is concrete.
fn schema_key(schema: Option<&str>) -> &str {
    schema.unwrap_or("")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::paused_tasks;

    fn store(root: &tempfile::TempDir) -> ColumnWidthStore {
        ColumnWidthStore::load(root.path().join("column-widths.json"), &paused_tasks())
    }

    #[tokio::test]
    async fn widths_keyed_by_schema() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root);
        let id = Uuid::new_v4();

        store.record(id, Some("public"), "users", "name", 240);
        store.record(id, Some("audit"), "users", "name", 90);

        assert_eq!(store.width(id, Some("public"), "users", "name"), Some(240));
        assert_eq!(store.width(id, Some("audit"), "users", "name"), Some(90));
        assert_eq!(store.width(id, None, "users", "name"), None);
    }

    #[tokio::test]
    async fn record_ignores_non_positive_and_unchanged_widths() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root);
        let id = Uuid::new_v4();
        store.record(id, None, "users", "name", 240);

        store.record(id, None, "users", "name", 0);
        store.record(id, None, "users", "name", -1);
        store.record(id, None, "users", "name", 240);
        store.flush().await;

        assert_eq!(store.width(id, None, "users", "name"), Some(240));
    }

    #[tokio::test]
    async fn forget_connection_removes_the_map() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root);
        let kept = Uuid::new_v4();
        let dropped = Uuid::new_v4();
        store.record(kept, None, "users", "name", 100);
        store.record(dropped, None, "users", "name", 200);

        store.forget_connection(dropped);

        assert_eq!(store.width(kept, None, "users", "name"), Some(100));
        assert_eq!(store.width(dropped, None, "users", "name"), None);
    }

    #[tokio::test]
    async fn a_recorded_width_survives_a_reopen() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("column-widths.json");
        let id = Uuid::new_v4();
        let store = ColumnWidthStore::load(path.clone(), &paused_tasks());
        store.record(id, Some("public"), "users", "name", 240);
        store.flush().await;

        let reopened = ColumnWidthStore::load(path, &paused_tasks());

        assert_eq!(reopened.width(id, Some("public"), "users", "name"), Some(240));
    }
}
