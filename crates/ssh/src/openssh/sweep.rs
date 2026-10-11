use std::fs::{File, OpenOptions, TryLockError};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, SystemTime};

use tokio::process::Command;

use super::OpenSshRuntime;
use super::argv::{ControlOp, control_args};
use super::runtime::LOCK_FILE;

const MIN_STALE_AGE: Duration = Duration::from_secs(10);
const CONTROL_EXIT_TIMEOUT: Duration = Duration::from_secs(5);

struct StaleInstance {
    dir: PathBuf,
    control_sockets: Vec<PathBuf>,
    _lock: File,
}

pub async fn sweep_stale_masters(runtime: &OpenSshRuntime, ssh_program: &Path) -> usize {
    let root = runtime.root().to_owned();
    let own_id = runtime.instance_id().to_owned();
    let stale = tokio::task::spawn_blocking(move || stale_instances(&root, &own_id))
        .await
        .unwrap_or_default();
    let mut removed = 0;
    for instance in stale {
        for control in &instance.control_sockets {
            exit_master(ssh_program, control).await;
        }
        let dir = instance.dir.clone();
        match tokio::task::spawn_blocking(move || std::fs::remove_dir_all(dir)).await {
            Ok(Ok(())) => removed += 1,
            Ok(Err(error)) => tracing::warn!(%error, "could not remove a stale ssh instance"),
            Err(error) => tracing::warn!(%error, "the stale ssh instance removal task failed"),
        }
    }
    removed
}

async fn exit_master(ssh_program: &Path, control: &Path) {
    let exited = Command::new(ssh_program)
        .args(control_args(control, ControlOp::Exit))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .status();
    match tokio::time::timeout(CONTROL_EXIT_TIMEOUT, exited).await {
        Ok(Ok(_)) => {}
        Ok(Err(error)) => tracing::debug!(%error, "could not ask a stale ssh master to exit"),
        Err(_) => tracing::debug!("a stale ssh master did not answer ssh -O exit"),
    }
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
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .open(dir.join(LOCK_FILE))
        .ok()?;
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
            tracing::debug!(%error, "could not lock an ssh instance");
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
    use super::*;

    fn stale_dir(root: &Path, id: &str, age: Duration) -> PathBuf {
        let dir = root.join(id);
        std::fs::create_dir_all(dir.join("0badc0de")).unwrap();
        std::fs::write(dir.join("0badc0de").join("control"), b"").unwrap();
        let lock = File::create(dir.join(LOCK_FILE)).unwrap();
        lock.set_modified(SystemTime::now() - age).unwrap();
        dir
    }

    #[tokio::test]
    async fn the_sweep_removes_unlocked_old_instances_and_keeps_live_and_fresh_ones() {
        let temp = tempfile::tempdir().unwrap();
        let live = OpenSshRuntime::acquire(temp.path()).unwrap();
        let sweeper = OpenSshRuntime::acquire(temp.path()).unwrap();
        let stale = stale_dir(live.root(), "00000000deadbeef", Duration::from_secs(3600));
        let fresh = stale_dir(live.root(), "00000000feedface", Duration::ZERO);
        let live_lock = live.instance_dir().join(LOCK_FILE);
        File::open(&live_lock)
            .unwrap()
            .set_modified(SystemTime::now() - Duration::from_secs(3600))
            .unwrap();

        assert_eq!(sweep_stale_masters(&sweeper, Path::new("true")).await, 1);

        assert!(!stale.exists());
        assert!(fresh.exists());
        assert!(live.instance_dir().exists());
        assert!(sweeper.instance_dir().exists());
    }
}
