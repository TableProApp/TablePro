use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;

use gtk4::gio;
use gtk4::gio::prelude::*;
use relm4::adw;
use serde::{Deserialize, Serialize};

use super::config_io::{atomic_write_bytes, atomic_write_json, xdg_config_path};
use super::state_file::StateFile;

#[cfg(test)]
const SETTINGS_SCHEMA: &str = "com.tablepro.linux";
const SETTINGS_MIGRATION_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
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
    #[serde(default = "default_csv_include_header")]
    pub csv_include_header: bool,
    #[serde(default)]
    pub color_scheme: ColorSchemePref,
    #[serde(default)]
    pub editor_font_family: String,
    #[serde(default)]
    pub editor_vim_mode: bool,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ColorSchemePref {
    #[default]
    System,
    Light,
    Dark,
}

impl ColorSchemePref {
    pub const ALL: [Self; 3] = [Self::System, Self::Light, Self::Dark];

    pub fn key(self) -> &'static str {
        match self {
            Self::System => "system",
            Self::Light => "light",
            Self::Dark => "dark",
        }
    }

    pub fn from_key(key: &str) -> Self {
        Self::ALL
            .into_iter()
            .find(|scheme| scheme.key() == key)
            .unwrap_or_default()
    }

    pub fn index(self) -> u32 {
        Self::ALL.iter().position(|scheme| *scheme == self).unwrap_or(0) as u32
    }

    pub fn from_index(index: u32) -> Self {
        Self::ALL.get(index as usize).copied().unwrap_or_default()
    }

    pub fn style(self) -> adw::ColorScheme {
        match self {
            Self::System => adw::ColorScheme::Default,
            Self::Light => adw::ColorScheme::ForceLight,
            Self::Dark => adw::ColorScheme::ForceDark,
        }
    }
}

fn default_history_retention_days() -> u32 {
    30
}

fn default_query_timeout_secs() -> u32 {
    60
}

fn default_csv_include_header() -> bool {
    true
}

impl Default for Preferences {
    fn default() -> Self {
        Self {
            default_page_size: 1_000,
            confirm_destructive: true,
            editor_font_size: 12,
            history_retention_days: default_history_retention_days(),
            query_timeout_secs: default_query_timeout_secs(),
            csv_include_header: default_csv_include_header(),
            color_scheme: ColorSchemePref::default(),
            editor_font_family: String::new(),
            editor_vim_mode: false,
        }
    }
}

/// Preferences are shared explicitly rather than through a global. GSettings
/// is canonical; the legacy JSON file remains in place as a rollback copy.
/// JSON is retained as a fallback if the installed schema is unavailable.
#[derive(Clone)]
pub struct PreferencesStore(Backend);

#[derive(Clone)]
enum Backend {
    GSettings {
        settings: Rc<gio::Settings>,
        legacy_path: Option<PathBuf>,
        migration_error: Option<String>,
    },
    Json(Arc<StateFile<Preferences>>),
}

impl Default for PreferencesStore {
    fn default() -> Self {
        Self::new()
    }
}

impl PreferencesStore {
    pub fn new() -> Self {
        let legacy_path = xdg_config_path("preferences.json");
        match open_settings() {
            Ok(settings) => Self::from_settings_with_legacy(settings, legacy_path),
            Err(error) => {
                tracing::warn!(%error, "preferences: GSettings unavailable; using JSON store");
                Self(Backend::Json(Arc::new(
                    legacy_path.map(StateFile::load).unwrap_or_else(StateFile::memory),
                )))
            }
        }
    }

    pub fn load(&self) -> Preferences {
        match &self.0 {
            Backend::GSettings { settings, .. } => read_settings(settings),
            Backend::Json(file) => file.read(Clone::clone).unwrap_or_default(),
        }
    }

    pub fn update(&self, mutate: impl FnOnce(&mut Preferences)) -> Result<(), String> {
        match &self.0 {
            Backend::GSettings {
                settings,
                legacy_path,
                migration_error,
            } => {
                if let Some(error) = migration_error {
                    return Err(format!("legacy preferences need recovery before editing: {error}"));
                }
                let settings = settings.as_ref();
                let previous = read_settings(settings);
                let mut updated = previous.clone();
                mutate(&mut updated);
                write_settings(settings, &updated)?;
                gio::Settings::sync();
                if let Some(path) = legacy_path
                    && let Err(error) = atomic_write_json(path, &updated)
                {
                    if let Err(rollback_error) = write_settings(settings, &previous) {
                        tracing::error!(%rollback_error, "preferences: failed to roll back GSettings after legacy mirror failure");
                    }
                    gio::Settings::sync();
                    return Err(format!("legacy preferences mirror failed: {error}"));
                }
                Ok(())
            }
            Backend::Json(file) => file.update(mutate),
        }
    }

