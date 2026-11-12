use std::collections::{BTreeMap, HashSet};

use serde::Deserialize;

use super::json_value::JsonValue;

const BUNDLED: &str = include_str!("../../clients.json");

pub const SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClientPlatform {
    Macos,
    Linux,
}

#[derive(Debug, thiserror::Error)]
pub enum CatalogError {
    #[error("the client catalog has schema version {0}")]
    UnsupportedSchema(u32),
    #[error("the client catalog is not valid at line {line}, column {column}: {detail}")]
    Malformed { line: usize, column: usize, detail: String },
    #[error("client {client} names config {config}, which the catalog does not define")]
    UnknownConfig { client: String, config: String },
    #[error("client {0} is listed twice")]
    DuplicateClient(String),
}

impl CatalogError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::UnsupportedSchema(_) => "unsupported_schema",
            Self::Malformed { .. } => "malformed",
            Self::UnknownConfig { .. } => "unknown_config",
            Self::DuplicateClient(_) => "duplicate_client",
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ClientCatalog {
    pub schema_version: u32,
    pub server_name: String,
    configs: BTreeMap<String, ConfigSet>,
    pub clients: Vec<ClientDefinition>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct ConfigSet {
    macos: Option<ConfigLocation>,
    linux: Option<ConfigLocation>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ConfigLocation {
    pub path: String,
    pub format: ConfigFormat,
    pub key_path: Vec<String>,
    #[serde(default = "writable_by_default")]
    pub writable: bool,
    // An older layout of the same file, read like `key_path` and never
    // written.
    #[serde(default)]
    pub alternate_key_paths: Vec<Vec<String>>,
    #[serde(default)]
    pub other_scopes: Vec<Vec<String>>,
}

fn writable_by_default() -> bool {
    true
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ConfigFormat {
    Json,
    Jsonc,
    Toml,
    Yaml,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ClientDefinition {
    pub id: String,
    pub name: String,
    pub icon: String,
    pub config: Option<String>,
    pub client_info: ClientInfoNames,
    macos: Option<PlatformSpec>,
    linux: Option<PlatformSpec>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ClientInfoNames {
    #[serde(default)]
    pub names: Vec<String>,
    #[serde(default)]
    pub prefixes: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PlatformSpec {
    #[serde(default)]
    pub detect: Vec<DetectRule>,
    pub entry: Option<JsonValue>,
    #[serde(default)]
    pub install: Vec<InstallMethod>,
    pub applies: Option<Applies>,
    pub unsupported: Option<UnsupportedReason>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(from = "DetectRuleText")]
pub enum DetectRule {
    BundleId(String),
    Binary { name: String, paths: Vec<String> },
    Path(String),
}

#[derive(Deserialize)]
#[serde(untagged)]
enum DetectRuleText {
    BundleId(BundleIdRule),
    Binary(BinaryRule),
    Path(PathRule),
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct BundleIdRule {
    bundle_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BinaryRule {
    binary: String,
    paths: Vec<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PathRule {
    path: String,
}

impl From<DetectRuleText> for DetectRule {
    fn from(text: DetectRuleText) -> Self {
        match text {
            DetectRuleText::BundleId(rule) => Self::BundleId(rule.bundle_id),
            DetectRuleText::Binary(rule) => Self::Binary {
                name: rule.binary,
                paths: rule.paths,
            },
            DetectRuleText::Path(rule) => Self::Path(rule.path),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum InstallMethod {
    Deeplink(DeeplinkInstall),
    Cli(CliInstall),
    File,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeeplinkInstall {
    pub scheme: String,
    pub url: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CliInstall {
    pub binary: String,
    pub add: Vec<String>,
    pub remove: Option<Vec<String>>,
    #[serde(default)]
    pub update: CliUpdate,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CliUpdate {
    #[default]
    Add,
    RemoveThenAdd,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Applies {
    Live,
    NewSession,
    RestartApp,
    Reload,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum UnsupportedReason {
    RemoteOnly,
    StdioOnly,
}

impl ClientCatalog {
    // The catalog both apps ship, compiled into this crate.
    pub fn bundled() -> Result<Self, CatalogError> {
        Self::parse(BUNDLED)
    }

    pub fn parse(text: &str) -> Result<Self, CatalogError> {
        let catalog: Self = serde_json::from_str(text).map_err(|error| CatalogError::Malformed {
            line: error.line(),
            column: error.column(),
            detail: error.to_string(),
        })?;
        if catalog.schema_version != SCHEMA_VERSION {
            return Err(CatalogError::UnsupportedSchema(catalog.schema_version));
        }
        let mut ids = HashSet::new();
        for client in &catalog.clients {
            if !ids.insert(client.id.as_str()) {
                return Err(CatalogError::DuplicateClient(client.id.clone()));
            }
            if let Some(config) = &client.config
                && !catalog.configs.contains_key(config)
            {
                return Err(CatalogError::UnknownConfig {
                    client: client.id.clone(),
                    config: config.clone(),
                });
            }
        }
        Ok(catalog)
    }

    pub fn client(&self, id: &str) -> Option<&ClientDefinition> {
        self.clients.iter().find(|client| client.id == id)
    }

    // A client without an entry for the platform is not shown there.
    pub fn clients_on(&self, platform: ClientPlatform) -> impl Iterator<Item = &ClientDefinition> {
        self.clients
            .iter()
            .filter(move |client| client.spec(platform).is_some())
    }

    pub fn location(&self, client: &ClientDefinition, platform: ClientPlatform) -> Option<&ConfigLocation> {
        let set = self.configs.get(client.config.as_deref()?)?;
        match platform {
            ClientPlatform::Macos => set.macos.as_ref(),
            ClientPlatform::Linux => set.linux.as_ref(),
        }
    }

    // Exact names first, ignoring case, then prefixes, the longest first.
    // Several clients can share one engine, so every match is returned.
    pub fn clients_for_client_info(&self, name: &str, platform: ClientPlatform) -> Vec<&ClientDefinition> {
        let name = name.trim().to_lowercase();
        if name.is_empty() {
            return Vec::new();
        }
        let exact: Vec<&ClientDefinition> = self
            .clients_on(platform)
            .filter(|client| {
                client
                    .client_info
                    .names
                    .iter()
                    .any(|known| known.to_lowercase() == name)
            })
            .collect();
        if !exact.is_empty() {
            return exact;
        }
        let mut prefixed: Vec<(usize, &ClientDefinition)> = self
            .clients_on(platform)
            .filter_map(|client| {
                client
                    .client_info
                    .prefixes
                    .iter()
                    .map(|prefix| prefix.to_lowercase())
                    .filter(|prefix| !prefix.is_empty() && name.starts_with(prefix.as_str()))
                    .map(|prefix| prefix.len())
                    .max()
                    .map(|length| (length, client))
            })
            .collect();
        prefixed.sort_by_key(|(length, _)| std::cmp::Reverse(*length));
        prefixed.into_iter().map(|(_, client)| client).collect()
    }
}

impl ClientDefinition {
    pub fn spec(&self, platform: ClientPlatform) -> Option<&PlatformSpec> {
        match platform {
            ClientPlatform::Macos => self.macos.as_ref(),
            ClientPlatform::Linux => self.linux.as_ref(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bundled() -> ClientCatalog {
        ClientCatalog::bundled().expect("the bundled catalog")
    }

    #[test]
    fn the_bundled_catalog_parses() {
        let catalog = bundled();

        assert_eq!(catalog.schema_version, SCHEMA_VERSION);
        assert_eq!(catalog.server_name, "tablepro");
        assert!(catalog.client("claude-code").is_some());
    }

    #[test]
    fn every_client_on_a_platform_is_either_unsupported_or_has_an_entry() {
        let catalog = bundled();

        for platform in [ClientPlatform::Macos, ClientPlatform::Linux] {
            for client in catalog.clients_on(platform) {
                let spec = client.spec(platform).expect("a spec");
                assert!(
                    spec.unsupported.is_some() != spec.entry.is_some(),
                    "{} on {platform:?}",
                    client.id
                );
            }
        }
    }

    #[test]
    fn a_file_install_needs_a_writable_location_on_its_platform() {
        let catalog = bundled();

        for platform in [ClientPlatform::Macos, ClientPlatform::Linux] {
            for client in catalog.clients_on(platform) {
                let spec = client.spec(platform).expect("a spec");
                if spec.install.contains(&InstallMethod::File) {
                    let location = catalog.location(client, platform);
                    assert!(
                        location.is_some_and(|location| location.writable),
                        "{} on {platform:?}",
                        client.id
                    );
                }
            }
        }
    }

    #[test]
    fn linux_entries_reach_the_server_over_http_and_never_start_a_program() {
        let catalog = bundled();

        for client in catalog.clients_on(ClientPlatform::Linux) {
            let Some(entry) = &client.spec(ClientPlatform::Linux).expect("a spec").entry else {
                continue;
            };
            let text = entry.to_compact();
            assert!(text.contains("{url}"), "{}", client.id);
            assert!(text.contains("{authorization}"), "{}", client.id);
            assert!(!text.contains("{command}"), "{}", client.id);
        }
    }

    #[test]
    fn linux_offers_no_deeplink_so_the_token_never_goes_into_a_url() {
        let catalog = bundled();

        for client in catalog.clients_on(ClientPlatform::Linux) {
            let spec = client.spec(ClientPlatform::Linux).expect("a spec");
            assert!(
                !spec
                    .install
                    .iter()
                    .any(|method| matches!(method, InstallMethod::Deeplink(_))),
                "{}",
                client.id
            );
        }
    }

    #[test]
    fn client_info_names_match_exactly_before_prefixes_and_ignore_case() {
        let catalog = bundled();
        let ids = |name: &str| -> Vec<String> {
            catalog
                .clients_for_client_info(name, ClientPlatform::Linux)
                .into_iter()
                .map(|client| client.id.clone())
                .collect()
        };

        assert_eq!(ids("claude-code"), ["claude-code"]);
        assert_eq!(ids("ZED"), ["zed"]);
        assert_eq!(ids("codex-mcp-client"), ["chatgpt", "codex"]);
        assert_eq!(ids("Visual Studio Code"), ["vscode"]);
        assert_eq!(ids("Visual Studio Code - Insiders"), ["vscode-insiders", "vscode"]);
        assert_eq!(ids("goose-cli"), ["goose"]);
        assert!(ids("raycast").is_empty(), "Raycast has no Linux build");
        assert!(ids("").is_empty());
    }

    #[test]
    fn opencode_reads_its_older_layout_as_an_alternate_key_path() {
        let catalog = bundled();
        let opencode = catalog.client("opencode").expect("opencode");

        for platform in [ClientPlatform::Macos, ClientPlatform::Linux] {
            let location = catalog.location(opencode, platform).expect("a location");
            assert_eq!(location.key_path, ["mcp", "servers"]);
            assert_eq!(location.alternate_key_paths, [["mcp"]]);
            assert!(location.other_scopes.is_empty());
        }
    }

    #[test]
    fn a_client_naming_an_unknown_config_is_refused() {
        let text = r#"{"schemaVersion": 1, "serverName": "tablepro", "configs": {},
            "clients": [{"id": "x", "name": "X", "icon": "x", "config": "missing", "clientInfo": {}}]}"#;

        let error = ClientCatalog::parse(text).expect_err("an unknown config");

        assert_eq!(error.code(), "unknown_config");
    }

    #[test]
    fn a_misspelled_field_is_refused() {
        let text = r#"{"schemaVersion": 1, "serverName": "tablepro", "configs": {},
            "clients": [{"id": "x", "name": "X", "icon": "x", "config": null, "clientInfo": {},
            "linux": {"detect": [{"binary": "x", "path": []}]}}]}"#;

        assert_eq!(ClientCatalog::parse(text).expect_err("a typo").code(), "malformed");
    }
}
