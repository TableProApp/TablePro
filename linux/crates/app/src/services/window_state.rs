use serde::{Deserialize, Serialize};

use super::config_io::{atomic_write_json, xdg_config_path};

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct WindowState {
    pub width: i32,
    pub height: i32,
    pub maximized: bool,
}

impl Default for WindowState {
    fn default() -> Self {
        Self {
            width: 1200,
            height: 760,
            maximized: false,
        }
    }
}

pub fn load() -> WindowState {
    let Some(path) = xdg_config_path("window.json") else {
        return WindowState::default();
    };
    std::fs::read(path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

pub fn save(state: WindowState) {
    let Some(path) = xdg_config_path("window.json") else {
        return;
    };
    if let Err(e) = atomic_write_json(&path, &state) {
        tracing::warn!(path = %path.display(), error = %e, "window_state: write failed");
    }
}