    pub fn flush(&self) -> Result<(), String> {
        match &self.0 {
            Backend::GSettings { .. } => {
                gio::Settings::sync();
                Ok(())
            }
            Backend::Json(file) => file.flush(),
        }
    }

    #[cfg(test)]
    fn from_settings(settings: gio::Settings, legacy_path: Option<PathBuf>) -> Self {
        Self(Backend::GSettings {
            settings: Rc::new(settings),
            legacy_path,
            migration_error: None,
        })
    }

    fn from_settings_with_legacy(settings: gio::Settings, legacy_path: Option<PathBuf>) -> Self {
        let migration_error = migrate_json_preferences(&settings, legacy_path.as_deref())
            .err()
            .map(|error| {
                tracing::warn!(%error, "preferences: legacy migration deferred; source retained");
                error
            });
        Self(Backend::GSettings {
            settings: Rc::new(settings),
            legacy_path,
            migration_error,
        })
    }
}

fn settings_path() -> &'static str {
    settings_path_for_profile(crate::config::profile())
}

fn settings_path_for_profile(profile: crate::config::Profile) -> &'static str {
    if profile == crate::config::Profile::Development {
        "/com/tablepro/linux/Devel/"
    } else {
        "/com/tablepro/linux/"
    }
}

pub(super) fn settings() -> Option<gio::Settings> {
    open_settings().ok()
}

fn open_settings() -> Result<gio::Settings, String> {
    let parent = gio::SettingsSchemaSource::default()
        .ok_or_else(|| "default GSettings schema source is unavailable".to_string())?;
    let local_source = Path::new(env!("TABLEPRO_GSETTINGS_SCHEMA_DIR"));
    let source = if local_source.is_dir() {
        gio::SettingsSchemaSource::from_directory(local_source, Some(&parent), false)
            .map_err(|error| error.to_string())?
    } else {
        parent.clone()
    };
    let schema = source
        .lookup(crate::config::APP_ID, true)
        .ok_or_else(|| format!("GSettings schema {} is not installed", crate::config::APP_ID))?;
    Ok(gio::Settings::new_full(
        &schema,
        None::<&gio::SettingsBackend>,
        Some(settings_path()),
    ))
}

fn read_settings(settings: &gio::Settings) -> Preferences {
    Preferences {
        default_page_size: settings.uint64("default-page-size"),
        confirm_destructive: settings.boolean("confirm-destructive"),
        editor_font_size: settings.uint("editor-font-size"),
        history_retention_days: settings.uint("history-retention-days"),
        query_timeout_secs: settings.uint("query-timeout-secs"),
        csv_include_header: settings.boolean("csv-include-header"),
        color_scheme: ColorSchemePref::from_key(settings.string("color-scheme").as_str()),
        editor_font_family: settings.string("editor-font-family").to_string(),
        editor_vim_mode: settings.boolean("editor-vim-mode"),
    }
}

fn write_settings(settings: &gio::Settings, prefs: &Preferences) -> Result<(), String> {
    settings.delay();
    let writes = [
        settings.set_uint64("default-page-size", prefs.default_page_size),
        settings.set_boolean("confirm-destructive", prefs.confirm_destructive),
        settings.set_uint("editor-font-size", prefs.editor_font_size),
        settings.set_uint("history-retention-days", prefs.history_retention_days),
        settings.set_uint("query-timeout-secs", prefs.query_timeout_secs),
        settings.set_boolean("csv-include-header", prefs.csv_include_header),
        settings.set_string("color-scheme", prefs.color_scheme.key()),
        settings.set_string("editor-font-family", &prefs.editor_font_family),
        settings.set_boolean("editor-vim-mode", prefs.editor_vim_mode),
    ];
    if let Some(error) = writes.into_iter().find_map(Result::err) {
        settings.revert();
        return Err(error.to_string());
    }
    settings.apply();
    Ok(())
}

