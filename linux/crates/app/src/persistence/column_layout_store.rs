use std::rc::Rc;

use tablepro_session::runtime::Tasks;
use uuid::Uuid;

use super::column_layouts_document::ColumnLayoutsDocument;
use super::{StateFile, StateFileError, TableStateKey};
use crate::services::grid::ColumnLayout;

#[derive(Clone)]
pub struct ColumnLayoutStore {
    file: Rc<StateFile<ColumnLayoutsDocument>>,
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

    pub fn path(&self) -> &std::path::Path {
        self.file.path()
    }

    pub fn layout(&self, key: impl Into<TableStateKey>, schema: Option<&str>, table: &str) -> ColumnLayout {
        self.read(&key.into(), schema, table, |layout| layout.cloned().unwrap_or_default())
    }

    pub fn save(&self, key: impl Into<TableStateKey>, schema: Option<&str>, table: &str, layout: &ColumnLayout) {
        self.change(&key.into(), schema, table, |stored| {
            if stored == layout {
                return false;
            }
            stored.clone_from(layout);
            true
        });
    }

    pub fn forget_connection(&self, connection_id: Uuid) {
        self.file.update(|document| {
            let before = document.connections.len();
            document
                .connections
                .retain(|key, _| !TableStateKey::belongs_to(key, connection_id));
            before != document.connections.len()
        });
    }

    pub fn failing(&self) -> tokio::sync::watch::Receiver<bool> {
        self.file.failing()
    }

    pub fn revision(&self) -> u64 {
        self.file.revision()
    }

    pub fn has_unsaved_changes(&self) -> bool {
        self.file.has_unsaved_changes()
    }

    pub fn current_error(&self) -> Option<StateFileError> {
        self.file.current_error()
    }

    pub fn retry(&self) -> bool {
        self.file.retry()
    }

    pub fn flush(&self) -> impl Future<Output = Result<(), StateFileError>> + Send + use<> {
        self.file.flush()
    }

    fn read<R>(
        &self,
        key: &TableStateKey,
        schema: Option<&str>,
        table: &str,
        with: impl FnOnce(Option<&ColumnLayout>) -> R,
    ) -> R {
        self.file.read(|document| {
            with(
                document
                    .connections
                    .get(key.as_str())
                    .and_then(|schemas| schemas.get(schema_key(schema)))
                    .and_then(|tables| tables.get(table)),
            )
        })
    }

    fn change(
        &self,
        key: &TableStateKey,
        schema: Option<&str>,
        table: &str,
        change: impl FnOnce(&mut ColumnLayout) -> bool,
    ) {
        let mut layout = self.layout(key, schema, table);
        if !change(&mut layout) {
            return;
        }
        self.file.update(|document| match layout == ColumnLayout::default() {
            true => prune(document, key, schema, table),
            false => {
                document
                    .connections
                    .entry(key.as_str().to_owned())
                    .or_default()
                    .entry(schema_key(schema).to_owned())
                    .or_default()
                    .insert(table.to_owned(), layout);
                true
            }
        });
    }
}

fn schema_key(schema: Option<&str>) -> &str {
    schema.unwrap_or("")
}

fn prune(document: &mut ColumnLayoutsDocument, key: &TableStateKey, schema: Option<&str>, table: &str) -> bool {
    let connection_key = key.as_str();
    let Some(schemas) = document.connections.get_mut(connection_key) else {
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
        document.connections.remove(connection_key);
    }
    removed
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::grid::LayoutSlot;
    use crate::test_support::{paused_tasks, read_text_file};

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
    async fn a_saved_layout_survives_a_reopen() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("column_layouts.json");
        let id = Uuid::new_v4();
        let store = store_at(&path);

        store.save(id, Some("public"), "users", &arranged());
        store.flush().await.expect("saved");
        let reopened = store_at(&path);

        assert_eq!(reopened.layout(id, Some("public"), "users"), arranged());
        assert_eq!(reopened.layout(id, None, "users"), ColumnLayout::default());
    }

    #[tokio::test]
    async fn a_save_replaces_one_tables_layout_and_leaves_the_rest() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store_at(&root.path().join("column_layouts.json"));
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
        let path = root.path().join("column_layouts.json");
        let store = store_at(&path);
        let id = Uuid::new_v4();
        store.save(id, Some("public"), "users", &arranged());

        store.save(id, Some("public"), "users", &ColumnLayout::default());
        store.flush().await.expect("saved");

        assert!(
            !read_text_file(&path).contains(&id.to_string()),
            "a reset left the connection's map in the file"
        );
    }

    #[tokio::test]
    async fn forget_connection_drops_only_that_connection() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store_at(&root.path().join("column_layouts.json"));
        let kept = Uuid::new_v4();
        let dropped = Uuid::new_v4();
        store.save(kept, None, "users", &arranged());
        store.save(dropped, None, "users", &arranged());

        store.forget_connection(dropped);

        assert_eq!(store.layout(kept, None, "users"), arranged());
        assert_eq!(store.layout(dropped, None, "users"), ColumnLayout::default());
    }
}
