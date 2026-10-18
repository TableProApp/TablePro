use std::fs::{DirBuilder, File, OpenOptions};
use std::io;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use rustix::fs::{CWD, Mode, OFlags, fstat, mkdirat, openat};
use rustix::io::Errno;
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
        create_missing_levels(runtime_dir)?;
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

/// Only Flatpak creates `$XDG_RUNTIME_DIR/app/<id>`, and with the
/// variable unset GLib names a directory under the cache instead, so a
/// host install makes the missing levels itself. Each one is made and
/// then opened through its parent's descriptor without following a
/// symlink, and must belong to this user, so a link or a directory
/// planted in the path cannot move the control sockets.
fn create_missing_levels(runtime_dir: &Path) -> Result<(), SshFailure> {
    let missing: Vec<&Path> = runtime_dir
        .ancestors()
        .filter(|dir| !dir.as_os_str().is_empty())
        .take_while(|dir| is_missing(dir))
        .collect();
    let Some(top) = missing.last() else {
        return Ok(());
    };
    let base = top
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let mut parent = openat(
        CWD,
        base,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map_err(|errno| unsafe_dir(base, &errno.into()))?;
    let owner = rustix::process::geteuid().as_raw();
    for dir in missing.into_iter().rev() {
        let Some(name) = dir.file_name() else {
            return Err(SshFailure::RuntimeDirUnsafe {
                path: dir.to_owned(),
                detail: "the path does not end in a directory name".to_owned(),
            });
        };
        match mkdirat(&parent, name, Mode::RWXU) {
            Ok(()) | Err(Errno::EXIST) => {}
            Err(errno) => return Err(unsafe_dir(dir, &errno.into())),
        }
        let child = openat(
            &parent,
            name,
            OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
        )
        .map_err(|errno| unsafe_dir(dir, &errno.into()))?;
        let stat = fstat(&child).map_err(|errno| unsafe_dir(dir, &errno.into()))?;
        if stat.st_uid != owner {
            return Err(SshFailure::RuntimeDirUnsafe {
                path: dir.to_owned(),
                detail: "the directory belongs to another user".to_owned(),
            });
        }
        parent = child;
    }
    Ok(())
}

fn is_missing(path: &Path) -> bool {
    matches!(std::fs::symlink_metadata(path), Err(error) if error.kind() == io::ErrorKind::NotFound)
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
    fn acquire_creates_the_app_levels_a_host_install_lacks() {
        let temp = tempfile::tempdir().unwrap();
        let xdg_runtime = temp.path().join("runtime");
        std::fs::create_dir(&xdg_runtime).unwrap();
        std::fs::set_permissions(&xdg_runtime, std::fs::Permissions::from_mode(0o700)).unwrap();
        let runtime_dir = xdg_runtime.join("app").join("app.tablepro.TablePro");

        let runtime = SshRuntime::acquire(&runtime_dir).unwrap();

        assert_eq!(runtime.root(), runtime_dir.join("ssh"));
        assert_eq!(mode(&xdg_runtime.join("app")), 0o700);
        assert_eq!(mode(&runtime_dir), 0o700);
        assert!(runtime.create_master_dir().is_ok());
    }

    #[test]
    fn acquire_creates_every_level_of_the_cache_fallback() {
        // With XDG_RUNTIME_DIR unset GLib answers the cache directory,
        // which a new account may not have yet either.
        let home = tempfile::tempdir().unwrap();
        let runtime_dir = home.path().join(".cache").join("app").join("app.tablepro.TablePro");

        let runtime = SshRuntime::acquire(&runtime_dir).unwrap();

        for level in [home.path().join(".cache"), home.path().join(".cache/app"), runtime_dir] {
            assert_eq!(mode(&level), 0o700, "{}", level.display());
        }
        assert_eq!(mode(runtime.root()), 0o700);
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
