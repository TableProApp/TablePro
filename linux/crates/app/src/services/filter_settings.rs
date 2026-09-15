//! Per-table filters, remembered per connection, schema and table.
//!
//! The schema is part of the key so `public.users` and `audit.users` do
//! not collide on a multi-schema Postgres database. An empty
//! `FilterSet` removes its entry, so clearing a filter shrinks the file
//! back instead of leaving an empty blob behind.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use tablepro_core::FilterSet;
use tablepro_session::runtime::{LatestWinsWriter, Tasks};
use tablepro_storage::StoragePaths;
use uuid::Uuid;

type Tables = HashMap<String, FilterSet>;
type Schemas = HashMap<String, Tables>;
type Connections = HashMap<String, Schemas>;

/// Lives on the GTK thread and hands snapshots to a writer that runs
/// off it.
#[derive(Clone)]
pub struct FilterSettingsStore {
    inner: Rc<Inner>,
}

struct Inner {
    cache: RefCell<Connections>,
    writer: LatestWinsWriter<Connections>,
}

impl FilterSettingsStore {
    pub fn load(paths: &StoragePaths, tasks: &Tasks) -> Self {
        let path = paths.filter_settings_file();
        let cache = read(&path);
        let writer = LatestWinsWriter::spawn(tasks, move |filters: &Connections| {
            super::write_json(&path, filters, "filter settings");
        });
        Self {
            inner: Rc::new(Inner {
                cache: RefCell::new(cache),
                writer,
            }),
        }
    }

    pub fn filters(&self, connection_id: Uuid, schema: Option<&str>, table: &str) -> FilterSet {
        self.inner
            .cache
            .borrow()
            .get(&connection_id.to_string())
            .and_then(|schemas| schemas.get(schema_key(schema)))
            .and_then(|tables| tables.get(table))
            .cloned()
            .unwrap_or_default()
    }

    pub fn set_filters(&self, connection_id: Uuid, schema: Option<&str>, table: &str, set: FilterSet) {
        let snapshot = {
            let mut cache = self.inner.cache.borrow_mut();
            match set.is_empty() {
                true => prune(&mut cache, connection_id, schema, table),
                false => {
                    cache
                        .entry(connection_id.to_string())
                        .or_default()
                        .entry(schema_key(schema).to_owned())
                        .or_default()
                        .insert(table.to_owned(), set);
                }
            }
            cache.clone()
        };
        self.inner.writer.put(snapshot);
    }

    /// Drops everything for a connection the user deleted.
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

/// `None` is stored as the empty string so every JSON key is concrete.
fn schema_key(schema: Option<&str>) -> &str {
    schema.unwrap_or("")
}

/// Removes the entry and any map it leaves empty.
fn prune(cache: &mut Connections, connection_id: Uuid, schema: Option<&str>, table: &str) {
    let connection_key = connection_id.to_string();
    let Some(schemas) = cache.get_mut(&connection_key) else {
        return;
    };
    if let Some(tables) = schemas.get_mut(schema_key(schema)) {
        tables.remove(table);
        if tables.is_empty() {
            schemas.remove(schema_key(schema));
        }
    }
    if schemas.is_empty() {
        cache.remove(&connection_key);
    }
}

fn read(path: &std::path::Path) -> Connections {
    let Ok(bytes) = std::fs::read(path) else {
        return HashMap::new();
    };
    match serde_json::from_slice(&bytes) {
        Ok(filters) => filters,
        Err(error) => {
            tracing::warn!(%error, path = %path.display(), "unreadable filter settings; starting fresh");
            HashMap::new()
        }
    }
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
        let paths = StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.TablePro.Devel");
        FilterSettingsStore::load(&paths, &paused_tasks())
    }

    #[tokio::test]
    async fn an_unset_table_has_no_filters() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root);

        assert!(store.filters(Uuid::new_v4(), Some("public"), "users").is_empty());
    }

    #[tokio::test]
    async fn a_schemaless_table_does_not_collide_with_a_named_schema() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root);
        let id = Uuid::new_v4();

        store.set_filters(id, None, "users", sample_set());

        assert_eq!(store.filters(id, None, "users"), sample_set());
        assert!(store.filters(id, Some("public"), "users").is_empty());
    }

    #[tokio::test]
    async fn an_empty_set_removes_the_entry() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = store(&root);
        let id = Uuid::new_v4();
        store.set_filters(id, Some("public"), "users", sample_set());

        store.set_filters(id, Some("public"), "users", FilterSet::default());

        assert!(store.filters(id, Some("public"), "users").is_empty());
        assert!(
            store.inner.cache.borrow().is_empty(),
            "clearing left an empty map behind: {:?}",
            store.inner.cache.borrow()
        );
    }

    #[tokio::test]
    async fn forget_connection_drops_only_that_connection() {
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
    async fn a_saved_filter_reaches_the_file() {
        let root = tempfile::tempdir().expect("tempdir");
        let paths = StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.TablePro.Devel");
        let store = FilterSettingsStore::load(&paths, &paused_tasks());
        let id = Uuid::new_v4();
        let path = paths.filter_settings_file();

        store.set_filters(id, Some("public"), "users", sample_set());

        // The write runs on a blocking thread, so the file appears a
        // moment after `set_filters` returns.
        let on_disk: Connections = loop {
            if let Ok(bytes) = std::fs::read(&path) {
                break serde_json::from_slice(&bytes).expect("the writer produced valid json");
            }
            tokio::time::sleep(std::time::Duration::from_millis(2)).await;
        };
        assert_eq!(on_disk[&id.to_string()]["public"]["users"], sample_set());
    }

    #[tokio::test]
    async fn an_unreadable_file_starts_fresh() {
        let root = tempfile::tempdir().expect("tempdir");
        let paths = StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.TablePro.Devel");
        let path = paths.filter_settings_file();
        std::fs::create_dir_all(path.parent().expect("parent")).expect("create");
        std::fs::write(&path, b"{ not json").expect("seed");

        let store = FilterSettingsStore::load(&paths, &paused_tasks());

        assert!(store.filters(Uuid::new_v4(), Some("public"), "users").is_empty());
    }
}
