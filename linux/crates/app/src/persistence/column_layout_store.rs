use std::rc::Rc;

use tablepro_session::runtime::Tasks;
use uuid::Uuid;

use super::StateFile;
use super::column_widths_document::ColumnWidthsDocument;
use crate::services::grid::ColumnLayout;

/// Each table's column order, hidden columns and widths, remembered per
/// connection, schema and table.
#[derive(Clone)]
pub struct ColumnLayoutStore {
    file: Rc<StateFile<ColumnWidthsDocument>>,
}

impl std::fmt::Debug for ColumnLayoutStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ColumnLayoutStore").finish_non_exhaustive()
    }
}

impl ColumnLayoutStore {
    pub fn load(path: std::path::PathBuf, tasks: &Tasks) -> Self {
        Self {
            file: Rc::new(StateFile::load(path, tasks)),
        }
    }

    pub fn layout(&self, connection_id: Uuid, schema: Option<&str>, table: &str) -> ColumnLayout {
        self.read(connection_id, schema, table, |layout| {
            layout.cloned().unwrap_or_default()
        })
    }

    /// Keep `layout` as the table's whole layout. The grid merges what it
    /// shows into the stored layout before it saves.
    pub fn save(&self, connection_id: Uuid, schema: Option<&str>, table: &str, layout: &ColumnLayout) {
        self.change(connection_id, schema, table, |stored| {
            if stored == layout {
                return false;
            }
            stored.clone_from(layout);
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

    pub(super) fn read<R>(
        &self,
        connection_id: Uuid,
        schema: Option<&str>,
        table: &str,
        with: impl FnOnce(Option<&ColumnLayout>) -> R,
    ) -> R {
        self.file.read(|document| {
            with(
                document
                    .connections
                    .get(&connection_id.to_string())
                    .and_then(|schemas| schemas.get(schema_key(schema)))
                    .and_then(|tables| tables.get(table)),
            )
        })
    }

    /// Change one table's layout. `change` returns whether anything moved.
    /// A layout left with nothing in it is removed with any map it empties,
    /// so a reset shrinks the file back.
    pub(super) fn change(
        &self,
        connection_id: Uuid,
        schema: Option<&str>,
        table: &str,
        change: impl FnOnce(&mut ColumnLayout) -> bool,
    ) {
        let mut layout = self.layout(connection_id, schema, table);
        if !change(&mut layout) {
            return;
        }
        self.file.update(|document| match layout == ColumnLayout::default() {
            true => prune(document, connection_id, schema, table),
            false => {
                document
                    .connections
                    .entry(connection_id.to_string())
                    .or_default()
                    .entry(schema_key(schema).to_owned())
                    .or_default()
                    .insert(table.to_owned(), layout);
                true
            }
        });
    }
}

/// `None` is stored as the empty string so every JSON key is concrete.
fn schema_key(schema: Option<&str>) -> &str {
    schema.unwrap_or("")
}

fn prune(document: &mut ColumnWidthsDocument, connection_id: Uuid, schema: Option<&str>, table: &str) -> bool {
    let connection_key = connection_id.to_string();
    let Some(schemas) = document.connections.get_mut(&connection_key) else {
        return false;
    };
    let mut removed = false;
    if let Some(tables) = schemas.get_mut(schema_key(schema)) {
        removed = tables.remove(table).is_some();
        if tables.is_empty() {
            schemas.remove(schema_key(schema));
        }
    }
    if schemas.is_empty() {
        document.connections.remove(&connection_key);
    }
    removed
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::grid::LayoutSlot;
    use crate::test_support::{paused_tasks, read_text_file, write_text_file};

    fn store_at(path: &std::path::Path) -> ColumnLayoutStore {
        ColumnLayoutStore::load(path.to_path_buf(), &paused_tasks())
    }

    fn arranged() -> ColumnLayout {
        ColumnLayout::default()
            .with_order(vec![
                LayoutSlot::Column("email".to_owned()),
                LayoutSlot::RowNumbers,
                LayoutSlot::Column("id".to_owned()),
            ])
            .with_hidden("secret", true)
            .with_width("email", 220)
    }

    #[tokio::test]
    async fn a_version_1_file_opens_with_its_widths() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("column_widths.json");
        let id = Uuid::new_v4();
        write_text_file(
            &path,
            &format!(r#"{{"version": 1, "connections": {{"{id}": {{"public": {{"users": {{"name": 240}}}}}}}}}}"#),
        );

        let store = store_at(&path);

        assert_eq!(
            store.layout(id, Some("public"), "users"),
            ColumnLayout::default().with_width("name", 240)
        );
        assert!(
            read_text_file(&path).contains("\"version\": 1"),
            "a read rewrites nothing"
        );
        store.save(id, Some("public"), "users", &arranged());
        store.flush().await;
        assert!(
            read_text_file(&path).contains("\"version\": 2"),
            "the next save writes version 2"
        );
    }

    #[tokio::test]
    async fn a_saved_layout_survives_a_reopen() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("column_widths.json");
        let id = Uuid::new_v4();
        let store = store_at(&path);

        store.save(id, Some("public"), "users", &arranged());
        store.flush().await;
        let reopened = store_at(&path);

        assert_eq!(reopened.layout(id, Some("public"), "users"), arranged());
        assert_eq!(reopened.layout(id, None, "users"), ColumnLayout::default());
    }

    #[tokio::test]
    async fn a_save_replaces_one_tables_layout_and_leaves_the_rest() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store_at(&root.path().join("column_widths.json"));
        let id = Uuid::new_v4();
        store.save(id, Some("public"), "users", &arranged());
        store.save(
            id,
            Some("audit"),
            "users",
            &ColumnLayout::default().with_width("id", 60),
        );

        let narrower = ColumnLayout::default().with_width("email", 90);
        store.save(id, Some("public"), "users", &narrower);

        assert_eq!(
            store.layout(id, Some("public"), "users"),
            narrower,
            "the store keeps what it is given"
        );
        assert_eq!(
            store.layout(id, Some("audit"), "users"),
            ColumnLayout::default().with_width("id", 60)
        );
    }

    #[tokio::test]
    async fn an_empty_layout_removes_the_entry() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("column_widths.json");
        let store = store_at(&path);
        let id = Uuid::new_v4();
        store.save(id, Some("public"), "users", &arranged());

        store.save(id, Some("public"), "users", &ColumnLayout::default());
        store.flush().await;

        assert!(
            !read_text_file(&path).contains(&id.to_string()),
            "a reset left the connection's map in the file"
        );
    }

    #[tokio::test]
    async fn forget_connection_drops_only_that_connection() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store_at(&root.path().join("column_widths.json"));
        let kept = Uuid::new_v4();
        let dropped = Uuid::new_v4();
        store.save(kept, None, "users", &arranged());
        store.save(dropped, None, "users", &arranged());

        store.forget_connection(dropped);

        assert_eq!(store.layout(kept, None, "users"), arranged());
        assert_eq!(store.layout(dropped, None, "users"), ColumnLayout::default());
    }
}
