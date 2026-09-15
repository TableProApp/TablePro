use std::path::{Path, PathBuf};

/// Every directory the app writes to, resolved once at startup.
///
/// A development build passes a different `dir_name`, so its files never
/// land on top of an installed build's.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoragePaths {
    pub config: PathBuf,
    pub state: PathBuf,
    pub data: PathBuf,
    pub cache: PathBuf,
    pub runtime: PathBuf,
}

impl StoragePaths {
    /// GLib resolves the XDG base directories, including the fallbacks
    /// for an unset variable, so the app agrees with the rest of the
    /// desktop about where things go.
    pub fn from_glib(dir_name: &str, app_id: &str) -> Self {
        Self {
            config: glib::user_config_dir().join(dir_name),
            state: glib::user_state_dir().join(dir_name),
            data: glib::user_data_dir().join(dir_name),
            cache: glib::user_cache_dir().join(dir_name),
            runtime: glib::user_runtime_dir().join("app").join(app_id),
        }
    }

    /// The same layout under a caller-supplied root, for tests.
    pub fn under(root: &Path, dir_name: &str, app_id: &str) -> Self {
        Self {
            config: root.join("config").join(dir_name),
            state: root.join("state").join(dir_name),
            data: root.join("data").join(dir_name),
            cache: root.join("cache").join(dir_name),
            runtime: root.join("runtime").join("app").join(app_id),
        }
    }

    pub fn connections_file(&self) -> PathBuf {
        self.config.join("connections.json")
    }

    pub fn history_database(&self) -> PathBuf {
        self.state.join("history.db")
    }

    pub fn workspaces_dir(&self) -> PathBuf {
        self.state.join("workspaces")
    }

    pub fn workspace_state_file(&self) -> PathBuf {
        self.state.join("workspace_state.json")
    }

    pub fn column_widths_file(&self) -> PathBuf {
        self.config.join("column_widths.json")
    }

    pub fn filter_settings_file(&self) -> PathBuf {
        self.config.join("filter_settings.json")
    }

    pub fn drafts_dir(&self) -> PathBuf {
        self.data.join("drafts")
    }

    pub fn instance_lock(&self) -> PathBuf {
        self.runtime.join("tablepro.lock")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn under_joins_dir_name_and_app_runtime() {
        let root = Path::new("/tmp/root");

        let paths = StoragePaths::under(root, "tablepro", "app.tablepro.TablePro");

        assert_eq!(paths.config, root.join("config/tablepro"));
        assert_eq!(paths.state, root.join("state/tablepro"));
        assert_eq!(paths.runtime, root.join("runtime/app/app.tablepro.TablePro"));
        assert_eq!(paths.history_database(), root.join("state/tablepro/history.db"));
        assert_eq!(paths.connections_file(), root.join("config/tablepro/connections.json"));
    }

    #[test]
    fn profiles_are_disjoint() {
        let root = Path::new("/tmp/root");

        let installed = StoragePaths::under(root, "tablepro", "app.tablepro.TablePro");
        let devel = StoragePaths::under(root, "tablepro-devel", "app.tablepro.TablePro.Devel");

        assert_ne!(installed.config, devel.config);
        assert_ne!(installed.state, devel.state);
        assert_ne!(installed.runtime, devel.runtime);
        assert_ne!(installed.history_database(), devel.history_database());
    }
}
