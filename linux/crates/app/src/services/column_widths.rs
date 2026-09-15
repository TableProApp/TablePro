use std::collections::HashMap;
use std::sync::Mutex;

use uuid::Uuid;

type Widths = HashMap<String, i32>;
type Tables = HashMap<String, Widths>;
type Connections = HashMap<String, Tables>;

static CACHE: Mutex<Option<Connections>> = Mutex::new(None);

pub fn load(connection_id: Uuid, table: &str, column: &str) -> Option<i32> {
    let mut guard = CACHE.lock().ok()?;
    let map = guard.get_or_insert_with(load_from_disk);
    map.get(&connection_id.to_string())?.get(table)?.get(column).copied()
}

pub fn save(connection_id: Uuid, table: &str, column: &str, width: i32) {
    let mut guard = match CACHE.lock() {
        Ok(g) => g,
        Err(_) => return,
    };
    let map = guard.get_or_insert_with(load_from_disk);
    map.entry(connection_id.to_string())
        .or_default()
        .entry(table.to_string())
        .or_default()
        .insert(column.to_string(), width);
    let snapshot = map.clone();
    drop(guard);
    // Column resize fires this rapidly during a drag; using `relm4::spawn`
    // shares the existing tokio runtime instead of creating a fresh OS
    // thread per width change.
    relm4::spawn(async move {
        if let Some(path) = super::paths().map(|paths| paths.column_widths_file()) {
            super::write_json(&path, &snapshot, "column widths");
        }
    });
}

fn load_from_disk() -> Connections {
    let Some(path) = super::paths().map(|paths| paths.column_widths_file()) else {
        return HashMap::new();
    };
    let Ok(bytes) = std::fs::read(path) else {
        return HashMap::new();
    };
    serde_json::from_slice(&bytes).unwrap_or_default()
}
