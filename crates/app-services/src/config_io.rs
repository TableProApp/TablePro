use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use serde::Serialize;

pub fn xdg_config_path(filename: &str) -> Option<PathBuf> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))?;
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
}
