mod chord;

use std::collections::HashSet;

use serde::Deserialize;

pub use chord::Chord;

const BUNDLED: &str = include_str!("../../keymaps.json");

pub const SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Deserialize)]
pub enum Platform {
    #[serde(rename = "macos")]
    MacOs,
    #[serde(rename = "linux")]
    Linux,
    #[serde(rename = "windows")]
    Windows,
}

// Named after the macOS app's ShortcutAction raw values, so the macOS app reads the file with no table of its own.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum KeymapAction {
    ExecuteQuery,
    ExecuteAllStatements,
    ExplainQuery,
    FormatQuery,
    NewTab,
    CloseTab,
    ShowNextTab,
    ShowPreviousTab,
    Refresh,
    NewConnection,
    QuickSwitcher,
    ToggleTableBrowser,
    SaveChanges,
    AddRow,
    Delete,
    DuplicateRow,
    ToggleFilters,
    Find,
    FindAndReplace,
    ToggleHistory,
    CancelQuery,
    CommitTransaction,
    DiscardChanges,
    ShowSettings,
}

impl KeymapAction {
    pub const ALL: [Self; 24] = [
        Self::ExecuteQuery,
        Self::ExecuteAllStatements,
        Self::ExplainQuery,
        Self::FormatQuery,
        Self::NewTab,
        Self::CloseTab,
        Self::ShowNextTab,
        Self::ShowPreviousTab,
        Self::Refresh,
        Self::NewConnection,
        Self::QuickSwitcher,
        Self::ToggleTableBrowser,
        Self::SaveChanges,
        Self::AddRow,
        Self::Delete,
        Self::DuplicateRow,
        Self::ToggleFilters,
        Self::Find,
        Self::FindAndReplace,
        Self::ToggleHistory,
        Self::CancelQuery,
        Self::CommitTransaction,
        Self::DiscardChanges,
        Self::ShowSettings,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::ExecuteQuery => "executeQuery",
            Self::ExecuteAllStatements => "executeAllStatements",
            Self::ExplainQuery => "explainQuery",
            Self::FormatQuery => "formatQuery",
            Self::NewTab => "newTab",
            Self::CloseTab => "closeTab",
            Self::ShowNextTab => "showNextTab",
            Self::ShowPreviousTab => "showPreviousTab",
            Self::Refresh => "refresh",
            Self::NewConnection => "newConnection",
            Self::QuickSwitcher => "quickSwitcher",
            Self::ToggleTableBrowser => "toggleTableBrowser",
            Self::SaveChanges => "saveChanges",
            Self::AddRow => "addRow",
            Self::Delete => "delete",
            Self::DuplicateRow => "duplicateRow",
            Self::ToggleFilters => "toggleFilters",
            Self::Find => "find",
            Self::FindAndReplace => "findAndReplace",
            Self::ToggleHistory => "toggleHistory",
            Self::CancelQuery => "cancelQuery",
            Self::CommitTransaction => "commitTransaction",
            Self::DiscardChanges => "discardChanges",
            Self::ShowSettings => "showSettings",
        }
    }

    pub fn from_name(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|action| action.as_str() == name)
    }

    // Discarding every pending edit has no macOS command, and macOS keeps Settings on its reserved Cmd-comma.
    pub fn has_macos_action(self) -> bool {
        !matches!(self, Self::DiscardChanges | Self::ShowSettings)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedBinding {
    pub action: KeymapAction,
    pub chord: Chord,
    pub derived: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PresetSummary {
    pub id: String,
    pub name: String,
    pub platforms: Vec<Platform>,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum KeymapError {
    #[error("the keymap file has schema version {0}")]
    UnsupportedSchema(u32),
    #[error("the keymap file is not valid at line {line}, column {column}: {detail}")]
    Malformed { line: usize, column: usize, detail: String },
    #[error("preset {preset} binds {action} to {chord}, which is not a chord")]
    InvalidChord {
        preset: String,
        action: String,
        chord: String,
    },
    #[error("preset {0} is listed twice")]
    DuplicatePreset(String),
    #[error("there is no preset {0}")]
    UnknownPreset(String),
    #[error("preset {preset} is not offered on {platform:?}")]
    NotOnPlatform { preset: String, platform: Platform },
}

impl KeymapError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::UnsupportedSchema(_) => "keymap.unsupported_schema",
            Self::Malformed { .. } => "keymap.malformed",
            Self::InvalidChord { .. } => "keymap.invalid_chord",
            Self::DuplicatePreset(_) => "keymap.duplicate_preset",
            Self::UnknownPreset(_) => "keymap.unknown_preset",
            Self::NotOnPlatform { .. } => "keymap.not_on_platform",
        }
    }

    fn malformed(error: &serde_json::Error) -> Self {
        Self::Malformed {
            line: error.line(),
            column: error.column(),
            detail: error.to_string(),
        }
    }
}

