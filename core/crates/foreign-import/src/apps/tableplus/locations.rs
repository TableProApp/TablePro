use std::path::{Path, PathBuf};

use serde::Deserialize;

use super::connection::Dialect;
use super::favorites::{self, Root, standardized};
use super::linux::Settings;
use crate::{ForeignAppDirs, ForeignPlatform};

// The standalone app first: it wins when both editions are there.
pub(super) const BUNDLE_IDENTIFIERS: [&str; 2] = ["com.tinyapp.TablePlus", "com.tinyapp.TablePlus-setapp"];
const WINDOWS_FOLDER: &str = "com.tinyapp.TablePlus";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum StoreFormat {
    Plist,
    Json,
}

// A folder holding one connection list and its groups.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct ConnectionStore {
    pub folder: PathBuf,
    pub format: StoreFormat,
}

impl ConnectionStore {
    fn plist(folder: PathBuf) -> Self {
        Self {
            folder,
            format: StoreFormat::Plist,
        }
    }

    pub(super) fn connections_file(&self) -> PathBuf {
        self.folder.join(match self.format {
            StoreFormat::Plist => "Connections.plist",
            StoreFormat::Json => "connections.json",
        })
    }

    pub(super) fn groups_file(&self) -> PathBuf {
        self.folder.join(match self.format {
            StoreFormat::Plist => "ConnectionGroups.plist",
            StoreFormat::Json => "connection_groups.json",
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Layout {
    pub dialect: Dialect,
    pub stores: Vec<ConnectionStore>,
    pub favorite_roots: Vec<Root>,
    pub reads_keywords: bool,
}

pub(super) fn layout(dirs: &ForeignAppDirs) -> Layout {
    match dirs.platform {
        ForeignPlatform::MacOs => macos(dirs),
        ForeignPlatform::Windows => windows(dirs),
        ForeignPlatform::Linux => linux(dirs),
    }
}

// What the app keeps in its preferences about where its files are.
#[derive(Debug, Default, PartialEq, Eq)]
pub(super) struct ViewSetting {
    pub shared_connection_path: Option<String>,
    pub shared_query_path: Option<String>,
    pub favorites: Vec<String>,
}

// Moving the data in the app's preferences writes the connection files directly under the chosen folder.
fn macos(dirs: &ForeignAppDirs) -> Layout {
    let bundle = macos_bundle_identifier(dirs);
    let data = macos_data_directory(&dirs.data, bundle);
    let setting = macos_view_setting(&macos_preferences_file(&dirs.home, bundle)).unwrap_or_default();
    let connections = shared_path(setting.shared_connection_path.as_deref(), dirs).unwrap_or_else(|| data.clone());
    let favorite_root = shared_path(setting.shared_query_path.as_deref(), dirs)
        .unwrap_or(data)
        .join("Favorite");
    Layout {
        dialect: Dialect::MacOs,
        stores: vec![ConnectionStore::plist(connections)],
        favorite_roots: favorites::roots(favorite_root, shared_folders(&setting.favorites, dirs)),
        reads_keywords: true,
    }
}

// The edition whose files are on disk, as no installed-app lookup reaches this crate.
pub(super) fn macos_bundle_identifier(dirs: &ForeignAppDirs) -> &'static str {
    BUNDLE_IDENTIFIERS
        .into_iter()
        .find(|bundle| dirs.data.join(bundle).is_dir() || macos_preferences_file(&dirs.home, bundle).is_file())
        .unwrap_or(BUNDLE_IDENTIFIERS[0])
}

pub(super) fn macos_data_directory(application_support: &Path, bundle: &str) -> PathBuf {
    application_support.join(bundle).join("Data")
}

fn macos_preferences_file(home: &Path, bundle: &str) -> PathBuf {
    home.join("Library").join("Preferences").join(format!("{bundle}.plist"))
}

pub(super) fn macos_view_setting(preferences: &Path) -> Option<ViewSetting> {
    let data = crate::files::read_capped(preferences).ok()?;
    let root = plist::Value::from_reader(std::io::Cursor::new(data)).ok()?;
    let setting = root.as_dictionary()?.get("ViewSetting")?.as_dictionary()?;
    let text = |key: &str| setting.get(key).and_then(plist::Value::as_string).map(str::to_owned);
    let favorites = setting
        .get("Favorites")
        .and_then(plist::Value::as_array)
        .and_then(|items| {
            items
                .iter()
                .map(plist::Value::as_dictionary)
                .collect::<Option<Vec<_>>>()
        })
        .unwrap_or_default()
        .into_iter()
        .filter_map(|favorite| {
            favorite
                .get("path")
                .and_then(plist::Value::as_string)
                .map(str::to_owned)
        })
        .collect();
    Some(ViewSetting {
        shared_connection_path: text("SharedConnectionPath"),
        shared_query_path: text("SharedQueryPath"),
        favorites,
    })
}

// The local folder, then every extra folder the app lists, each with its own connection files.
fn windows(dirs: &ForeignAppDirs) -> Layout {
    let base = dirs.data.join(WINDOWS_FOLDER);
    let data = base.join("Data");
    let mut stores = vec![ConnectionStore::plist(data.clone())];
    for folder in windows_connection_sources(&base.join("ConnectionSources.json"), dirs) {
        let folder_key = standardized(&folder);
        if stores.iter().all(|store| standardized(&store.folder) != folder_key) {
            stores.push(ConnectionStore::plist(folder));
        }
    }
    let setting = windows_setting(&base.join("Setting.json"));
    let favorite_root = shared_path(setting.shared_query_path.as_deref(), dirs)
        .unwrap_or(data)
        .join("Favorite");
    Layout {
        dialect: Dialect::Windows,
        stores,
        favorite_roots: favorites::roots(favorite_root, shared_folders(&setting.favorites, dirs)),
        reads_keywords: true,
    }
}

#[derive(Deserialize)]
struct SourceList {
    #[serde(default)]
    sources: Vec<serde_json::Value>,
}

fn windows_connection_sources(path: &Path, dirs: &ForeignAppDirs) -> Vec<PathBuf> {
    let Some(list) = crate::files::read_capped(path)
        .ok()
        .and_then(|data| serde_json::from_slice::<SourceList>(&data).ok())
    else {
        return Vec::new();
    };
    list.sources
        .iter()
        .filter_map(|source| source.get("path").and_then(serde_json::Value::as_str))
        .filter_map(|path| shared_path(Some(path), dirs))
        .filter(|folder| folder.is_dir())
        .collect()
}

#[derive(Deserialize, Default)]
struct WindowsSetting {
    #[serde(rename = "sharedQueryPath", default)]
    shared_query_path: Option<serde_json::Value>,
    #[serde(default)]
    favorites: Option<serde_json::Value>,
}

fn windows_setting(path: &Path) -> ViewSetting {
    let setting: WindowsSetting = crate::files::read_capped(path)
        .ok()
        .and_then(|data| serde_json::from_slice(&data).ok())
        .unwrap_or_default();
    let favorites = setting
        .favorites
        .as_ref()
        .and_then(serde_json::Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.get("path").and_then(serde_json::Value::as_str))
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default();
    ViewSetting {
        shared_connection_path: None,
        shared_query_path: setting
            .shared_query_path
            .as_ref()
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned),
        favorites,
    }
}

// The Linux app keeps everything under `~/.tableplus`, not under the XDG folders.
fn linux(dirs: &ForeignAppDirs) -> Layout {
    let base = dirs.home.join(".tableplus");
    let settings_folder = base.join("settings");
    let settings = crate::files::read_capped(settings_folder.join("settings.json"))
        .map(|data| Settings::parse(&data))
        .unwrap_or_default();
    Layout {
        dialect: Dialect::Linux,
        stores: vec![ConnectionStore {
            folder: settings_folder,
            format: StoreFormat::Json,
        }],
        favorite_roots: favorites::roots(
            base.join("queries"),
            shared_folders(&settings.shared_folder_paths(), dirs),
        ),
        reads_keywords: false,
    }
}

// A folder the user picked in the app, `~` meaning the home folder.
fn shared_path(raw: Option<&str>, dirs: &ForeignAppDirs) -> Option<PathBuf> {
    let path = raw?.trim();
    if path.is_empty() {
        return None;
    }
    let expanded = if path == "~" {
        dirs.home.clone()
    } else {
        dirs.expand_home(path)
    };
    expanded.is_absolute().then_some(expanded)
}

fn shared_folders(raw_paths: &[String], dirs: &ForeignAppDirs) -> Vec<PathBuf> {
    raw_paths
        .iter()
        .filter_map(|path| shared_path(Some(path), dirs))
        .filter(|folder| folder.is_dir())
        .collect()
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;

    fn dirs(platform: ForeignPlatform, home: &Path) -> ForeignAppDirs {
        ForeignAppDirs::conventional(platform, home)
    }

    #[test]
    fn the_standalone_edition_wins_and_setapp_is_read_when_only_it_is_there() {
        let home = tempfile::tempdir().expect("a temp dir");
        let macos = dirs(ForeignPlatform::MacOs, home.path());
        assert_eq!(macos_bundle_identifier(&macos), "com.tinyapp.TablePlus");

        fs::create_dir_all(macos.data.join("com.tinyapp.TablePlus-setapp")).expect("a folder");
        assert_eq!(macos_bundle_identifier(&macos), "com.tinyapp.TablePlus-setapp");

        let preferences = home.path().join("Library/Preferences");
        fs::create_dir_all(&preferences).expect("a folder");
        fs::write(preferences.join("com.tinyapp.TablePlus.plist"), b"").expect("a file");
        assert_eq!(macos_bundle_identifier(&macos), "com.tinyapp.TablePlus");
    }

    #[test]
    fn the_data_directory_follows_the_bundle_identifier() {
        let support = Path::new("/Users/test/Library/Application Support");
        assert_eq!(
            macos_data_directory(support, "com.tinyapp.TablePlus-setapp"),
            Path::new("/Users/test/Library/Application Support/com.tinyapp.TablePlus-setapp/Data")
        );
    }

    #[test]
    fn view_setting_is_none_without_the_file_or_the_key() {
        let home = tempfile::tempdir().expect("a temp dir");
        assert_eq!(macos_view_setting(&home.path().join("missing.plist")), None);
        let path = home.path().join("other.plist");
        plist::Value::Dictionary(plist::Dictionary::new())
            .to_file_xml(&path)
            .expect("a plist");
        assert_eq!(macos_view_setting(&path), None);
    }

    #[test]
    fn a_shared_path_is_trimmed_expanded_and_must_be_absolute() {
        // Absolute as this host reads a path, so the test holds on Windows too.
        let (home, team) = if cfg!(windows) {
            (r"C:\Users\test", r"D:\Team")
        } else {
            ("/Users/test", "/Volumes/Team")
        };
        let macos = dirs(ForeignPlatform::MacOs, Path::new(home));
        assert_eq!(
            shared_path(Some(" ~/Queries \n"), &macos),
            Some(Path::new(home).join("Queries"))
        );
        assert_eq!(shared_path(Some("~"), &macos), Some(PathBuf::from(home)));
        assert_eq!(shared_path(Some(team), &macos), Some(PathBuf::from(team)));
        assert_eq!(shared_path(Some("relative/dir"), &macos), None);
        assert_eq!(shared_path(Some("  "), &macos), None);
        assert_eq!(shared_path(None, &macos), None);
    }

    #[test]
    fn a_windows_connection_source_already_listed_is_read_once() {
        let home = tempfile::tempdir().expect("a temp dir");
        let windows = dirs(ForeignPlatform::Windows, home.path());
        let base = windows.data.join(WINDOWS_FOLDER);
        let team = home.path().join("Team");
        fs::create_dir_all(base.join("Data")).expect("a folder");
        fs::create_dir_all(&team).expect("a folder");
        let quoted = |path: &Path| serde_json::to_string(path).expect("a path");
        let sources = format!(
            r#"{{"sources":[{{"id":"1","name":"Local","path":{}}},{{"id":"2","name":"Team","path":{}}},{{"id":"3","path":{}}},{{"id":"4","path":"relative"}},{{"id":"5"}}]}}"#,
            quoted(&base.join("Data")),
            quoted(&team),
            quoted(&home.path().join("gone")),
        );
        fs::write(base.join("ConnectionSources.json"), sources).expect("a file");
        let folders: Vec<PathBuf> = layout(&windows).stores.into_iter().map(|store| store.folder).collect();
        assert_eq!(folders, [base.join("Data"), team]);
    }
}