fn migrate_json_preferences(settings: &gio::Settings, path: Option<&Path>) -> Result<(), String> {
    let version = settings.uint("migration-version");
    if version > SETTINGS_MIGRATION_VERSION {
        return Err(format!("preferences schema version {version} is newer than this build"));
    }
    if version == SETTINGS_MIGRATION_VERSION || settings.boolean("preferences-migrated") {
        sync_rollback_preferences(settings, path)?;
        return Ok(());
    }
    let legacy = match path {
        Some(path) => match std::fs::symlink_metadata(path) {
            Ok(metadata) if !metadata.file_type().is_file() => {
                return Err("legacy preferences path is not a regular file".into());
            }
            Ok(_) => {
                let bytes = std::fs::read(path).map_err(|error| error.to_string())?;
                let preferences = serde_json::from_slice::<Preferences>(&bytes).map_err(|error| error.to_string())?;
                Some((preferences, bytes, backup_path(path)?))
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(error) => return Err(error.to_string()),
        },
        None => None,
    };

    if let Some((legacy, bytes, backup)) = legacy {
        preserve_migration_backup(&backup, &bytes)?;
        write_settings(settings, &legacy)?;
        gio::Settings::sync();
        if read_settings(settings) != legacy {
            return Err("migrated preferences did not verify against GSettings".into());
        }
    }
    settings
        .set_boolean("preferences-migrated", true)
        .map_err(|error| error.to_string())?;
    settings
        .set_uint("migration-version", SETTINGS_MIGRATION_VERSION)
        .map_err(|error| error.to_string())?;
    settings.apply();
    gio::Settings::sync();
    if settings.uint("migration-version") != SETTINGS_MIGRATION_VERSION {
        return Err("GSettings migration marker did not persist".into());
    }
    Ok(())
}

fn sync_rollback_preferences(settings: &gio::Settings, path: Option<&Path>) -> Result<(), String> {
    let Some(path) = path else {
        return Ok(());
    };
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if !metadata.file_type().is_file() => {
            return Err("legacy preferences path is not a regular file".into());
        }
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.to_string()),
    }
    let bytes = std::fs::read(path).map_err(|error| error.to_string())?;
    let legacy: Preferences = serde_json::from_slice(&bytes).map_err(|error| error.to_string())?;
    if read_settings(settings) != legacy {
        write_settings(settings, &legacy)?;
        gio::Settings::sync();
        if read_settings(settings) != legacy {
            return Err("rollback preferences did not verify against GSettings".into());
        }
    }
    Ok(())
}

fn backup_path(source: &Path) -> Result<PathBuf, String> {
    if source.file_name().is_none() {
        return Err("legacy preferences path has no filename".into());
    }
    Ok(source.with_extension("before-gsettings.json"))
}

