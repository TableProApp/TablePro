use std::path::PathBuf;

use crate::StorageError;

pub fn storage_dir_name() -> &'static str {
    if option_env!("TABLEPRO_PROFILE") == Some("development") {
        "tablepro-devel"
    } else {
        "tablepro"
    }
}

pub fn secret_schema() -> &'static str {
    if option_env!("TABLEPRO_PROFILE") == Some("development") {
        "com.tablepro.linux.Devel.Password"
    } else {
        "com.tablepro.linux.Password"
    }
}

pub fn config_path(filename: &str) -> Result<PathBuf, StorageError> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
        .ok_or_else(|| StorageError::Schema("neither XDG_CONFIG_HOME nor HOME is set".into()))?;
    Ok(base.join(storage_dir_name()).join(filename))
}

pub fn data_path(filename: &str) -> Result<PathBuf, StorageError> {
    let base = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share")))
        .ok_or_else(|| StorageError::Schema("neither XDG_DATA_HOME nor HOME is set".into()))?;
    Ok(base.join(storage_dir_name()).join(filename))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn profile_paths_and_secrets_share_an_identity() {
        if option_env!("TABLEPRO_PROFILE") == Some("development") {
            assert_eq!(storage_dir_name(), "tablepro-devel");
            assert_eq!(secret_schema(), "com.tablepro.linux.Devel.Password");
        } else {
            assert_eq!(storage_dir_name(), "tablepro");
            assert_eq!(secret_schema(), "com.tablepro.linux.Password");
        }
    }
}
