use tablepro_session::runtime::Tasks;
use uuid::Uuid;

use super::ColumnLayoutStore;

/// The widths the user dragged, remembered per connection, schema and
/// table. It reads and writes the widths of the layouts in the same file,
/// so a width and the rest of a table's layout never overwrite each other.
#[derive(Clone)]
pub struct ColumnWidthStore {
    layouts: ColumnLayoutStore,
}

impl ColumnWidthStore {
    pub fn load(path: std::path::PathBuf, tasks: &Tasks) -> Self {
        Self {
            layouts: ColumnLayoutStore::load(path, tasks),
        }
    }

    /// The layouts this store keeps the widths of, for a grid that keeps a
    /// table's whole layout.
    pub fn layouts(&self) -> &ColumnLayoutStore {
        &self.layouts
    }

    pub fn width(&self, connection_id: Uuid, schema: Option<&str>, table: &str, column: &str) -> Option<i32> {
        self.layouts.read(connection_id, schema, table, |layout| {
            layout.and_then(|layout| layout.widths.get(column).copied())
        })
    }

    /// A non-positive width is what an unrealized column reports, and
    /// an unchanged one has nothing to save.
    pub fn record(&self, connection_id: Uuid, schema: Option<&str>, table: &str, column: &str, width: i32) {
        if width <= 0 {
            return;
        }
        self.layouts.change(connection_id, schema, table, |layout| {
            layout.widths.insert(column.to_owned(), width) != Some(width)
        });
    }

    /// Drop the column's width, so it opens at its default again.
    pub fn forget(&self, connection_id: Uuid, schema: Option<&str>, table: &str, column: &str) {
        self.layouts.change(connection_id, schema, table, |layout| {
            layout.widths.remove(column).is_some()
        });
    }

    /// Drop everything for a connection the user deleted, so the file
    /// does not grow with entries nothing can reach.
    pub fn forget_connection(&self, connection_id: Uuid) {
        self.layouts.forget_connection(connection_id);
    }

    pub fn flush(&self) -> impl Future<Output = ()> + Send + use<> {
        self.layouts.flush()
    }
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
    async fn forget_drops_one_column() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root);
        let id = Uuid::new_v4();
        store.record(id, Some("public"), "users", "name", 240);
        store.record(id, Some("public"), "users", "email", 180);

        store.forget(id, Some("public"), "users", "name");
        store.forget(id, Some("public"), "orders", "name");

        assert_eq!(store.width(id, Some("public"), "users", "name"), None);
        assert_eq!(store.width(id, Some("public"), "users", "email"), Some(180));
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

    #[tokio::test]
    async fn a_width_merges_into_the_tables_layout() {
        use crate::services::grid::{ColumnLayout, LayoutSlot};

        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root);
        let id = Uuid::new_v4();
        let arranged = ColumnLayout::default()
            .with_order(vec![LayoutSlot::Column("email".to_owned()), LayoutSlot::RowNumbers])
            .with_hidden("secret", true);
        store.layouts().save(id, None, "users", &arranged);

        store.record(id, None, "users", "email", 200);
        store.forget(id, None, "users", "missing");

        assert_eq!(
            store.layouts().layout(id, None, "users"),
            arranged.with_width("email", 200),
            "the order and the hidden column stay"
        );
    }
}
