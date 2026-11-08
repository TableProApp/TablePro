use tablepro_session::SessionKey;
use uuid::Uuid;

use crate::workspace::WorkspaceFileName;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct TableStateKey(String);

impl TableStateKey {
    pub fn for_session(session: &SessionKey) -> Self {
        Self(WorkspaceFileName::for_key(session).storage_key().to_owned())
    }

    pub(super) fn as_str(&self) -> &str {
        &self.0
    }

    pub(super) fn belongs_to(stored: &str, connection_id: Uuid) -> bool {
        stored == connection_id.to_string() || stored.starts_with(&WorkspaceFileName::databases_prefix(connection_id))
    }
}

impl From<Uuid> for TableStateKey {
    fn from(id: Uuid) -> Self {
        Self::for_session(&SessionKey::Saved(id))
    }
}

impl From<&TableStateKey> for TableStateKey {
    fn from(key: &TableStateKey) -> Self {
        key.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn saved_keys_keep_their_spelling_and_other_sessions_do_not_collide() {
        let id = Uuid::new_v4();
        let saved = TableStateKey::from(id);
        let sibling = TableStateKey::for_session(&SessionKey::SavedIn {
            id,
            database: "other".into(),
        });
        let file = TableStateKey::for_session(&SessionKey::File("file:///tmp/data.sqlite".into()));
        assert_eq!(saved.as_str(), id.to_string());
        assert_ne!(saved, sibling);
        assert_ne!(saved, file);
        assert_ne!(sibling, file);
        assert!(TableStateKey::belongs_to(saved.as_str(), id));
        assert!(TableStateKey::belongs_to(sibling.as_str(), id));
        assert!(!TableStateKey::belongs_to(file.as_str(), id));
        assert!(!TableStateKey::belongs_to(sibling.as_str(), Uuid::new_v4()));
    }
}

#[cfg(test)]
mod persistence_tests {
    use super::*;
    use crate::persistence::{ColumnLayoutStore, FilterSettingsStore, HighlightRulesStore};
    use crate::services::grid::{ColumnLayout, HighlightRule};
    use crate::test_support::paused_tasks;
    use tablepro_core::{FilterOp, FilterRule, FilterSet, FilterValue};

    fn filter(value: &str) -> FilterSet {
        FilterSet {
            rules: vec![FilterRule {
                column: "status".to_owned(),
                op: FilterOp::Eq,
                value: Some(FilterValue::Single(value.to_owned())),
            }],
            ..FilterSet::default()
        }
    }

    fn keys(id: Uuid) -> Vec<SessionKey> {
        vec![
            SessionKey::Saved(id),
            SessionKey::SavedIn {
                id,
                database: "first".to_owned(),
            },
            SessionKey::SavedIn {
                id,
                database: "second".to_owned(),
            },
            SessionKey::File("file:///tmp/first.sqlite".to_owned()),
            SessionKey::File("file:///tmp/second.sqlite".to_owned()),
            SessionKey::Saved(Uuid::new_v4()),
        ]
    }

    #[tokio::test]
    async fn each_session_keeps_all_table_state_across_reopening_the_stores() {
        let root = tempfile::tempdir().expect("tempdir");
        let tasks = paused_tasks();
        let layout_path = root.path().join("layouts.json");
        let filter_path = root.path().join("filters.json");
        let rules_path = root.path().join("rules.json");
        let layouts = ColumnLayoutStore::load(layout_path.clone(), &tasks);
        let filters = FilterSettingsStore::load(filter_path.clone(), &tasks);
        let highlights = HighlightRulesStore::load(rules_path.clone(), &tasks);
        let sessions = keys(Uuid::new_v4());
        let rules: Vec<_> = sessions
            .iter()
            .enumerate()
            .map(|(index, _)| {
                let mut rule = HighlightRule::new("status");
                rule.value = Some(FilterValue::Single(index.to_string()));
                rule
            })
            .collect();
        for (index, session) in sessions.iter().enumerate() {
            let key = TableStateKey::for_session(session);
            layouts.save(
                &key,
                Some("public"),
                "orders",
                &ColumnLayout::default().with_width("status", 100 + index as i32),
            );
            filters.set_filters(&key, Some("public"), "orders", filter(&index.to_string()));
            highlights.set_rules(&key, Some("public"), "orders", vec![rules[index].clone()]);
        }
        layouts.flush().await.expect("layouts saved");
        filters.flush().await.expect("filters saved");
        highlights.flush().await.expect("rules saved");
        drop((layouts, filters, highlights));
        let layouts = ColumnLayoutStore::load(layout_path, &tasks);
        let filters = FilterSettingsStore::load(filter_path, &tasks);
        let highlights = HighlightRulesStore::load(rules_path, &tasks);
        for (index, session) in sessions.iter().enumerate() {
            let key = TableStateKey::for_session(session);
            assert_eq!(
                layouts.layout(&key, Some("public"), "orders"),
                ColumnLayout::default().with_width("status", 100 + index as i32)
            );
            assert_eq!(
                filters.filters(&key, Some("public"), "orders"),
                filter(&index.to_string())
            );
            assert_eq!(highlights.rules(&key, Some("public"), "orders"), [rules[index].clone()]);
            assert!(highlights.rules(&key, Some("audit"), "orders").is_empty());
            assert!(highlights.rules(&key, Some("public"), "users").is_empty());
        }
    }

    #[tokio::test]
    async fn deletion_purges_sibling_databases_from_all_table_state_files() {
        let root = tempfile::tempdir().expect("tempdir");
        let tasks = paused_tasks();
        let layout_path = root.path().join("layouts.json");
        let filter_path = root.path().join("filters.json");
        let rules_path = root.path().join("rules.json");
        let layouts = ColumnLayoutStore::load(layout_path.clone(), &tasks);
        let filters = FilterSettingsStore::load(filter_path.clone(), &tasks);
        let highlights = HighlightRulesStore::load(rules_path.clone(), &tasks);
        let dropped = Uuid::new_v4();
        let sessions = keys(dropped);
        for session in &sessions {
            let key = TableStateKey::for_session(session);
            layouts.save(&key, None, "orders", &ColumnLayout::default().with_width("status", 100));
            filters.set_filters(&key, None, "orders", filter("open"));
            highlights.set_rules(&key, None, "orders", vec![HighlightRule::new("status")]);
        }
        layouts.forget_connection(dropped);
        filters.forget_connection(dropped);
        highlights.forget_connection(dropped);
        layouts.flush().await.expect("layouts purged");
        filters.flush().await.expect("filters purged");
        highlights.flush().await.expect("rules purged");
        drop((layouts, filters, highlights));
        let layouts = ColumnLayoutStore::load(layout_path, &tasks);
        let filters = FilterSettingsStore::load(filter_path, &tasks);
        let highlights = HighlightRulesStore::load(rules_path, &tasks);
        for (index, session) in sessions.iter().enumerate() {
            let key = TableStateKey::for_session(session);
            let removed = index < 3;
            assert_eq!(layouts.layout(&key, None, "orders") == ColumnLayout::default(), removed);
            assert_eq!(filters.filters(&key, None, "orders").is_empty(), removed);
            assert_eq!(highlights.rules(&key, None, "orders").is_empty(), removed);
        }
    }
}
