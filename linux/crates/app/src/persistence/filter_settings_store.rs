use std::collections::BTreeSet;
use std::rc::Rc;

use tablepro_core::FilterSet;
use tablepro_session::runtime::Tasks;
use uuid::Uuid;

use super::filter_settings_document::FilterSettingsDocument;
use super::{StateFile, StateFileError, TableStateKey};

#[derive(Clone)]
pub struct FilterSettingsStore {
    file: Rc<StateFile<FilterSettingsDocument>>,
}

impl FilterSettingsStore {
    pub fn load(path: std::path::PathBuf, tasks: &Tasks) -> Self {
        Self {
            file: Rc::new(StateFile::load(path, tasks)),
        }
    }

    pub fn path(&self) -> &std::path::Path {
        self.file.path()
    }

    pub fn filters(&self, key: impl Into<TableStateKey>, schema: Option<&str>, table: &str) -> FilterSet {
        let key = key.into();
        self.file.read(|document| {
            document
                .connections
                .get(key.as_str())
                .and_then(|schemas| schemas.get(schema_key(schema)))
                .and_then(|tables| tables.get(table))
                .cloned()
                .unwrap_or_default()
        })
    }

    pub fn set_filters(&self, key: impl Into<TableStateKey>, schema: Option<&str>, table: &str, set: FilterSet) {
        let key = key.into();
        self.file.update(|document| match set.is_empty() {
            // Clearing a filter shrinks the file back rather than
            // leaving an empty blob behind.
            true => prune(document, &key, schema, table),
            false => {
                let slot = document
                    .connections
                    .entry(key.as_str().to_owned())
                    .or_default()
                    .entry(schema_key(schema).to_owned())
                    .or_default()
                    .entry(table.to_owned())
                    .or_default();
                if *slot == set {
                    return false;
                }
                *slot = set;
                true
            }
        });
    }

    pub fn sidebar_schemas(&self, connection_id: Uuid, database: &str) -> BTreeSet<String> {
        self.file.read(|document| {
            document
                .sidebar_schemas
                .get(&connection_id.to_string())
                .and_then(|databases| databases.get(database))
                .cloned()
                .unwrap_or_default()
        })
    }

    pub fn set_sidebar_schemas(&self, connection_id: Uuid, database: &str, kept: &BTreeSet<String>) {
        self.file.update(|document| {
            let connection = connection_id.to_string();
            if kept.is_empty() {
                let Some(databases) = document.sidebar_schemas.get_mut(&connection) else {
                    return false;
                };
                let removed = databases.remove(database).is_some();
                if databases.is_empty() {
                    document.sidebar_schemas.remove(&connection);
                }
                return removed;
            }
            let slot = document
                .sidebar_schemas
                .entry(connection)
                .or_default()
                .entry(database.to_owned())
                .or_default();
            if slot == kept {
                return false;
            }
            slot.clone_from(kept);
            true
        });
    }

