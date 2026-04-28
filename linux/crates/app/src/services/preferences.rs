use serde::{Deserialize, Serialize};

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
        }
    }
}

pub fn load() -> Preferences {
    let Some(path) = xdg_config_path("preferences.json") else {
        return Preferences::default();
    };
    std::fs::read(path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

pub fn save(prefs: &Preferences) {
    let Some(path) = xdg_config_path("preferences.json") else {
        return;
    };
    if let Err(e) = atomic_write_json(&path, prefs) {
        tracing::warn!(path = %path.display(), error = %e, "preferences: write failed");
    }
}
