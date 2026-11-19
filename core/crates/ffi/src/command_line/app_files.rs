// The Windows app's files the command reads, as windows/docs/decisions/0019-mcp-server-and-command-line.md says.

use std::io;
use std::path::{Path, PathBuf};

use serde_json::Value;

// windows/src/TablePro.App.Model/AppSettings.cs writes them with these names and normalizes the port to this range.
const ENABLED_KEY: &str = "mcpServerEnabled";
const PORT_KEY: &str = "mcpServerPort";
const LOWEST_PORT: u16 = 1024;

// The app writes its process id here and holds the file open for writing while it runs (App's AppPresence).
#[cfg(windows)]
const PRESENCE_FILE: [&str; 2] = ["runtime", "app.lock"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct McpSettings {
    pub(crate) enabled: bool,
    pub(crate) port: u16,
}

impl Default for McpSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            port: tablepro_mcp::DEFAULT_PORT,
        }
    }
}

// As AppStorage resolves it: TABLEPRO_DATA_DIR, else a packaged app's LocalState, else %LOCALAPPDATA%\TablePro.
pub(crate) fn data_folder(
    variable: impl Fn(&str) -> Option<std::ffi::OsString>,
    package_family: Option<String>,
) -> Option<PathBuf> {
    if let Some(overridden) = variable("TABLEPRO_DATA_DIR").filter(|dir| !dir.to_string_lossy().trim().is_empty()) {
        return std::path::absolute(overridden).ok();
    }
    let local = PathBuf::from(variable("LOCALAPPDATA").filter(|dir| !dir.is_empty())?);
    Some(match package_family {
        Some(family) => local.join("Packages").join(family).join("LocalState"),
        None => local.join("TablePro"),
    })
}

