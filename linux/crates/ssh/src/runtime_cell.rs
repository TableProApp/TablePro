use std::path::PathBuf;
use std::sync::Arc;

use tablepro_core::SshFailure;
use tokio::sync::OnceCell;

use crate::SshRuntime;

#[derive(Debug)]
pub struct SshRuntimeCell {
    runtime_dir: PathBuf,
    cell: OnceCell<Arc<SshRuntime>>,
}

impl SshRuntimeCell {
    pub fn new(runtime_dir: PathBuf) -> Self {
        Self {
            runtime_dir,
            cell: OnceCell::new(),
        }
    }

    pub async fn get(&self) -> Result<Arc<SshRuntime>, SshFailure> {
        self.cell
            .get_or_try_init(|| async {
                let runtime_dir = self.runtime_dir.clone();
                tokio::task::spawn_blocking(move || SshRuntime::acquire(&runtime_dir))
                    .await
                    .map_err(|error| SshFailure::RuntimeDirUnsafe {
                        path: self.runtime_dir.clone(),
                        detail: format!("the runtime setup task failed: {error}"),
                    })?
            })
            .await
            .cloned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn runtime_cell_retries_after_error() {
        let temp = tempfile::tempdir().unwrap();
        let runtime_dir = temp.path().join("runtime");
        std::fs::write(&runtime_dir, b"not a directory").unwrap();
        let cell = SshRuntimeCell::new(runtime_dir.clone());

        assert!(cell.get().await.is_err());

        std::fs::remove_file(&runtime_dir).unwrap();
        std::fs::create_dir(&runtime_dir).unwrap();
        let first = cell.get().await.unwrap();
        let second = cell.get().await.unwrap();
        assert!(Arc::ptr_eq(&first, &second));
    }
}