    pub fn forget_connection(&self, connection_id: Uuid) {
        let connection = connection_id.to_string();
        self.file.update(|document| {
            let before = document.connections.len();
            document
                .connections
                .retain(|key, _| !TableStateKey::belongs_to(key, connection_id));
            let filters = before != document.connections.len();
            document.sidebar_schemas.remove(&connection).is_some() || filters
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
}

fn schema_key(schema: Option<&str>) -> &str {
    schema.unwrap_or("")
}

fn prune(document: &mut FilterSettingsDocument, key: &TableStateKey, schema: Option<&str>, table: &str) -> bool {
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
    use tablepro_core::{Combinator, FilterOp, FilterRule, FilterValue};

    use super::*;
    use crate::test_support::paused_tasks;

    fn sample_set() -> FilterSet {
        FilterSet {
            combinator: Combinator::Or,
            rules: vec![FilterRule {
                column: "name".into(),
                op: FilterOp::Eq,
                value: Some(FilterValue::Single("alice".into())),
            }],
            extra_sql: None,
        }
    }

    fn store(root: &tempfile::TempDir) -> FilterSettingsStore {
        FilterSettingsStore::load(root.path().join("filter-settings.json"), &paused_tasks())
    }

    #[tokio::test]
    async fn filters_are_keyed_by_schema() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root);
        let id = Uuid::new_v4();

        store.set_filters(id, Some("public"), "users", sample_set());

        assert_eq!(store.filters(id, Some("public"), "users"), sample_set());
        assert!(store.filters(id, Some("audit"), "users").is_empty());
        assert!(store.filters(id, None, "users").is_empty());
    }

    #[tokio::test]
    async fn empty_filter_set_prunes_entry() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("filter-settings.json");
        let store = FilterSettingsStore::load(path.clone(), &paused_tasks());
        let id = Uuid::new_v4();
        store.set_filters(id, Some("public"), "users", sample_set());

        store.set_filters(id, Some("public"), "users", FilterSet::default());
        store.flush().await.expect("saved");

        assert!(store.filters(id, Some("public"), "users").is_empty());
        let written = std::fs::read_to_string(&path).expect("the file");
        assert!(
            !written.contains("alice"),
            "the cleared filter stayed on disk: {written}"
        );
        assert!(!written.contains("users"), "an empty map was left behind: {written}");
    }

    #[tokio::test]
    async fn forget_connection_removes_both_maps() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root);
        let kept = Uuid::new_v4();
        let dropped = Uuid::new_v4();
        store.set_filters(kept, Some("public"), "users", sample_set());
        store.set_filters(dropped, Some("public"), "users", sample_set());

        store.forget_connection(dropped);

        assert_eq!(store.filters(kept, Some("public"), "users"), sample_set());
        assert!(store.filters(dropped, Some("public"), "users").is_empty());
    }

    #[tokio::test]
    async fn the_sidebars_schemas_are_kept_per_database_and_go_with_the_connection() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("filter-settings.json");
        let id = Uuid::new_v4();
        let kept = BTreeSet::from(["public".to_owned(), "sales".to_owned()]);
        let store = FilterSettingsStore::load(path.clone(), &paused_tasks());
        store.set_sidebar_schemas(id, "shop", &kept);
        store.set_filters(id, None, "users", sample_set());
        store.flush().await;

        let reopened = FilterSettingsStore::load(path.clone(), &paused_tasks());
        assert_eq!(reopened.sidebar_schemas(id, "shop"), kept);
        assert!(reopened.sidebar_schemas(id, "other").is_empty());

        reopened.set_sidebar_schemas(id, "shop", &BTreeSet::new());
        assert!(reopened.sidebar_schemas(id, "shop").is_empty());
        reopened.set_sidebar_schemas(id, "shop", &kept);
        reopened.forget_connection(id);
        reopened.flush().await;
        let written = std::fs::read_to_string(&path).expect("the file");
        assert!(
            !written.contains("sales"),
            "the deleted connection's schemas stayed: {written}"
        );
    }

    #[tokio::test]
    async fn a_version_1_file_keeps_its_filters_and_has_no_sidebar_filter() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("filter-settings.json");
        let id = Uuid::new_v4();
        let filter = serde_json::to_string(&sample_set()).expect("the filter");
        let written = format!(r#"{{"version": 1, "connections": {{"{id}": {{"": {{"users": {filter}}}}}}}}}"#);
        std::fs::write(&path, written).expect("the old file");

        let store = FilterSettingsStore::load(path, &paused_tasks());

        assert_eq!(store.filters(id, None, "users"), sample_set());
        assert!(store.sidebar_schemas(id, "").is_empty());
    }

    #[tokio::test]
    async fn a_saved_filter_survives_a_reopen() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("filter-settings.json");
        let id = Uuid::new_v4();
        let store = FilterSettingsStore::load(path.clone(), &paused_tasks());
        store.set_filters(id, None, "users", sample_set());
        store.flush().await.expect("saved");

        let reopened = FilterSettingsStore::load(path, &paused_tasks());

        assert_eq!(reopened.filters(id, None, "users"), sample_set());
    }
}
