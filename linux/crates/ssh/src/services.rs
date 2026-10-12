use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use tablepro_core::SshFailure;

use crate::SshRuntimeCell;

/// The file name of the askpass helper ssh runs for every prompt.
pub const ASKPASS_HELPER: &str = "tablepro-askpass";

#[derive(Debug, Clone)]
pub struct SshServices {
    pub runtime: Arc<SshRuntimeCell>,
    pub ssh_program: PathBuf,
    pub ssh_keygen_program: PathBuf,
    pub askpass_program: PathBuf,
}

impl SshServices {
    /// The system OpenSSH client from `PATH`, with control sockets under
    /// `runtime_dir` and the askpass helper found from `libexecdir`.
    pub fn system(runtime_dir: PathBuf, libexecdir: &Path) -> Self {
        let executable_dir = std::env::current_exe()
            .ok()
            .and_then(|path| path.parent().map(Path::to_path_buf));
        Self {
            runtime: Arc::new(SshRuntimeCell::new(runtime_dir)),
            ssh_program: PathBuf::from("ssh"),
            ssh_keygen_program: PathBuf::from("ssh-keygen"),
            askpass_program: locate_askpass(libexecdir, executable_dir.as_deref()),
        }
    }

    pub fn verify_askpass_helper(&self) -> Result<(), SshFailure> {
        if is_executable_file(&self.askpass_program) {
            Ok(())
        } else {
            Err(SshFailure::AskpassHelperMissing {
                program: self.askpass_program.clone(),
            })
        }
    }
}

/// The configured libexec directory wins. A bare `cargo build` never
/// installs there but puts the helper next to the app binary, so that
/// directory is the fallback. When neither has it, the configured path
/// is kept so the missing-helper error names where it belongs.
fn locate_askpass(libexecdir: &Path, executable_dir: Option<&Path>) -> PathBuf {
    let configured = libexecdir.join(ASKPASS_HELPER);
    if is_executable_file(&configured) {
        return configured;
    }
    executable_dir
        .map(|dir| dir.join(ASKPASS_HELPER))
        .filter(|beside| is_executable_file(beside))
        .unwrap_or(configured)
}

fn is_executable_file(path: &Path) -> bool {
    std::fs::metadata(path).is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn services(askpass_program: PathBuf) -> SshServices {
        SshServices {
            runtime: Arc::new(SshRuntimeCell::new(PathBuf::from("/nonexistent"))),
            ssh_program: PathBuf::from("ssh"),
            ssh_keygen_program: PathBuf::from("ssh-keygen"),
            askpass_program,
        }
    }

    fn install_helper(dir: &Path) -> PathBuf {
        let helper = dir.join(ASKPASS_HELPER);
        std::fs::write(&helper, b"#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();
        helper
    }

    #[test]
    fn askpass_helper_must_be_an_executable_file() {
        let temp = tempfile::tempdir().unwrap();
        let helper = temp.path().join(ASKPASS_HELPER);

        assert!(matches!(
            services(helper.clone()).verify_askpass_helper(),
            Err(SshFailure::AskpassHelperMissing { .. })
        ));

        std::fs::write(&helper, b"#!/bin/sh\n").unwrap();
        assert!(services(helper.clone()).verify_askpass_helper().is_err());

        std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(services(helper).verify_askpass_helper().is_ok());
    }

    #[test]
    fn askpass_in_libexecdir_wins_over_the_executable_directory() {
        let libexec = tempfile::tempdir().unwrap();
        let beside = tempfile::tempdir().unwrap();
        let installed = install_helper(libexec.path());
        install_helper(beside.path());

        assert_eq!(locate_askpass(libexec.path(), Some(beside.path())), installed);
    }

    #[test]
    fn askpass_falls_back_to_the_executable_directory() {
        let libexec = tempfile::tempdir().unwrap();
        let beside = tempfile::tempdir().unwrap();
        let built = install_helper(beside.path());

        let located = locate_askpass(libexec.path(), Some(beside.path()));

        assert_eq!(located, built);
        assert!(services(located).verify_askpass_helper().is_ok());
    }

    #[test]
    fn a_missing_helper_is_reported_at_the_configured_path() {
        let libexec = tempfile::tempdir().unwrap();
        let beside = tempfile::tempdir().unwrap();

        let located = locate_askpass(libexec.path(), Some(beside.path()));

        assert_eq!(located, libexec.path().join(ASKPASS_HELPER));
        assert_eq!(locate_askpass(libexec.path(), None), located);
    }

    #[test]
    fn system_services_run_the_openssh_client_from_path() {
        let libexec = tempfile::tempdir().unwrap();
        let installed = install_helper(libexec.path());

        let services = SshServices::system(PathBuf::from("/run/user/1000/tablepro"), libexec.path());

        assert_eq!(services.ssh_program, Path::new("ssh"));
        assert_eq!(services.ssh_keygen_program, Path::new("ssh-keygen"));
        assert_eq!(services.askpass_program, installed);
    }
}
