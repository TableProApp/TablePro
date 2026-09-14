use std::fs::{File, OpenOptions, TryLockError};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, SystemTime};

use tokio::process::Command;

use crate::SshServices;
use crate::argv::{ControlOp, control_args};

const MIN_STALE_AGE: Duration = Duration::from_secs(10);

struct StaleInstance {
    dir: PathBuf,
    control_sockets: Vec<PathBuf>,
    _lock: File,
}

pub async fn sweep_stale_masters(services: &SshServices) -> usize {
    let runtime = match services.runtime.get().await {
        Ok(runtime) => runtime,
        Err(error) => {
            tracing::warn!(%error, "skipped the stale ssh master sweep");
            return 0;
        }
    };
    let root = runtime.root().to_owned();
    let own_id = runtime.instance_id().to_owned();
    let stale = tokio::task::spawn_blocking(move || stale_instances(&root, &own_id))
        .await
        .unwrap_or_default();

    let mut removed = 0;
    for instance in stale {
        for control in &instance.control_sockets {
            let exited = Command::new(&services.ssh_program)
                .args(control_args(control, ControlOp::Exit))
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .await;
            if let Err(error) = exited {
                tracing::debug!(%error, control = %control.display(), "could not ask a stale ssh master to exit");
            }
        }
        let dir = instance.dir.clone();
        let removal = tokio::task::spawn_blocking(move || std::fs::remove_dir_all(dir)).await;
        match removal {
            Ok(Ok(())) => removed += 1,
            Ok(Err(error)) => {
                tracing::warn!(%error, dir = %instance.dir.display(), "could not remove a stale ssh instance")
            }
            Err(error) => tracing::warn!(%error, "the stale ssh instance removal task failed"),
        }
    }
    removed
}

fn stale_instances(root: &Path, own_id: &str) -> Vec<StaleInstance> {
    let Ok(entries) = std::fs::read_dir(root) else {
        return Vec::new();
    };
    entries
        .filter_map(Result::ok)
        .filter(|entry| entry.file_name() != own_id && entry.file_type().is_ok_and(|kind| kind.is_dir()))
        .filter_map(|entry| stale_instance(entry.path()))
        .collect()
}

fn stale_instance(dir: PathBuf) -> Option<StaleInstance> {
    let lock = OpenOptions::new().read(true).write(true).open(dir.join("lock")).ok()?;
    let age = lock
        .metadata()
        .and_then(|metadata| metadata.modified())
        .ok()
        .and_then(|modified| SystemTime::now().duration_since(modified).ok())?;
    if age < MIN_STALE_AGE {
        return None;
    }
    match lock.try_lock() {
        Ok(()) => {}
        Err(TryLockError::WouldBlock) => return None,
        Err(TryLockError::Error(error)) => {
            tracing::debug!(%error, dir = %dir.display(), "could not lock an ssh instance");
            return None;
        }
    }
    let control_sockets = std::fs::read_dir(&dir)
        .map(|entries| {
            entries
                .filter_map(Result::ok)
                .map(|entry| entry.path().join("control"))
                .filter(|control| control.exists())
                .collect()
        })
        .unwrap_or_default();
    Some(StaleInstance {
        dir,
        control_sockets,
        _lock: lock,
    })
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;
    use crate::{SshRuntime, SshRuntimeCell};

    fn services(runtime_dir: &Path) -> SshServices {
        SshServices {
            runtime: Arc::new(SshRuntimeCell::new(runtime_dir.to_owned())),
            ssh_program: PathBuf::from("true"),
            ssh_keygen_program: PathBuf::from("true"),
            askpass_program: PathBuf::from("/nonexistent"),
        }
    }

    fn stale_dir(root: &Path, id: &str, age: Duration) -> PathBuf {
        let dir = root.join(id);
        std::fs::create_dir_all(dir.join("0badc0de")).unwrap();
        std::fs::write(dir.join("0badc0de").join("control"), b"").unwrap();
        let lock = File::create(dir.join("lock")).unwrap();
        lock.set_modified(SystemTime::now() - age).unwrap();
        dir
    }

    #[tokio::test]
    async fn sweep_skips_locked_and_removes_unlocked_instance() {
        let temp = tempfile::tempdir().unwrap();
        let live = SshRuntime::acquire(temp.path()).unwrap();
        let root = live.root().to_owned();
        let stale = stale_dir(&root, "00000000deadbeef", Duration::from_secs(3600));
        let fresh = stale_dir(&root, "00000000feedface", Duration::ZERO);

        let sweeper = services(temp.path());
        assert_eq!(sweep_stale_masters(&sweeper).await, 1);

        assert!(!stale.exists());
        assert!(fresh.exists());
        assert!(live.instance_dir().exists());
        let own = sweeper.runtime.get().await.unwrap();
        assert!(own.instance_dir().exists());
    }
}