// A file that is missing or does not parse gives the defaults, as the app reads it.
pub(crate) fn read_settings(folder: &Path) -> io::Result<McpSettings> {
    match std::fs::read(folder.join("settings.json")) {
        Ok(bytes) => Ok(parse_settings(&bytes)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(McpSettings::default()),
        Err(error) => Err(error),
    }
}

pub(crate) fn parse_settings(bytes: &[u8]) -> McpSettings {
    let defaults = McpSettings::default();
    let Ok(document) = serde_json::from_slice::<Value>(bytes) else {
        return defaults;
    };
    McpSettings {
        enabled: document
            .get(ENABLED_KEY)
            .and_then(Value::as_bool)
            .unwrap_or(defaults.enabled),
        port: document
            .get(PORT_KEY)
            .and_then(Value::as_i64)
            .map_or(defaults.port, |port| {
                u16::try_from(port.clamp(i64::from(LOWEST_PORT), i64::from(u16::MAX))).unwrap_or(defaults.port)
            }),
    }
}

#[cfg(windows)]
pub(crate) fn presence_file(folder: &Path) -> PathBuf {
    PRESENCE_FILE
        .iter()
        .fold(folder.to_path_buf(), |path, part| path.join(part))
}

// The running app's process id. It shares the file for reading only, so Windows refuses a second writer while it runs.
#[cfg(windows)]
pub(crate) fn holder(folder: &Path) -> Option<u32> {
    const ERROR_SHARING_VIOLATION: i32 = 32;
    let file = presence_file(folder);
    match std::fs::OpenOptions::new().write(true).open(&file) {
        Err(error) if error.raw_os_error() == Some(ERROR_SHARING_VIOLATION) => {}
        _ => return None,
    }
    parse_holder(&std::fs::read_to_string(file).ok()?)
}

pub(crate) fn parse_holder(text: &str) -> Option<u32> {
    text.trim().parse().ok().filter(|pid| *pid != 0)
}

// The informational version .NET writes as the product version, without the commit after `+`.
pub(crate) fn app_version(product_version: Option<&str>) -> String {
    product_version
        .and_then(|version| version.split('+').next())
        .map(str::trim)
        .filter(|version| !version.is_empty())
        .unwrap_or("0.0.0")
        .to_owned()
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;

    use super::*;

    fn variables(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<OsString> {
        let pairs: Vec<(String, OsString)> = pairs
            .iter()
            .map(|(name, value)| ((*name).to_owned(), OsString::from(value)))
            .collect();
        move |name| {
            pairs
                .iter()
                .find(|(key, _)| key == name)
                .map(|(_, value)| value.clone())
        }
    }

    #[test]
    fn the_data_folder_is_found_as_the_app_finds_it() {
        let local = std::env::temp_dir().join("Local");
        let local_text = local.to_string_lossy().into_owned();
        let overridden = std::env::temp_dir().join("tests").join("data");

        assert_eq!(
            data_folder(
                variables(&[
                    ("TABLEPRO_DATA_DIR", &overridden.to_string_lossy()),
                    ("LOCALAPPDATA", &local_text)
                ]),
                Some("TablePro_x".to_owned())
            ),
            Some(overridden)
        );
        assert_eq!(
            data_folder(
                variables(&[("LOCALAPPDATA", &local_text)]),
                Some("TablePro_x".to_owned())
            ),
            Some(local.join("Packages").join("TablePro_x").join("LocalState"))
        );
        assert_eq!(
            data_folder(
                variables(&[("TABLEPRO_DATA_DIR", "  "), ("LOCALAPPDATA", &local_text)]),
                None
            ),
            Some(local.join("TablePro"))
        );
        assert_eq!(data_folder(variables(&[]), None), None);
    }

    #[test]
    fn the_settings_read_as_the_app_writes_them() {
        let written = br#"{
  "theme": "System",
  "mcpServerEnabled": true,
  "mcpServerPort": 24000
}"#;

        assert_eq!(
            parse_settings(written),
            McpSettings {
                enabled: true,
                port: 24000
            }
        );
        assert_eq!(parse_settings(b"{}"), McpSettings::default());
        assert_eq!(parse_settings(b"not json"), McpSettings::default());
        assert_eq!(parse_settings(br#"{"mcpServerPort": 80}"#).port, 1024);
        assert_eq!(parse_settings(br#"{"mcpServerPort": 70000}"#).port, 65535);
        assert!(!parse_settings(br#"{"mcpServerEnabled": "yes"}"#).enabled);
    }

    #[test]
    fn a_folder_with_no_settings_file_has_the_defaults() {
        let folder = tempfile::tempdir().unwrap();

        assert_eq!(read_settings(folder.path()).unwrap(), McpSettings::default());
        std::fs::write(folder.path().join("settings.json"), br#"{"mcpServerEnabled":true}"#).unwrap();
        assert!(read_settings(folder.path()).unwrap().enabled);
    }

    #[test]
    fn the_version_drops_the_commit() {
        assert_eq!(app_version(Some("0.1.0+3f2a9c")), "0.1.0");
        assert_eq!(app_version(Some("1.2.3")), "1.2.3");
        assert_eq!(app_version(Some("")), "0.0.0");
        assert_eq!(app_version(None), "0.0.0");
    }

    #[test]
    fn the_holder_is_a_process_id() {
        assert_eq!(parse_holder("4242"), Some(4242));
        assert_eq!(parse_holder(" 4242\r\n"), Some(4242));
        assert_eq!(parse_holder(""), None);
        assert_eq!(parse_holder("0"), None);
        assert_eq!(parse_holder("tablepro"), None);
    }

    // As the app holds it: FileAccess.ReadWrite with FileShare.Read.
    #[cfg(windows)]
    #[test]
    fn a_folder_has_a_holder_only_while_a_process_keeps_the_file_open_for_writing() {
        use std::io::Write;
        use std::os::windows::fs::OpenOptionsExt;

        const FILE_SHARE_READ: u32 = 1;
        let folder = tempfile::tempdir().unwrap();
        assert_eq!(holder(folder.path()), None);
        let file = presence_file(folder.path());
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();

        let mut held = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .share_mode(FILE_SHARE_READ)
            .open(&file)
            .unwrap();
        write!(held, "4242").unwrap();
        held.flush().unwrap();
        assert_eq!(holder(folder.path()), Some(4242));
        drop(held);
        assert_eq!(holder(folder.path()), None);
    }
}
