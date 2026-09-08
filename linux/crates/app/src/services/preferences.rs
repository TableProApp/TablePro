use std::sync::{Mutex, MutexGuard, OnceLock};

use serde::{Deserialize, Serialize};
use tablepro_core::export::CsvOptions;

use super::config_io::{atomic_write_json, xdg_config_path};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Preferences {
    pub default_page_size: u64,
    pub confirm_destructive: bool,
    pub editor_font_size: u32,
    #[serde(default = "default_history_retention_days")]
    pub history_retention_days: u32,
    /// Wall-clock seconds before the editor's Run cancels a query
    /// the driver hasn't returned from. `0` disables the timeout.
    /// Defaults to 60s — long enough for typical OLTP work and
    /// catalog browsing, short enough that a runaway DDL or
    /// cross-join doesn't pin the GTK main thread waiting on
    /// shutdown.
    #[serde(default = "default_query_timeout_secs")]
    pub query_timeout_secs: u32,
    #[serde(default)]
    pub csv_export: CsvOptions,
}

fn default_history_retention_days() -> u32 {
    30
}

fn default_query_timeout_secs() -> u32 {
    60
}

impl Default for Preferences {
    fn default() -> Self {
        Self {
            default_page_size: 1_000,
            confirm_destructive: true,
            editor_font_size: 12,
            history_retention_days: default_history_retention_days(),
            query_timeout_secs: default_query_timeout_secs(),
            csv_export: CsvOptions::default(),
        }
    }
}

/// The file is read once per process. This app is the only writer and
/// every write lands in `save`, so the cached copy cannot drift from
/// what is on disk. Without it a live-saving dialog reads and parses
/// the file again on every spin-button tick, on the GTK main thread.
fn cache() -> &'static Mutex<Option<Preferences>> {
    static CACHE: OnceLock<Mutex<Option<Preferences>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(None))
}

fn lock_cache() -> MutexGuard<'static, Option<Preferences>> {
    cache().lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn read_from_disk() -> Preferences {
    let Some(path) = xdg_config_path("preferences.json") else {
        return Preferences::default();
    };
    std::fs::read(path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

pub fn load() -> Preferences {
    let mut cached = lock_cache();
    if let Some(prefs) = cached.as_ref() {
        return prefs.clone();
    }
    let prefs = read_from_disk();
    *cached = Some(prefs.clone());
    prefs
}

pub fn save(prefs: &Preferences) {
    *lock_cache() = Some(prefs.clone());
    let Some(path) = xdg_config_path("preferences.json") else {
        return;
    };
    if let Err(e) = atomic_write_json(&path, prefs) {
        tracing::warn!(path = %path.display(), error = %e, "preferences: write failed");
    }
}

/// Read, change, write. A caller that owns one setting cannot drop the
/// others, which a hand-assembled `Preferences` does silently the
/// moment a field is added that the caller doesn't know about.
pub fn update(mutate: impl FnOnce(&mut Preferences)) {
    let mut prefs = load();
    mutate(&mut prefs);
    save(&prefs);
}
