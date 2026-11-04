use std::path::{Path, PathBuf};

use tablepro_core::SshFailure;

use super::known_hosts::{forget_host, lookup_name};
use crate::{ForgetHostKeyError, SshConfig, SshDestination};

// OpenSSH's default identities, less the security keys nothing in process can sign with.
const DEFAULT_IDENTITIES: [&str; 3] = ["id_rsa", "id_ecdsa", "id_ed25519"];

#[cfg(windows)]
const OPENSSH_AGENT_PIPE: &str = r"\\.\pipe\openssh-ssh-agent";

// SSH in this process, where OpenSSH cannot run a ControlMaster (core ADR 0009).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InProcessSsh {
    // Read first, and where a key the user trusts is written.
    pub user_known_hosts: Option<PathBuf>,
    pub other_known_hosts: Vec<PathBuf>,
    // Tried when the connection names no key file, as OpenSSH does.
    pub identity_files: Vec<PathBuf>,
    // A Unix socket, or on Windows a named pipe.
    pub agent: Option<PathBuf>,
    // Windows: ask Pageant when nothing answers at `agent`.
    pub pageant: bool,
}

impl InProcessSsh {
    pub fn system() -> Self {
        let ssh_dir = std::env::home_dir()
            .filter(|home| home.is_absolute())
            .map(|home| home.join(".ssh"));
        let mut other_known_hosts: Vec<PathBuf> = ssh_dir.iter().map(|dir| dir.join("known_hosts2")).collect();
        other_known_hosts.extend(global_known_hosts());
        Self {
            user_known_hosts: ssh_dir.as_ref().map(|dir| dir.join("known_hosts")),
            other_known_hosts,
            identity_files: ssh_dir
                .iter()
                .flat_map(|dir| DEFAULT_IDENTITIES.iter().map(move |name| dir.join(name)))
                .collect(),
            agent: agent_from_environment(),
            pageant: cfg!(windows),
        }
    }

    pub(crate) fn known_hosts_files(&self) -> impl Iterator<Item = &Path> {
        self.user_known_hosts
            .iter()
            .chain(&self.other_known_hosts)
            .map(PathBuf::as_path)
    }

    // `host` and `known_hosts` come back from the app, so both are checked against this connection.
    pub async fn forget_changed_host_key(
        &self,
        config: &SshConfig,
        host: &str,
        known_hosts: &Path,
    ) -> Result<(), ForgetHostKeyError> {
        let ours = config
            .jump_hosts
            .iter()
            .chain([&config.destination])
            .any(|hop| hop_lookup_name(hop).eq_ignore_ascii_case(host));
        let read = self.known_hosts_files().any(|file| file == known_hosts);
        if !ours || !read {
            return Err(ForgetHostKeyError::NotThisConnection {
                host: host.to_owned(),
                known_hosts: known_hosts.to_owned(),
            });
        }
        let path = known_hosts.to_owned();
        let name = host.to_owned();
        let removed = tokio::task::spawn_blocking(move || forget_host(&path, &name))
            .await
            .map_err(|error| crate::setup_task_failed(&error))?;
        removed.map_err(|error| {
            ForgetHostKeyError::Ssh(SshFailure::KnownHostsUnwritable {
                path: known_hosts.to_owned(),
                kind: error.kind(),
            })
        })
    }
}

pub(crate) fn hop_lookup_name(hop: &SshDestination) -> String {
    lookup_name(hop.host(), hop.port().unwrap_or(22))
}

fn agent_from_environment() -> Option<PathBuf> {
    let named = std::env::var_os("SSH_AUTH_SOCK")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from);
    #[cfg(windows)]
    let named = named.or_else(|| Some(PathBuf::from(OPENSSH_AGENT_PIPE)));
    named
}

#[cfg(unix)]
fn global_known_hosts() -> Vec<PathBuf> {
    ["/etc/ssh/ssh_known_hosts", "/etc/ssh/ssh_known_hosts2"]
        .into_iter()
        .map(PathBuf::from)
        .collect()
}

// Win32-OpenSSH keeps its system files under %ProgramData%\ssh.
#[cfg(not(unix))]
fn global_known_hosts() -> Vec<PathBuf> {
    std::env::var_os("ProgramData")
        .map(PathBuf::from)
        .filter(|dir| dir.is_absolute())
        .map(|dir| {
            let ssh = dir.join("ssh");
            vec![ssh.join("ssh_known_hosts"), ssh.join("ssh_known_hosts2")]
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::SshAuth;

    fn config(destination: &str, jumps: &str) -> SshConfig {
        SshConfig {
            destination: SshDestination::parse_jump_list(destination).unwrap().remove(0),
            jump_hosts: SshDestination::parse_jump_list(jumps).unwrap(),
            auth: SshAuth::Agent,
        }
    }

    fn services(dir: &Path) -> InProcessSsh {
        InProcessSsh {
            user_known_hosts: Some(dir.join("known_hosts")),
            other_known_hosts: vec![dir.join("global")],
            identity_files: Vec::new(),
            agent: None,
            pageant: false,
        }
    }

    #[test]
    fn the_system_files_are_absolute_and_the_user_file_comes_first() {
        let system = InProcessSsh::system();

        assert!(system.known_hosts_files().all(Path::is_absolute));
        if let Some(user) = &system.user_known_hosts {
            assert_eq!(system.known_hosts_files().next(), Some(user.as_path()));
            assert!(user.ends_with(Path::new(".ssh").join("known_hosts")));
        }
        assert!(system.identity_files.iter().all(|file| file.is_absolute()));
    }

    #[tokio::test]
    async fn only_a_host_of_this_connection_in_a_file_it_reads_is_forgotten() {
        let dir = tempfile::tempdir().unwrap();
        let services = services(dir.path());
        let known_hosts = dir.path().join("known_hosts");
        std::fs::write(
            &known_hosts,
            "[db.internal]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILM+rvN+ot98qgEN796jTiQfZfG1KaT0PtFDJ/XFSqti\n\
             jump1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILM+rvN+ot98qgEN796jTiQfZfG1KaT0PtFDJ/XFSqti\n",
        )
        .unwrap();
        let config = config("deploy@db.internal:2222", "ops@jump1");

        let elsewhere = services.forget_changed_host_key(&config, "other", &known_hosts).await;
        let unread = services
            .forget_changed_host_key(&config, "jump1", &dir.path().join("elsewhere"))
            .await;
        services
            .forget_changed_host_key(&config, "jump1", &known_hosts)
            .await
            .unwrap();

        assert!(matches!(elsewhere, Err(ForgetHostKeyError::NotThisConnection { .. })));
        assert!(matches!(unread, Err(ForgetHostKeyError::NotThisConnection { .. })));
        let left = std::fs::read_to_string(&known_hosts).unwrap();
        assert!(left.starts_with("[db.internal]:2222 "), "{left}");
        assert!(!left.contains("jump1"), "{left}");
    }
}
