// The catalog of downloadable drivers. Each entry has the shape of a v3 plugin manifest entry (id, name,
// databaseTypeIds, releases); a release names the driver ABI major and the operating system and processor its
// library is built for, since a driver is one library per platform and architecture.

use serde::Deserialize;
use tablepro_driver_abi::ffi;

use crate::error::PluginError;

pub const SCHEMA_VERSION: u32 = 1;
pub const STABLE: &str = "stable";

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub schema_version: u32,
    pub plugins: Vec<RegistryEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegistryEntry {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub database_type_ids: Vec<String>,
    pub releases: Vec<RegistryRelease>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegistryRelease {
    pub version: String,
    pub build: u64,
    pub channel: String,
    pub abi: u16,
    // std::env::consts::OS and ARCH of the app that loads it: "windows", "x86_64" or "aarch64".
    pub os: String,
    pub arch: String,
    pub url: String,
    pub sha256: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HostTarget {
    pub os: &'static str,
    pub arch: &'static str,
    pub abi_major: u16,
}

impl HostTarget {
    pub fn current() -> Self {
        Self {
            os: std::env::consts::OS,
            arch: std::env::consts::ARCH,
            abi_major: ffi::ABI_MAJOR,
        }
    }
}

pub fn parse_manifest(json: &str) -> Result<Manifest, PluginError> {
    let manifest: Manifest = serde_json::from_str(json).map_err(|error| PluginError::Manifest {
        detail: error.to_string(),
    })?;
    if manifest.schema_version != SCHEMA_VERSION {
        return Err(PluginError::Manifest {
            detail: format!("schema {} is not {SCHEMA_VERSION}", manifest.schema_version),
        });
    }
    Ok(manifest)
}

impl Manifest {
    pub fn entry(&self, id: &str) -> Result<&RegistryEntry, PluginError> {
        self.plugins
            .iter()
            .find(|entry| entry.id == id)
            .ok_or_else(|| PluginError::NoRelease { id: id.to_owned() })
    }
}

impl RegistryEntry {
    // The newest stable build for this platform, processor and ABI major.
    pub fn release_for(&self, target: HostTarget) -> Option<&RegistryRelease> {
        self.releases
            .iter()
            .filter(|release| {
                release.channel == STABLE
                    && release.abi == target.abi_major
                    && release.os == target.os
                    && release.arch == target.arch
            })
            .max_by_key(|release| release.build)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const WINDOWS_X64: HostTarget = HostTarget {
        os: "windows",
        arch: "x86_64",
        abi_major: 1,
    };

    fn manifest() -> Manifest {
        parse_manifest(
            r#"{
              "schemaVersion": 1,
              "serial": 1793000000,
              "plugins": [{
                "id": "sqlite",
                "name": "SQLite",
                "databaseTypeIds": ["sqlite"],
                "releases": [
                  {"version": "0.1.0", "build": 1, "channel": "stable", "abi": 1, "os": "windows", "arch": "x86_64",
                   "url": "https://example.com/1/x64.dll", "sha256": "aa"},
                  {"version": "0.2.0", "build": 2, "channel": "stable", "abi": 1, "os": "windows", "arch": "x86_64",
                   "url": "https://example.com/2/x64.dll", "sha256": "bb"},
                  {"version": "0.2.0", "build": 2, "channel": "stable", "abi": 1, "os": "windows", "arch": "aarch64",
                   "url": "https://example.com/2/arm64.dll", "sha256": "cc"},
                  {"version": "0.3.0-beta.1", "build": 3, "channel": "beta", "abi": 1, "os": "windows",
                   "arch": "x86_64", "url": "https://example.com/3/x64.dll", "sha256": "dd"},
                  {"version": "1.0.0", "build": 4, "channel": "stable", "abi": 2, "os": "windows", "arch": "x86_64",
                   "url": "https://example.com/4/x64.dll", "sha256": "ee"}
                ]
              }]
            }"#,
        )
        .unwrap()
    }

    #[test]
    fn the_newest_stable_release_for_this_processor_and_abi_is_picked() {
        let manifest = manifest();
        let entry = manifest.entry("sqlite").unwrap();

        let release = entry.release_for(WINDOWS_X64).unwrap();

        assert_eq!(release.url, "https://example.com/2/x64.dll");
        assert_eq!(entry.database_type_ids, ["sqlite"]);
    }

    #[test]
    fn the_other_processor_gets_its_own_library() {
        let arm = HostTarget {
            arch: "aarch64",
            ..WINDOWS_X64
        };

        let release = manifest().plugins[0].release_for(arm).cloned().unwrap();

        assert_eq!(release.sha256, "cc");
    }

    #[test]
    fn no_release_for_another_platform() {
        let mac = HostTarget {
            os: "macos",
            arch: "aarch64",
            abi_major: 1,
        };

        assert!(manifest().plugins[0].release_for(mac).is_none());
    }

    #[test]
    fn another_schema_is_refused() {
        let error = parse_manifest(r#"{"schemaVersion": 3, "plugins": []}"#).unwrap_err();

        assert_eq!(error.code(), "plugin.manifest_invalid");
    }

    #[test]
    fn an_unknown_id_has_no_release() {
        assert_eq!(manifest().entry("oracle").unwrap_err().code(), "plugin.no_release");
    }
}
