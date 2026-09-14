use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::Arc;

use tablepro_core::SshFailure;

use crate::SshRuntimeCell;

#[derive(Debug, Clone)]
pub struct SshServices {
    pub runtime: Arc<SshRuntimeCell>,
    pub ssh_program: PathBuf,
    pub ssh_keygen_program: PathBuf,
    pub askpass_program: PathBuf,
}

impl SshServices {
    pub fn verify_askpass_helper(&self) -> Result<(), SshFailure> {
        let executable = std::fs::metadata(&self.askpass_program)
            .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0);
        if executable {
            Ok(())
        } else {
            Err(SshFailure::AskpassHelperMissing {
                program: self.askpass_program.clone(),
            })
        }
    }
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

    #[test]
    fn askpass_helper_must_be_an_executable_file() {
        let temp = tempfile::tempdir().unwrap();
        let helper = temp.path().join("tablepro-askpass");

        assert!(matches!(
            services(helper.clone()).verify_askpass_helper(),
            Err(SshFailure::AskpassHelperMissing { .. })
        ));

        std::fs::write(&helper, b"#!/bin/sh\n").unwrap();
        assert!(services(helper.clone()).verify_askpass_helper().is_err());

        std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(services(helper).verify_askpass_helper().is_ok());
    }
}
