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
