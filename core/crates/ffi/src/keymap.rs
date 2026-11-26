use tablepro_core::keymap::{self, KeymapError, Platform, ResolvedBinding};

use crate::error::CoreError;

// The platform is the caller's, never the build target's, so any host reads any platform's rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum KeymapPlatformTag {
    MacOs,
    Linux,
    Windows,
}

impl From<KeymapPlatformTag> for Platform {
    fn from(platform: KeymapPlatformTag) -> Self {
        match platform {
            KeymapPlatformTag::MacOs => Self::MacOs,
            KeymapPlatformTag::Linux => Self::Linux,
            KeymapPlatformTag::Windows => Self::Windows,
        }
    }
}

// `action` is the name the keymap file uses, so a new action needs no change to the generated bindings.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct KeymapBindingInfo {
    pub action: String,
    pub key: String,
    pub ctrl: bool,
    pub shift: bool,
    pub alt: bool,
    pub cmd: bool,
    // Read as Cmd to Ctrl from the source app's macOS keys, which it published alone.
    pub derived: bool,
}

impl From<ResolvedBinding> for KeymapBindingInfo {
    fn from(binding: ResolvedBinding) -> Self {
        Self {
            action: binding.action.as_str().to_owned(),
            key: binding.chord.key,
            ctrl: binding.chord.ctrl,
            shift: binding.chord.shift,
            alt: binding.chord.alt,
            cmd: binding.chord.cmd,
            derived: binding.derived,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct KeymapPresetInfo {
    pub id: String,
    pub name: String,
}

fn keymap_error(error: KeymapError) -> CoreError {
    CoreError::failed(error.code(), error.to_string())
}

// Fails with a keymap.* code.
#[uniffi::export]
pub fn keymap_preset(id: String, platform: KeymapPlatformTag) -> Result<Vec<KeymapBindingInfo>, CoreError> {
    Ok(keymap::preset(&id, platform.into())
        .map_err(keymap_error)?
        .into_iter()
        .map(KeymapBindingInfo::from)
        .collect())
}

#[uniffi::export]
pub fn keymap_presets(platform: KeymapPlatformTag) -> Result<Vec<KeymapPresetInfo>, CoreError> {
    let platform = Platform::from(platform);
    Ok(keymap::presets()
        .map_err(keymap_error)?
        .into_iter()
        .filter(|preset| preset.platforms.contains(&platform))
        .map(|preset| KeymapPresetInfo {
            id: preset.id,
            name: preset.name,
        })
        .collect())
}
