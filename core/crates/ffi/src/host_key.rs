use std::path::Path;

use tablepro_core::{DriverError, TransportError};
use tablepro_session::connect::ssh_config;
use tablepro_ssh::{ForgetHostKeyError, InProcessSsh};
use uuid::Uuid;

use crate::core_handle::Core;
use crate::error::CoreError;
use crate::library::{ConnectionRecord, apply, blank};
use crate::runtime::on_runtime;

#[uniffi::export]
impl Core {
    pub async fn forget_changed_host_key(
        &self,
        record: ConnectionRecord,
        host: String,
        known_hosts: String,
    ) -> Result<(), CoreError> {
        let ssh = self.ssh.clone();
        on_runtime(&self.tasks, async move {
            forget(&ssh, &record, &host, Path::new(&known_hosts)).await
        })
        .await
    }
}

async fn forget(
    ssh: &InProcessSsh,
    record: &ConnectionRecord,
    host: &str,
    known_hosts: &Path,
) -> Result<(), CoreError> {
    let mut saved = blank(Uuid::new_v4());
    apply(record, record.name.trim().to_owned(), None, &mut saved);
    let settings = saved
        .ssh
        .ok_or_else(|| CoreError::failed("ssh.host_key_not_this_connection", "the connection has no SSH settings"))?;
    let config = ssh_config(&settings).map_err(|error| DriverError::from(TransportError::Ssh(error.into())))?;
    ssh.forget_changed_host_key(&config, host, known_hosts)
        .await
        .map_err(|error| match error {
            ForgetHostKeyError::Ssh(failure) => DriverError::from(TransportError::Ssh(failure)).into(),
            error @ ForgetHostKeyError::NotThisConnection { .. } => {
                CoreError::failed("ssh.host_key_not_this_connection", error.to_string())
            }
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::library::{SshAuthTag, SshSettings};

    #[tokio::test]
    async fn a_host_or_file_outside_this_connection_cannot_be_forgotten() {
        let dir = tempfile::tempdir().unwrap();
        let known_hosts = dir.path().join("known_hosts");
        let contents =
            "[db.internal]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILM+rvN+ot98qgEN796jTiQfZfG1KaT0PtFDJ/XFSqti\n";
        std::fs::write(&known_hosts, contents).unwrap();
        let services = InProcessSsh {
            user_known_hosts: Some(known_hosts.clone()),
            other_known_hosts: Vec::new(),
            identity_files: Vec::new(),
            agent: None,
            pageant: false,
        };
        let mut record = ConnectionRecord::from(&blank(Uuid::new_v4()));
        record.ssh = Some(SshSettings {
            host: "db.internal".to_owned(),
            port: Some(2222),
            username: Some("deploy".to_owned()),
            jump_hosts: Vec::new(),
            auth: SshAuthTag::Agent,
        });

        let wrong_host = forget(&services, &record, "other", &known_hosts).await.unwrap_err();
        let wrong_file = forget(&services, &record, "[db.internal]:2222", &dir.path().join("other"))
            .await
            .unwrap_err();
        assert_eq!(wrong_host.code(), "ssh.host_key_not_this_connection");
        assert_eq!(wrong_file.code(), "ssh.host_key_not_this_connection");
        assert_eq!(std::fs::read_to_string(&known_hosts).unwrap(), contents);

        forget(&services, &record, "[db.internal]:2222", &known_hosts)
            .await
            .unwrap();
        assert_eq!(std::fs::read_to_string(&known_hosts).unwrap(), "");

        record.ssh = None;
        assert_eq!(
            forget(&services, &record, "[db.internal]:2222", &known_hosts)
                .await
                .unwrap_err()
                .code(),
            "ssh.host_key_not_this_connection"
        );
    }
}
