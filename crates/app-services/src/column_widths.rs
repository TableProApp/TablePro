use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use uuid::Uuid;

use super::config_io::xdg_config_path;
use super::state_file::StateFile;

type Connections = HashMap<String, HashMap<String, HashMap<String, i32>>>;
type HiddenColumns = HashMap<String, HashMap<String, Vec<String>>>;

pub const MIN_COLUMN_WIDTH: i32 = 24;
pub const MAX_COLUMN_WIDTH: i32 = 4000;

#[derive(Clone)]
pub struct ColumnWidthStore {
    file: Arc<StateFile<Connections>>,
    hidden: Arc<StateFile<HiddenColumns>>,
    order: Arc<StateFile<HiddenColumns>>,
}

pub fn saved_column_order(names: &[String], saved: &[String]) -> Vec<usize> {
    let mut order: Vec<usize> = Vec::with_capacity(names.len());
    for name in saved {
        let Some(index) = names.iter().position(|candidate| candidate == name) else {
            continue;
        };
        if !order.contains(&index) {
            order.push(index);
        }
    }
    let missing: Vec<usize> = (0..names.len()).filter(|index| !order.contains(index)).collect();
    order.extend(missing);
    order
}

pub fn may_hide(total: usize, already_hidden: usize) -> bool {
    total > 0 && already_hidden + 1 < total
}

impl ColumnWidthStore {
    pub fn open() -> Option<Self> {
        Some(Self::load_at(
            xdg_config_path("column_widths.json")?,
            xdg_config_path("hidden_columns.json")?,
            xdg_config_path("column_order.json")?,
        ))
    }

    pub fn load_in(dir: &std::path::Path) -> Self {
        Self::load_at(
            dir.join("column_widths.json"),
            dir.join("hidden_columns.json"),
            dir.join("column_order.json"),
        )
    }

    fn load_at(widths: std::path::PathBuf, hidden: std::path::PathBuf, order: std::path::PathBuf) -> Self {
        Self {
            file: Arc::new(StateFile::load(widths)),
            hidden: Arc::new(StateFile::load(hidden)),
            order: Arc::new(StateFile::load(order)),
        }
    }

    pub fn column_order(&self, connection_id: Uuid, table: &str) -> Vec<String> {
        self.order
            .read(|map| map.get(&connection_id.to_string())?.get(table).cloned())
            .flatten()
            .unwrap_or_default()
    }

    pub fn set_column_order(&self, connection_id: Uuid, table: &str, names: Vec<String>) -> Result<(), String> {
        self.order.update(|map| {
            map.entry(connection_id.to_string())
                .or_default()
                .insert(table.to_string(), names);
        })
    }

    pub fn hidden_columns(&self, connection_id: Uuid, table: &str) -> HashSet<String> {
        self.hidden
            .read(|map| {
                map.get(&connection_id.to_string())
                    .and_then(|tables| tables.get(table))
                    .map(|columns| columns.iter().cloned().collect())
            })
            .flatten()
            .unwrap_or_default()
    }

    pub fn set_hidden(&self, connection_id: Uuid, table: &str, column: &str, hidden: bool) -> Result<(), String> {
        self.hidden.update(|map| {
            let columns = map
                .entry(connection_id.to_string())
                .or_default()
                .entry(table.to_string())
                .or_default();
            columns.retain(|name| name != column);
            if hidden {
                columns.push(column.to_string());
            }
        })
    }

    pub fn load(&self, connection_id: Uuid, table: &str, column: &str) -> Option<i32> {
        self.file
            .read(|map| map.get(&connection_id.to_string())?.get(table)?.get(column).copied())
            .flatten()
            .map(|width| width.clamp(MIN_COLUMN_WIDTH, MAX_COLUMN_WIDTH))
    }

    pub fn save(&self, connection_id: Uuid, table: &str, column: &str, width: i32) -> Result<(), String> {
        self.file.update(|map| {
            map.entry(connection_id.to_string())
                .or_default()
                .entry(table.to_string())
                .or_default()
                .insert(column.to_string(), width.clamp(MIN_COLUMN_WIDTH, MAX_COLUMN_WIDTH));
        })
    }

