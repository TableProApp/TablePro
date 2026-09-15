pub const APP_ID: &str = default_env(option_env!("TABLEPRO_APP_ID"), "app.tablepro.TablePro.Devel");
pub const VERSION: &str = default_env(option_env!("TABLEPRO_VERSION"), "unknown");
pub const PROFILE: &str = default_env(option_env!("TABLEPRO_PROFILE"), "development");
pub const LOCALEDIR: &str = default_env(option_env!("TABLEPRO_LOCALEDIR"), "/usr/share/locale");
pub const LIBEXECDIR: &str = default_env(option_env!("TABLEPRO_LIBEXECDIR"), "/usr/libexec");

pub const GETTEXT_PACKAGE: &str = env!("CARGO_PKG_NAME");
pub const SCHEMA_ID: &str = "app.tablepro.TablePro";
pub const RESOURCE_BASE_PATH: &str = "/app/tablepro/TablePro";

const DEVELOPMENT_SUFFIX: &str = ".Devel";

const fn default_env(value: Option<&'static str>, fallback: &'static str) -> &'static str {
    match value {
        Some(value) => value,
        None => fallback,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Profile {
    Default,
    Development,
}

pub fn profile() -> Profile {
    if APP_ID.ends_with(DEVELOPMENT_SUFFIX) {
        Profile::Development
    } else {
        Profile::Default
    }
}

/// Directory name under `$XDG_CONFIG_HOME` and `$XDG_STATE_HOME`. A
/// development build keeps its own so `cargo run` never writes over an
/// installed build's connections, history or workspace state.
pub fn storage_dir_name() -> &'static str {
    match profile() {
        Profile::Default => "tablepro",
        Profile::Development => "tablepro-devel",
    }
}

/// `xdg:schema` attribute for keyring items. It follows the app ID, so
/// a development build never reads an installed build's secrets.
pub fn secret_schema() -> String {
    format!("{APP_ID}.Password")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn app_id_is_valid() {
        assert!(gtk4::gio::Application::id_is_valid(APP_ID));
        assert!(gtk4::gio::Application::id_is_valid(SCHEMA_ID));
    }

    #[test]
    fn app_id_extends_the_schema_id() {
        assert!(APP_ID.starts_with(SCHEMA_ID));
    }

    #[test]
    fn resource_base_path_derives_from_the_schema_id() {
        assert_eq!(RESOURCE_BASE_PATH, format!("/{}", SCHEMA_ID.replace('.', "/")));
    }

    #[test]
    fn profile_is_development_exactly_when_the_app_id_is_a_devel_id() {
        assert_eq!(profile() == Profile::Development, APP_ID.ends_with(DEVELOPMENT_SUFFIX));
    }

    #[test]
    fn storage_dir_name_separates_development_from_installed_builds() {
        let expected = match profile() {
            Profile::Default => "tablepro",
            Profile::Development => "tablepro-devel",
        };
        assert_eq!(storage_dir_name(), expected);
        assert_ne!("tablepro", "tablepro-devel");
    }

    #[test]
    fn secret_schema_follows_the_app_id() {
        assert_eq!(secret_schema(), format!("{APP_ID}.Password"));
        assert!(secret_schema().starts_with(SCHEMA_ID));
    }

    #[test]
    fn default_env_prefers_the_build_time_value() {
        assert_eq!(default_env(Some("set"), "fallback"), "set");
        assert_eq!(default_env(None, "fallback"), "fallback");
    }

    #[test]
    fn gettext_package_is_the_package_name() {
        assert_eq!(GETTEXT_PACKAGE, "tablepro");
    }
}
