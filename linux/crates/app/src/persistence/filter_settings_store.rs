use std::collections::BTreeSet;
use std::rc::Rc;

use tablepro_core::FilterSet;
use tablepro_session::runtime::Tasks;
use uuid::Uuid;

use super::StateFile;
use super::filter_settings_document::FilterSettingsDocument;

/// The filter each table was left with, remembered per connection,
/// schema and table.
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

    pub fn filters(&self, connection_id: Uuid, schema: Option<&str>, table: &str) -> FilterSet {
        self.file.read(|document| {
            document
                .connections
                .get(&connection_id.to_string())
                .and_then(|schemas| schemas.get(schema_key(schema)))
                .and_then(|tables| tables.get(table))
                .cloned()
                .unwrap_or_default()
        })
    }

    pub fn set_filters(&self, connection_id: Uuid, schema: Option<&str>, table: &str, set: FilterSet) {
        self.file.update(|document| match set.is_empty() {
            // Clearing a filter shrinks the file back rather than
            // leaving an empty blob behind.
            true => prune(document, connection_id, schema, table),
            false => {
                let slot = document
                    .connections
                    .entry(connection_id.to_string())
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

    /// Drop everything for a connection the user deleted.
    pub fn forget_connection(&self, connection_id: Uuid) {
        let connection = connection_id.to_string();
        self.file.update(|document| {
            let filters = document.connections.remove(&connection).is_some();
            document.sidebar_schemas.remove(&connection).is_some() || filters
        });
    }

    pub fn flush(&self) -> impl Future<Output = ()> + Send + use<> {
        self.file.flush()
    }
}

/// `None` is stored as the empty string so every JSON key is concrete.
fn schema_key(schema: Option<&str>) -> &str {
    schema.unwrap_or("")
}

/// Remove the entry and any map it leaves empty.
fn prune(document: &mut FilterSettingsDocument, connection_id: Uuid, schema: Option<&str>, table: &str) -> bool {
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
        store.flush().await;

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
        store.flush().await;

        let reopened = FilterSettingsStore::load(path, &paused_tasks());

        assert_eq!(reopened.filters(id, None, "users"), sample_set());
    }
}