    pub fn forget_connection(&self, connection_id: Uuid) -> Result<(), String> {
        let key = connection_id.to_string();
        self.file.update(|map| {
            map.remove(&key);
        })?;
        self.hidden.update(|map| {
            map.remove(&key);
        })?;
        self.order.update(|map| {
            map.remove(&key);
        })
    }

    pub fn flush(&self) -> Result<(), String> {
        self.file.flush()?;
        self.hidden.flush()?;
        self.order.flush()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn forgetting_a_connection_drops_its_widths_hidden_columns_and_order_only() {
        let dir = tempfile::tempdir().unwrap();
        let store = ColumnWidthStore::load_in(dir.path());
        let (gone, kept) = (Uuid::new_v4(), Uuid::new_v4());
        for id in [gone, kept] {
            store.save(id, "t", "c", 120).unwrap();
            store.set_hidden(id, "t", "c", true).unwrap();
            store.set_column_order(id, "t", vec!["c".into()]).unwrap();
        }
        store.forget_connection(gone).unwrap();
        assert_eq!(store.load(gone, "t", "c"), None);
        assert!(store.hidden_columns(gone, "t").is_empty());
        assert!(store.column_order(gone, "t").is_empty());
        assert_eq!(store.load(kept, "t", "c"), Some(120));
        assert!(store.hidden_columns(kept, "t").contains("c"));
        assert_eq!(store.column_order(kept, "t"), vec!["c".to_string()]);
    }

    #[test]
    fn separately_opened_stores_do_not_share_state() {
        let first = tempfile::tempdir().unwrap();
        let second = tempfile::tempdir().unwrap();
        let id = Uuid::new_v4();
        let first_store = store_in(&first);
        let second_store = store_in(&second);

        first_store.save(id, "users", "name", 240).unwrap();
        first_store.flush().unwrap();

        assert_eq!(first_store.load(id, "users", "name"), Some(240));
        assert_eq!(second_store.load(id, "users", "name"), None);
    }

    fn store_in(dir: &tempfile::TempDir) -> ColumnWidthStore {
        ColumnWidthStore::load_at(
            dir.path().join("widths.json"),
            dir.path().join("hidden.json"),
            dir.path().join("order.json"),
        )
    }

    #[test]
    fn hidden_columns_are_remembered_per_connection_and_table() {
        let dir = tempfile::tempdir().unwrap();
        let (a, b) = (Uuid::new_v4(), Uuid::new_v4());
        let store = store_in(&dir);

        store.set_hidden(a, "users", "email", true).unwrap();

        assert!(store.hidden_columns(a, "users").contains("email"));
        assert!(store.hidden_columns(a, "orders").is_empty());
        assert!(store.hidden_columns(b, "users").is_empty());
    }

    #[test]
    fn showing_a_column_again_removes_it_from_the_hidden_set() {
        let dir = tempfile::tempdir().unwrap();
        let id = Uuid::new_v4();
        let store = store_in(&dir);
        store.set_hidden(id, "users", "email", true).unwrap();
        store.set_hidden(id, "users", "email", false).unwrap();
        assert!(store.hidden_columns(id, "users").is_empty());
    }

    #[test]
    fn hidden_columns_survive_a_restart() {
        let dir = tempfile::tempdir().unwrap();
        let id = Uuid::new_v4();
        let store = store_in(&dir);
        store.set_hidden(id, "users", "email", true).unwrap();
        store.flush().unwrap();

        let reopened = store_in(&dir);
        assert!(reopened.hidden_columns(id, "users").contains("email"));
    }

    fn names(list: &[&str]) -> Vec<String> {
        list.iter().map(|name| name.to_string()).collect()
    }

    #[test]
    fn a_saved_order_is_applied_and_unknown_or_new_columns_keep_their_place_at_the_end() {
        let current = names(&["id", "name", "email", "created"]);
        assert_eq!(saved_column_order(&current, &names(&["email", "id"])), vec![2, 0, 1, 3]);
        assert_eq!(
            saved_column_order(&current, &names(&["gone", "name", "name"])),
            vec![1, 0, 2, 3]
        );
        assert_eq!(saved_column_order(&current, &[]), vec![0, 1, 2, 3]);
    }

    #[test]
    fn a_column_order_is_remembered_per_table_and_survives_a_restart() {
        let dir = tempfile::tempdir().unwrap();
        let id = Uuid::new_v4();
        let store = store_in(&dir);
        store.set_column_order(id, "users", names(&["email", "id"])).unwrap();
        store.flush().unwrap();

        let reopened = store_in(&dir);
        assert_eq!(reopened.column_order(id, "users"), names(&["email", "id"]));
        assert!(reopened.column_order(id, "orders").is_empty());
    }

    #[test]
    fn the_last_visible_column_cannot_be_hidden() {
        assert!(may_hide(3, 1));
        assert!(!may_hide(3, 2));
        assert!(!may_hide(3, 3));
        assert!(!may_hide(1, 0));
        assert!(!may_hide(0, 0));
    }
    #[test]
    fn a_width_from_a_hand_edited_or_corrupt_file_is_clamped_before_it_reaches_the_toolkit() {
        let dir = tempfile::tempdir().unwrap();
        let id = Uuid::new_v4();
        let widths = [
            ("negative", -5),
            ("zero", 0),
            ("huge", i32::MAX),
            ("min", i32::MIN),
            ("fine", 150),
        ];
        let entries: Vec<String> = widths
            .iter()
            .map(|(name, width)| format!("\"{name}\": {width}"))
            .collect();
        std::fs::write(
            dir.path().join("column_widths.json"),
            format!("{{\"{id}\": {{\"t\": {{{}}}}}}}", entries.join(", ")),
        )
        .unwrap();

        let store = ColumnWidthStore::load_in(dir.path());

        for (name, _) in widths {
            let width = store.load(id, "t", name).unwrap();
            assert!(
                (MIN_COLUMN_WIDTH..=MAX_COLUMN_WIDTH).contains(&width),
                "{name}: {width}"
            );
        }
        assert_eq!(store.load(id, "t", "fine"), Some(150));
        assert_eq!(store.load(id, "t", "negative"), Some(MIN_COLUMN_WIDTH));
        assert_eq!(store.load(id, "t", "huge"), Some(MAX_COLUMN_WIDTH));
    }

    #[test]
    fn a_width_is_clamped_when_saved_too() {
        let dir = tempfile::tempdir().unwrap();
        let store = ColumnWidthStore::load_in(dir.path());
        let id = Uuid::new_v4();
        store.save(id, "t", "c", -40).unwrap();
        store.save(id, "t", "d", i32::MAX).unwrap();
        assert_eq!(store.load(id, "t", "c"), Some(MIN_COLUMN_WIDTH));
        assert_eq!(store.load(id, "t", "d"), Some(MAX_COLUMN_WIDTH));
    }

    #[test]
    fn at_least_one_column_always_stays_visible() {
        assert!(!may_hide(0, 0));
        assert!(!may_hide(1, 0));
        assert!(may_hide(2, 0));
        assert!(!may_hide(2, 1));
        assert!(may_hide(5, 3));
        assert!(!may_hide(5, 4));
    }

    #[test]
    fn open_follows_the_config_directory_environment() {
        let configured = std::env::var_os("XDG_CONFIG_HOME").is_some() || std::env::var_os("HOME").is_some();
        assert_eq!(ColumnWidthStore::open().is_some(), configured);
    }

    #[test]
    fn flushing_persists_widths_hidden_columns_and_order_for_the_next_launch() {
        let dir = tempfile::tempdir().unwrap();
        let id = Uuid::new_v4();
        let store = ColumnWidthStore::load_in(dir.path());
        store.save(id, "users", "name", 240).unwrap();
        store.set_hidden(id, "users", "secret", true).unwrap();
        store
            .set_column_order(id, "users", vec!["name".into(), "id".into()])
            .unwrap();
        store.flush().unwrap();
        drop(store);
        let reopened = ColumnWidthStore::load_in(dir.path());
        assert_eq!(reopened.load(id, "users", "name"), Some(240));
        assert!(reopened.hidden_columns(id, "users").contains("secret"));
        assert_eq!(
            reopened.column_order(id, "users"),
            vec!["name".to_string(), "id".to_string()]
        );
    }
}
