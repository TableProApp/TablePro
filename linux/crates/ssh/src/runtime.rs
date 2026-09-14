use std::fs::{DirBuilder, File, OpenOptions};
use std::io;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use tablepro_core::SshFailure;
use uuid::Uuid;

#[derive(Debug)]
pub struct SshRuntime {
    root: PathBuf,
    instance_dir: PathBuf,
    instance_id: String,
    _lock: File,
}

impl SshRuntime {
    pub fn acquire(runtime_dir: &Path) -> Result<Arc<SshRuntime>, SshFailure> {
        let root = runtime_dir.join("ssh");
        let root_metadata = private_dir(&root)?;
        let (instance_id, instance_dir) = create_unique_dir(&root, 8)?;
        let instance_metadata =
            std::fs::symlink_metadata(&instance_dir).map_err(|error| unsafe_dir(&instance_dir, &error))?;
        if instance_metadata.uid() != root_metadata.uid() {
            let _ = std::fs::remove_dir(&instance_dir);
            return Err(SshFailure::RuntimeDirUnsafe {
                path: root,
                detail: "the directory belongs to another user".to_owned(),
            });
        }
        let lock_path = instance_dir.join("lock");
        let lock = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&lock_path)
            .map_err(|error| unsafe_dir(&lock_path, &error))?;
        lock.try_lock().map_err(|error| SshFailure::RuntimeDirUnsafe {
            path: lock_path,
            detail: error.to_string(),
        })?;
        Ok(Arc::new(Self {
            root,
            instance_dir,
            instance_id,
            _lock: lock,
        }))
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn instance_dir(&self) -> &Path {
        &self.instance_dir
    }

    pub fn instance_id(&self) -> &str {
        &self.instance_id
    }

    pub(crate) fn create_master_dir(&self) -> Result<PathBuf, SshFailure> {
        create_unique_dir(&self.instance_dir, 4).map(|(_, dir)| dir)
    }
}

fn private_dir(path: &Path) -> Result<std::fs::Metadata, SshFailure> {
    match DirBuilder::new().mode(0o700).create(path) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(unsafe_dir(path, &error)),
    }
    let metadata = std::fs::symlink_metadata(path).map_err(|error| unsafe_dir(path, &error))?;
    if !metadata.is_dir() {
        return Err(SshFailure::RuntimeDirUnsafe {
            path: path.to_owned(),
            detail: "the path is not a directory".to_owned(),
        });
    }
    if metadata.mode() & 0o077 != 0 {
        return Err(SshFailure::RuntimeDirUnsafe {
            path: path.to_owned(),
            detail: format!("the directory mode is {:o}, expected 700", metadata.mode() & 0o777),
        });
    }
    Ok(metadata)
}

fn create_unique_dir(parent: &Path, id_bytes: usize) -> Result<(String, PathBuf), SshFailure> {
    loop {
        let id: String = Uuid::new_v4()
            .into_bytes()
            .iter()
            .take(id_bytes)
            .map(|byte| format!("{byte:02x}"))
            .collect();
        let dir = parent.join(&id);
        match DirBuilder::new().mode(0o700).create(&dir) {
            Ok(()) => return Ok((id, dir)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(unsafe_dir(&dir, &error)),
        }
    }
}

fn unsafe_dir(path: &Path, error: &io::Error) -> SshFailure {
    SshFailure::RuntimeDirUnsafe {
        path: path.to_owned(),
        detail: error.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use std::fs::TryLockError;
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    fn mode(path: &Path) -> u32 {
        std::fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    #[test]
    fn runtime_acquire_creates_0700_and_holds_lock() {
        let temp = tempfile::tempdir().unwrap();
        let runtime = SshRuntime::acquire(temp.path()).unwrap();

        assert_eq!(runtime.root(), temp.path().join("ssh"));
        assert_eq!(mode(runtime.root()), 0o700);
        assert_eq!(mode(runtime.instance_dir()), 0o700);
        assert_eq!(runtime.instance_id().len(), 16);
        let lock_path = runtime.instance_dir().join("lock");
        assert_eq!(mode(&lock_path), 0o600);

        let other = File::open(&lock_path).unwrap();
        assert!(matches!(other.try_lock(), Err(TryLockError::WouldBlock)));

        let master = runtime.create_master_dir().unwrap();
        assert_eq!(master.parent(), Some(runtime.instance_dir()));
        assert_eq!(mode(&master), 0o700);
    }

    #[test]
    fn second_acquire_gets_distinct_instance() {
        let temp = tempfile::tempdir().unwrap();
        let first = SshRuntime::acquire(temp.path()).unwrap();
        let second = SshRuntime::acquire(temp.path()).unwrap();
        assert_ne!(first.instance_dir(), second.instance_dir());
    }

    #[test]
    fn group_writable_root_is_unsafe() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("ssh");
        std::fs::create_dir(&root).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o770)).unwrap();
        assert!(matches!(
            SshRuntime::acquire(temp.path()),
            Err(SshFailure::RuntimeDirUnsafe { .. })
        ));
    }
}
