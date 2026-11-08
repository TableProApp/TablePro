use std::rc::Rc;

use tablepro_session::runtime::Tasks;
use uuid::Uuid;

use super::StateFile;
use super::highlight_rules_document::HighlightRulesDocument;
use crate::services::grid::HighlightRule;

/// The highlight rules each table was left with, remembered per
/// connection, schema and table, as the macOS grid keeps them.
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

    pub fn rules(&self, connection_id: Uuid, schema: Option<&str>, table: &str) -> Vec<HighlightRule> {
        self.file.read(|document| {
            document
                .connections
                .get(&connection_id.to_string())
                .and_then(|schemas| schemas.get(schema.unwrap_or("")))
                .and_then(|tables| tables.get(table))
                .cloned()
                .unwrap_or_default()
        })
    }

    pub fn set_rules(&self, connection_id: Uuid, schema: Option<&str>, table: &str, rules: Vec<HighlightRule>) {
        self.file.update(|document| {
            let schemas = document.connections.entry(connection_id.to_string()).or_default();
            let schema_key = schema.unwrap_or("").to_owned();
            if rules.is_empty() {
                // No rules shrinks the file back, as no filter does.
                let removed = schemas
                    .get_mut(&schema_key)
                    .is_some_and(|tables| tables.remove(table).is_some());
                if schemas.get(&schema_key).is_some_and(|tables| tables.is_empty()) {
                    schemas.remove(&schema_key);
                }
                if schemas.is_empty() {
                    document.connections.remove(&connection_id.to_string());
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

    /// Drop everything for a connection the user deleted.
    pub fn forget_connection(&self, connection_id: Uuid) {
        self.file
            .update(|document| document.connections.remove(&connection_id.to_string()).is_some());
    }

    pub fn flush(&self) -> impl Future<Output = ()> + Send + use<> {
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
