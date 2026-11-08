use std::rc::Rc;

use tablepro_session::runtime::Tasks;
use uuid::Uuid;

use super::highlight_rules_document::HighlightRulesDocument;
use super::{StateFile, StateFileError, TableStateKey};
use crate::services::grid::HighlightRule;

#[derive(Clone)]
pub struct HighlightRulesStore {
    file: Rc<StateFile<HighlightRulesDocument>>,
}

impl HighlightRulesStore {
    pub fn load(path: std::path::PathBuf, tasks: &Tasks) -> Self {
        Self {
            file: Rc::new(StateFile::load(path, tasks)),
        }
    }

    pub fn path(&self) -> &std::path::Path {
        self.file.path()
    }

    pub fn rules(&self, key: impl Into<TableStateKey>, schema: Option<&str>, table: &str) -> Vec<HighlightRule> {
        let key = key.into();
        self.file.read(|document| {
            document
                .connections
                .get(key.as_str())
                .and_then(|schemas| schemas.get(schema.unwrap_or("")))
                .and_then(|tables| tables.get(table))
                .cloned()
                .unwrap_or_default()
        })
    }

    pub fn set_rules(
        &self,
        key: impl Into<TableStateKey>,
        schema: Option<&str>,
        table: &str,
        rules: Vec<HighlightRule>,
    ) {
        let key = key.into();
        self.file.update(|document| {
            let schemas = document.connections.entry(key.as_str().to_owned()).or_default();
            let schema_key = schema.unwrap_or("").to_owned();
            if rules.is_empty() {
                let removed = schemas
                    .get_mut(&schema_key)
                    .is_some_and(|tables| tables.remove(table).is_some());
                if schemas.get(&schema_key).is_some_and(|tables| tables.is_empty()) {
                    schemas.remove(&schema_key);
                }
                if schemas.is_empty() {
                    document.connections.remove(key.as_str());
                }
                return removed;
            }
            let slot = schemas
                .entry(schema_key)
                .or_default()
                .entry(table.to_owned())
                .or_default();
            if *slot == rules {
                return false;
            }
            *slot = rules;
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::paused_tasks;

    fn store(root: &tempfile::TempDir) -> HighlightRulesStore {
        HighlightRulesStore::load(root.path().join("highlight_rules.json"), &paused_tasks())
    }

    #[tokio::test]
    async fn rules_are_kept_per_table_and_schema() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root);
        let id = Uuid::new_v4();
        let rule = HighlightRule::new("status");

        store.set_rules(id, Some("public"), "orders", vec![rule.clone()]);

        assert_eq!(store.rules(id, Some("public"), "orders"), [rule]);
        assert!(store.rules(id, Some("audit"), "orders").is_empty());
        assert!(store.rules(id, Some("public"), "users").is_empty());
        assert!(store.rules(Uuid::new_v4(), Some("public"), "orders").is_empty());
    }

    #[tokio::test]
    async fn no_rules_removes_the_entry_and_a_deleted_connection_takes_its_rules() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root);
        let id = Uuid::new_v4();
        store.set_rules(id, None, "orders", vec![HighlightRule::new("status")]);
        store.set_rules(id, None, "orders", Vec::new());
        assert!(store.rules(id, None, "orders").is_empty());

        store.set_rules(id, None, "users", vec![HighlightRule::new("name")]);
        store.forget_connection(id);

        assert!(store.rules(id, None, "users").is_empty());
    }
}
