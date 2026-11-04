use std::path::{Path, PathBuf};

use tablepro_foreign_import::{ForeignAppDirs, ForeignPlatform};
use tablepro_storage::StoragePaths;

/// GLib resolves the XDG base directories, including the fallbacks
/// for an unset variable, so the app agrees with the rest of the
/// desktop about where things go.
pub fn storage_paths(dir_name: &str, app_id: &str) -> StoragePaths {
    StoragePaths {
        config: glib::user_config_dir().join(dir_name),
        state: glib::user_state_dir().join(dir_name),
        data: glib::user_data_dir().join(dir_name),
        cache: glib::user_cache_dir().join(dir_name),
        runtime: glib::user_runtime_dir().join("app").join(app_id),
    }
}

// Inside a Flatpak, GLib's XDG directories are the sandbox's own, and other apps keep their files
// in the host's, which Flatpak passes as HOST_XDG_*.
pub fn foreign_app_dirs() -> ForeignAppDirs {
    let home = glib::home_dir();
    let sandboxed = Path::new("/.flatpak-info").exists();
    let host_dir = |variable: &str, sandbox_default: PathBuf, desktop_default: PathBuf| {
        std::env::var_os(variable)
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .unwrap_or(if sandboxed { sandbox_default } else { desktop_default })
    };
    ForeignAppDirs {
        platform: ForeignPlatform::Linux,
        config: host_dir("HOST_XDG_CONFIG_HOME", home.join(".config"), glib::user_config_dir()),
        data: host_dir(
            "HOST_XDG_DATA_HOME",
            home.join(".local").join("share"),
            glib::user_data_dir(),
        ),
        home,
    }
}
