use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use serde::Serialize;

pub fn xdg_config_path(filename: &str) -> Option<PathBuf> {
    config_path_in(std::env::var_os("XDG_CONFIG_HOME"), std::env::var_os("HOME"), filename)
}

fn config_path_in(
    xdg: Option<std::ffi::OsString>,
    home: Option<std::ffi::OsString>,
    filename: &str,
) -> Option<PathBuf> {
    let base = xdg
        .map(PathBuf::from)
        .or_else(|| home.map(|h| PathBuf::from(h).join(".config")))?;
    Some(base.join(tablepro_storage::storage_dir_name()).join(filename))
}

pub fn backup_file_if_exists(path: &Path, backup: &Path) -> std::io::Result<()> {
    match std::fs::symlink_metadata(backup) {
        Ok(meta) if meta.file_type().is_file() => return Ok(()),
        Ok(_) => return Err(std::io::Error::other("backup path is not a regular file")),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    match std::fs::read(path) {
        Ok(bytes) => atomic_write_bytes(backup, &bytes),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
}

pub fn atomic_write_json<T: Serialize>(path: &Path, value: &T) -> std::io::Result<()> {
    atomic_write_bytes(path, &serde_json::to_vec_pretty(value).map_err(std::io::Error::other)?)
}

pub fn atomic_write_bytes(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
        std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))?;
    }
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if !metadata.file_type().is_file() => {
            return Err(std::io::Error::other("settings path is not a regular file"));
        }
        Ok(_) => std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    write_durably(path, bytes)
}

fn write_durably(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;

    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let name = path
        .file_name()
        .ok_or_else(|| std::io::Error::other("settings path has no file name"))?;
    let mut temp_name = std::ffi::OsString::from(".");
    temp_name.push(name);
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let serial = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    temp_name.push(format!(".tmp-{}-{serial}", std::process::id()));
    let temp = parent.join(temp_name);
    let written = (|| {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        std::fs::rename(&temp, path)?;
        std::fs::File::open(parent)?.sync_all()
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    written
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_rewrite_replaces_the_content_and_leaves_no_temporary_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        atomic_write_bytes(&path, b"first").unwrap();
        atomic_write_bytes(&path, b"second").unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"second");
        let names: Vec<_> = std::fs::read_dir(dir.path())
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        assert_eq!(names, ["settings.json"]);
    }

    #[test]
    fn writes_are_private_and_do_not_follow_symlinks() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        atomic_write_json(&path, &vec![1]).unwrap();
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        let link = dir.path().join("link.json");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(atomic_write_json(&link, &vec![2]).is_err());
        assert_eq!(
            serde_json::from_slice::<Vec<i32>>(&std::fs::read(path).unwrap()).unwrap(),
            vec![1]
        );
    }

    #[test]
    fn the_config_directory_prefers_xdg_then_falls_back_to_home() {
        let name = tablepro_storage::storage_dir_name();
        assert_eq!(
            config_path_in(Some("/xdg".into()), Some("/home/me".into()), "f.json"),
            Some(PathBuf::from("/xdg").join(name).join("f.json"))
        );
        assert_eq!(
            config_path_in(None, Some("/home/me".into()), "f.json"),
            Some(PathBuf::from("/home/me/.config").join(name).join("f.json"))
        );
        assert_eq!(config_path_in(None, None, "f.json"), None);
    }

    #[test]
    fn the_environment_wrapper_agrees_with_the_pure_helper() {
        assert_eq!(
            xdg_config_path("f.json"),
            config_path_in(std::env::var_os("XDG_CONFIG_HOME"), std::env::var_os("HOME"), "f.json")
        );
    }

    #[test]
    fn a_backup_copies_the_current_file_once_and_never_overwrites_it() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        let backup = dir.path().join("settings.json.bak");
        std::fs::write(&path, b"original").unwrap();
        backup_file_if_exists(&path, &backup).unwrap();
        assert_eq!(std::fs::read(&backup).unwrap(), b"original");
        std::fs::write(&path, b"changed").unwrap();
        backup_file_if_exists(&path, &backup).unwrap();
        assert_eq!(std::fs::read(&backup).unwrap(), b"original");
    }

    #[test]
    fn a_missing_file_needs_no_backup() {
        let dir = tempfile::tempdir().unwrap();
        let backup = dir.path().join("settings.json.bak");
        backup_file_if_exists(&dir.path().join("absent.json"), &backup).unwrap();
        assert!(!backup.exists());
    }

    #[test]
    fn a_backup_path_that_is_not_a_regular_file_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::fs::write(&path, b"original").unwrap();
        let backup = dir.path().join("settings.json.bak");
        std::fs::create_dir(&backup).unwrap();
        assert!(backup_file_if_exists(&path, &backup).is_err());
        let link = dir.path().join("link.bak");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(backup_file_if_exists(&path, &link).is_err());
    }

    #[test]
    fn an_unreadable_source_is_an_error_not_a_missing_file() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("a-directory");
        std::fs::create_dir(&source).unwrap();
        assert!(backup_file_if_exists(&source, &dir.path().join("settings.json.bak")).is_err());
    }

    #[test]
    fn a_backup_location_that_cannot_be_inspected_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::fs::write(&path, b"original").unwrap();
        let blocker = dir.path().join("blocker");
        std::fs::write(&blocker, b"a file").unwrap();
        assert!(backup_file_if_exists(&path, &blocker.join("settings.json.bak")).is_err());
    }

    #[test]
    fn a_backup_location_that_denies_inspection_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::fs::write(&path, b"original").unwrap();
        let locked = dir.path().join("locked");
        std::fs::create_dir(&locked).unwrap();
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o000)).unwrap();
        let enforced = std::fs::read_dir(&locked).is_err();
        let result = backup_file_if_exists(&path, &locked.join("settings.json.bak"));
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert!(!enforced || result.is_err());
    }
}