fn preserve_migration_backup(path: &Path, bytes: &[u8]) -> Result<(), String> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if !metadata.file_type().is_file() => {
            return Err("preferences rollback backup is not a regular file".into());
        }
        Ok(_) => {
            let existing = std::fs::read(path).map_err(|error| error.to_string())?;
            if existing != bytes {
                return Err("preferences rollback backup differs from the migration source".into());
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            atomic_write_bytes(path, bytes).map_err(|error| error.to_string())?;
        }
        Err(error) => return Err(error.to_string()),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn migrates_legacy_settings_and_keeps_rollback_copies() {
        if std::env::var_os("BOOKIE_SETTINGS_TEST_CHILD").is_some() {
            let path = xdg_config_path("preferences.json").unwrap();
            atomic_write_json(
                &path,
                &Preferences {
                    default_page_size: 321,
                    ..Preferences::default()
                },
            )
            .unwrap();
            let store = PreferencesStore::new();
            assert_eq!(store.load().default_page_size, 321);
            let backup = backup_path(&path).unwrap();
            assert_eq!(std::fs::read(&backup).unwrap(), std::fs::read(&path).unwrap());
            assert_eq!(std::fs::metadata(&backup).unwrap().permissions().mode() & 0o777, 0o600);
            assert_eq!(
                settings().unwrap().uint("migration-version"),
                SETTINGS_MIGRATION_VERSION
            );
            store.update(|prefs| prefs.default_page_size = 654).unwrap();
            assert_eq!(PreferencesStore::new().load().default_page_size, 654);
            assert_eq!(
                serde_json::from_slice::<Preferences>(&std::fs::read(&path).unwrap())
                    .unwrap()
                    .default_page_size,
                654
            );
            assert_eq!(
                serde_json::from_slice::<Preferences>(&std::fs::read(&backup).unwrap())
                    .unwrap()
                    .default_page_size,
                321
            );
            atomic_write_json(
                &path,
                &Preferences {
                    default_page_size: 777,
                    ..Preferences::default()
                },
            )
            .unwrap();
            assert_eq!(PreferencesStore::new().load().default_page_size, 777);
            assert_eq!(settings().unwrap().uint64("default-page-size"), 777);
            let window_path = xdg_config_path("window.json").unwrap();
            let connection_id = uuid::Uuid::new_v4();
            let old_window = super::super::window_state::WindowState {
                width: 901,
                height: 702,
                maximized: false,
                last_connection_id: Some(connection_id),
            };
            atomic_write_json(&window_path, &old_window).unwrap();
            assert_eq!(super::super::window_state::load().width, 901);
            assert_eq!(
                std::fs::read(window_path.with_extension("before-gsettings.json")).unwrap(),
                std::fs::read(&window_path).unwrap()
            );
            super::super::window_state::save_geometry(902, 703, true);
            let updated = super::super::window_state::load();
            assert_eq!(updated.last_connection_id, Some(connection_id));
            assert_eq!(updated.width, 902);
            assert_eq!(settings().unwrap().int("window-width"), 902);
            atomic_write_json(&window_path, &old_window).unwrap();
            assert_eq!(super::super::window_state::load().width, 901);
            assert_eq!(settings().unwrap().int("window-width"), 901);
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let schema = dir.path().join("com.tablepro.linux.gschema.xml");
        std::fs::copy(
            concat!(env!("CARGO_MANIFEST_DIR"), "/../../data/com.tablepro.linux.gschema.xml"),
            &schema,
        )
        .unwrap();
        assert!(
            std::process::Command::new("glib-compile-schemas")
                .arg("--strict")
                .arg(dir.path())
                .status()
                .unwrap()
                .success()
        );
        let result = std::process::Command::new(std::env::current_exe().unwrap())
            .arg("migrates_legacy_settings_and_keeps_rollback_copies")
            .env("BOOKIE_SETTINGS_TEST_CHILD", "1")
            .env("GSETTINGS_SCHEMA_DIR", dir.path())
            .env("GSETTINGS_BACKEND", "memory")
            .env("XDG_CONFIG_HOME", dir.path())
            .output()
            .unwrap();
        assert!(result.status.success(), "{}", String::from_utf8_lossy(&result.stdout));
    }

    fn make_test_settings(_path: &str) -> (gio::Settings, gio::SettingsBackend) {
        let source = gio::SettingsSchemaSource::from_directory(
            env!("TABLEPRO_GSETTINGS_SCHEMA_DIR"),
            gio::SettingsSchemaSource::default().as_ref(),
            false,
        )
        .unwrap();
        let schema = source.lookup(SETTINGS_SCHEMA, true).unwrap();
        let backend = gio::memory_settings_backend_new();
        let settings = gio::Settings::new_full(&schema, Some(&backend), None);
        (settings, backend)
    }

    #[test]
    fn gsettings_updates_are_visible_to_reopened_handles() {
        let (settings, backend) = make_test_settings("/com/tablepro/linux/test/");
        let store = PreferencesStore::from_settings(settings, None);
        store
            .update(|prefs| {
                prefs.default_page_size = 424_242;
                prefs.csv_include_header = false;
            })
            .unwrap();
        store.flush().unwrap();

        let reopened = test_settings_with_backend("/com/tablepro/linux/test/", backend);
        let reopened = PreferencesStore::from_settings(reopened, None);
        assert_eq!(reopened.load().default_page_size, 424_242);
        assert!(!reopened.load().csv_include_header);
    }

    #[test]
    fn production_and_development_profiles_use_separate_gsettings_paths() {
        let production = settings_path_for_profile(crate::config::Profile::Default);
        let development = settings_path_for_profile(crate::config::Profile::Development);
        assert_ne!(production, development);
        assert!(production.starts_with("/com/tablepro/linux/"));
        assert!(development.starts_with("/com/tablepro/linux/Devel/"));
    }

    #[test]
    fn gsettings_keyfile_backend_survives_a_process_restart() {
        let config = tempfile::tempdir().unwrap();
        for mode in ["write", "read"] {
            let status = std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "services::preferences::tests::gsettings_keyfile_child",
                    "--nocapture",
                ])
                .env("TABLEPRO_GSETTINGS_CHILD", mode)
                .env("GSETTINGS_BACKEND", "keyfile")
                .env("XDG_CONFIG_HOME", config.path())
                .status()
                .unwrap();
            assert!(status.success(), "GSettings {mode} child failed");
        }
    }

    #[test]
    fn gsettings_keyfile_child() {
        let Ok(mode) = std::env::var("TABLEPRO_GSETTINGS_CHILD") else {
            return;
        };
        assert!(matches!(mode.as_str(), "write" | "read"));
        let store = PreferencesStore::new();
        match mode.as_str() {
            "write" => {
                store
                    .update(|prefs| {
                        prefs.default_page_size = 313_131;
                        prefs.csv_include_header = false;
                    })
                    .unwrap();
                store.flush().unwrap();
            }
            "read" => {
                let prefs = store.load();
                assert_eq!(prefs.default_page_size, 313_131);
                assert!(!prefs.csv_include_header);
            }
            _ => {}
        }
    }

    #[test]
    fn legacy_preferences_migrate_once_and_source_file_is_a_rollback_copy() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("preferences.json");
        let original = serde_json::to_vec(&Preferences {
            default_page_size: 777,
            editor_font_size: 15,
            csv_include_header: false,
            ..Preferences::default()
        })
        .unwrap();
        std::fs::write(&path, &original).unwrap();
        let (settings, backend) = make_test_settings("/com/tablepro/linux/migration/");

        migrate_json_preferences(&settings, Some(&path)).unwrap();

        let store = PreferencesStore::from_settings(settings.clone(), Some(path.clone()));
        assert_eq!(store.load().default_page_size, 777);
        assert_eq!(store.load().editor_font_size, 15);
        assert!(!store.load().csv_include_header);
        assert_eq!(settings.uint("migration-version"), SETTINGS_MIGRATION_VERSION);
        assert_eq!(std::fs::read(&path).unwrap(), original);
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(backup_path(&path).unwrap())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );

        store.update(|prefs| prefs.default_page_size = 999).unwrap();
        store.flush().unwrap();
        let downgraded_preferences: Preferences = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(downgraded_preferences.default_page_size, 999);
        assert_eq!(std::fs::read(backup_path(&path).unwrap()).unwrap(), original);

        let reopened = test_settings_with_backend("/com/tablepro/linux/migration/", backend);
        migrate_json_preferences(&reopened, Some(&path)).unwrap();
        assert_eq!(read_settings(&reopened).default_page_size, 999);
    }

    #[test]
    fn remote_migration_marker_keeps_settings_and_imports_rollback_edits() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("preferences.json");
        let (settings, _) = make_test_settings("/com/tablepro/linux/remote/");
        settings.set_boolean("preferences-migrated", true).unwrap();
        settings.set_uint64("default-page-size", 555).unwrap();
        migrate_json_preferences(&settings, Some(&path)).unwrap();
        assert_eq!(read_settings(&settings).default_page_size, 555);
        let legacy = Preferences {
            default_page_size: 777,
            ..Preferences::default()
        };
        atomic_write_json(&path, &legacy).unwrap();
        migrate_json_preferences(&settings, Some(&path)).unwrap();
        assert_eq!(read_settings(&settings), legacy);
        std::fs::write(&path, b"broken json").unwrap();
        let store = PreferencesStore::from_settings_with_legacy(settings, Some(path.clone()));
        assert!(store.update(|prefs| prefs.default_page_size = 1).is_err());
        assert_eq!(std::fs::read(path).unwrap(), b"broken json");
    }

    #[test]
    fn malformed_legacy_preferences_are_preserved_and_migration_can_retry() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("preferences.json");
        std::fs::write(&path, b"broken json").unwrap();
        let (settings, _) = make_test_settings("/com/tablepro/linux/bad-migration/");

        assert!(migrate_json_preferences(&settings, Some(&path)).is_err());
        assert_eq!(settings.uint("migration-version"), 0);
        assert_eq!(std::fs::read(&path).unwrap(), b"broken json");
        let store = PreferencesStore::from_settings_with_legacy(settings.clone(), Some(path.clone()));
        assert!(store.update(|prefs| prefs.default_page_size = 500).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"broken json");
        std::fs::write(&path, serde_json::to_vec(&Preferences::default()).unwrap()).unwrap();
        migrate_json_preferences(&settings, Some(&path)).unwrap();
        assert_eq!(settings.uint("migration-version"), SETTINGS_MIGRATION_VERSION);
    }

    #[test]
    fn a_newer_gsettings_migration_marker_is_not_downgraded() {
        let (settings, _) = make_test_settings("/com/tablepro/linux/future-version/");
        settings
            .set_uint("migration-version", SETTINGS_MIGRATION_VERSION + 1)
            .unwrap();

        assert!(migrate_json_preferences(&settings, None).is_err());
        assert_eq!(settings.uint("migration-version"), SETTINGS_MIGRATION_VERSION + 1);
    }

    #[test]
    fn failed_legacy_mirror_rolls_back_the_gsettings_update() {
        let dir = tempfile::tempdir().unwrap();
        let parent_file = dir.path().join("not-a-directory");
        std::fs::write(&parent_file, b"block directory creation").unwrap();
        let path = parent_file.join("preferences.json");
        let (settings, _) = make_test_settings("/com/tablepro/linux/mirror-failure/");
        let store = PreferencesStore::from_settings(settings, Some(path));

        assert!(store.update(|prefs| prefs.default_page_size = 500).is_err());

        assert_eq!(store.load().default_page_size, Preferences::default().default_page_size);
    }

    fn test_settings_with_backend(_path: &str, backend: gio::SettingsBackend) -> gio::Settings {
        let source = gio::SettingsSchemaSource::from_directory(
            env!("TABLEPRO_GSETTINGS_SCHEMA_DIR"),
            gio::SettingsSchemaSource::default().as_ref(),
            false,
        )
        .unwrap();
        let schema = source.lookup(SETTINGS_SCHEMA, true).unwrap();
        gio::Settings::new_full(&schema, Some(&backend), None)
    }

    fn after_a_round_trip(path: &str, change: impl FnOnce(&mut Preferences)) -> (Preferences, Preferences) {
        let (settings, backend) = make_test_settings(path);
        let store = PreferencesStore::from_settings(settings, None);
        let before = store.load();
        store.update(change).unwrap();
        store.flush().unwrap();
        let reopened = PreferencesStore::from_settings(test_settings_with_backend(path, backend), None);
        (before, reopened.load())
    }

    #[test]
    fn the_color_scheme_survives_a_gsettings_round_trip_and_defaults_to_the_system() {
        let (before, after) = after_a_round_trip("/com/tablepro/linux/scheme/", |prefs| {
            prefs.color_scheme = ColorSchemePref::Dark;
        });
        assert_eq!(before.color_scheme, ColorSchemePref::System);
        assert_eq!(after.color_scheme, ColorSchemePref::Dark);
    }

    #[test]
    fn the_editor_font_family_survives_a_gsettings_round_trip_and_defaults_to_empty() {
        let (before, after) = after_a_round_trip("/com/tablepro/linux/font-family/", |prefs| {
            prefs.editor_font_family = "Iosevka".into();
        });
        assert_eq!(before.editor_font_family, "");
        assert_eq!(after.editor_font_family, "Iosevka");
    }

    #[test]
    fn vim_mode_is_off_by_default_and_survives_a_gsettings_round_trip() {
        let (before, after) = after_a_round_trip("/com/tablepro/linux/vim-mode/", |prefs| {
            prefs.editor_vim_mode = true;
        });
        assert!(!before.editor_vim_mode);
        assert!(after.editor_vim_mode);
    }

    #[test]
    fn color_scheme_rows_keys_and_styles_agree() {
        for (position, scheme) in ColorSchemePref::ALL.into_iter().enumerate() {
            assert_eq!(scheme.index() as usize, position);
            assert_eq!(ColorSchemePref::from_index(position as u32), scheme);
            assert_eq!(ColorSchemePref::from_key(scheme.key()), scheme);
        }
        assert_eq!(ColorSchemePref::from_key("sepia"), ColorSchemePref::System);
        assert_eq!(ColorSchemePref::from_index(9), ColorSchemePref::System);
        assert_eq!(ColorSchemePref::Light.style(), adw::ColorScheme::ForceLight);
        assert_eq!(ColorSchemePref::Dark.style(), adw::ColorScheme::ForceDark);
        assert_eq!(ColorSchemePref::System.style(), adw::ColorScheme::Default);
    }

    #[test]
    fn an_old_preferences_file_without_a_color_scheme_loads_with_the_system_default() {
        let parsed: Preferences =
            serde_json::from_str(r#"{"default_page_size":50,"confirm_destructive":true,"editor_font_size":12}"#)
                .unwrap();
        assert_eq!(parsed.color_scheme, ColorSchemePref::System);
    }
}