// Read before the full parse, so a file of a later schema says so instead of failing on a field it added.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SchemaProbe {
    schema_version: u32,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct KeymapFile {
    #[serde(rename = "schemaVersion")]
    _schema_version: u32,
    presets: Vec<PresetEntry>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PresetEntry {
    id: String,
    name: String,
    platforms: Vec<Platform>,
    bindings: Vec<BindingEntry>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BindingEntry {
    action: KeymapAction,
    key: Option<String>,
    mac: Option<String>,
    linux: Option<String>,
    windows: Option<String>,
    #[serde(default)]
    derived: bool,
}

#[derive(Debug, Clone)]
struct Binding {
    action: KeymapAction,
    key: Option<Chord>,
    mac: Option<Chord>,
    linux: Option<Chord>,
    windows: Option<Chord>,
    derived: bool,
}

impl Binding {
    fn chord(&self, platform: Platform) -> Option<&Chord> {
        let own = match platform {
            Platform::MacOs => self.mac.as_ref(),
            Platform::Linux => self.linux.as_ref(),
            Platform::Windows => self.windows.as_ref(),
        };
        own.or(self.key.as_ref())
    }
}

#[derive(Debug, Clone)]
struct Preset {
    id: String,
    name: String,
    platforms: Vec<Platform>,
    bindings: Vec<Binding>,
}

#[derive(Debug, Clone)]
pub struct Keymap {
    presets: Vec<Preset>,
}

impl Keymap {
    // The file every app ships, compiled into this crate.
    pub fn bundled() -> Result<Self, KeymapError> {
        Self::parse(BUNDLED)
    }

    pub fn parse(text: &str) -> Result<Self, KeymapError> {
        let probe: SchemaProbe = serde_json::from_str(text).map_err(|error| KeymapError::malformed(&error))?;
        if probe.schema_version != SCHEMA_VERSION {
            return Err(KeymapError::UnsupportedSchema(probe.schema_version));
        }
        let file: KeymapFile = serde_json::from_str(text).map_err(|error| KeymapError::malformed(&error))?;
        let mut ids = HashSet::new();
        let mut presets = Vec::with_capacity(file.presets.len());
        for entry in file.presets {
            if !ids.insert(entry.id.clone()) {
                return Err(KeymapError::DuplicatePreset(entry.id));
            }
            let bindings = entry
                .bindings
                .into_iter()
                .map(|binding| read_binding(&entry.id, binding))
                .collect::<Result<_, _>>()?;
            presets.push(Preset {
                id: entry.id,
                name: entry.name,
                platforms: entry.platforms,
                bindings,
            });
        }
        Ok(Self { presets })
    }

    pub fn presets(&self) -> Vec<PresetSummary> {
        self.presets
            .iter()
            .map(|preset| PresetSummary {
                id: preset.id.clone(),
                name: preset.name.clone(),
                platforms: preset.platforms.clone(),
            })
            .collect()
    }

    pub fn preset_ids(&self, platform: Platform) -> Vec<String> {
        self.presets
            .iter()
            .filter(|preset| preset.platforms.contains(&platform))
            .map(|preset| preset.id.clone())
            .collect()
    }

    pub fn preset(&self, id: &str, platform: Platform) -> Result<Vec<ResolvedBinding>, KeymapError> {
        let preset = self
            .presets
            .iter()
            .find(|preset| preset.id == id)
            .ok_or_else(|| KeymapError::UnknownPreset(id.to_owned()))?;
        if !preset.platforms.contains(&platform) {
            return Err(KeymapError::NotOnPlatform {
                preset: preset.id.clone(),
                platform,
            });
        }
        Ok(preset
            .bindings
            .iter()
            .filter(|binding| platform != Platform::MacOs || binding.action.has_macos_action())
            .filter_map(|binding| {
                binding.chord(platform).map(|chord| ResolvedBinding {
                    action: binding.action,
                    chord: chord.clone(),
                    derived: binding.derived && platform != Platform::MacOs,
                })
            })
            .collect())
    }
}

fn read_binding(preset: &str, entry: BindingEntry) -> Result<Binding, KeymapError> {
    let action = entry.action;
    let read = |text: Option<String>, allows_cmd: bool| -> Result<Option<Chord>, KeymapError> {
        let Some(text) = text else {
            return Ok(None);
        };
        match Chord::parse(&text) {
            Ok(chord) if allows_cmd || !chord.cmd => Ok(Some(chord)),
            _ => Err(KeymapError::InvalidChord {
                preset: preset.to_owned(),
                action: action.as_str().to_owned(),
                chord: text,
            }),
        }
    };
    Ok(Binding {
        action,
        key: read(entry.key, false)?,
        mac: read(entry.mac, true)?,
        linux: read(entry.linux, false)?,
        windows: read(entry.windows, false)?,
        derived: entry.derived,
    })
}

pub fn presets() -> Result<Vec<PresetSummary>, KeymapError> {
    Ok(Keymap::bundled()?.presets())
}

pub fn preset_ids(platform: Platform) -> Result<Vec<String>, KeymapError> {
    Ok(Keymap::bundled()?.preset_ids(platform))
}

pub fn preset(id: &str, platform: Platform) -> Result<Vec<ResolvedBinding>, KeymapError> {
    Keymap::bundled()?.preset(id, platform)
}
