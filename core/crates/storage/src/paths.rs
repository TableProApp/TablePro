use std::path::{Path, PathBuf};

/// Every directory the app writes to, resolved once at startup by the
/// platform the app runs on.
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

    pub fn column_layouts_file(&self) -> PathBuf {
        self.config.join("column_layouts.json")
    }

    pub fn filter_settings_file(&self) -> PathBuf {
        self.config.join("filter_settings.json")
    }

    pub fn highlight_rules_file(&self) -> PathBuf {
        self.config.join("highlight_rules.json")
    }

    pub fn drafts_dir(&self) -> PathBuf {
        self.data.join("drafts")
    }

    /// The user's own SQL editor snippets, in GtkSourceView's format.
    pub fn snippets_dir(&self) -> PathBuf {
        self.data.join("snippets")
    }

    pub fn crashes_dir(&self) -> PathBuf {
        self.state.join("crashes")
    }

    // The entitlement in it is signed, so it needs no keyring.
    pub fn account_file(&self) -> PathBuf {
        self.state.join("account.json")
    }

    // The usage data's anonymous ID and what it sent once.
    pub fn telemetry_file(&self) -> PathBuf {
        self.state.join("telemetry.json")
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
        assert_eq!(
            paths.highlight_rules_file(),
            root.join("config/tablepro/highlight_rules.json")
        );
        assert_eq!(paths.snippets_dir(), root.join("data/tablepro/snippets"));
        assert_eq!(paths.account_file(), root.join("state/tablepro/account.json"));
        assert_eq!(paths.telemetry_file(), root.join("state/tablepro/telemetry.json"));
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
