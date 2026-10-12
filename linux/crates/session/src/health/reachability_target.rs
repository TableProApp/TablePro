use std::net::IpAddr;

use tablepro_core::NetworkEndpoint;

use crate::connect::{ConnectRequest, RequestTarget};
use crate::link::EstablishedConnection;

const SSH_PORT: u16 = 22;

/// What the network has to reach for a session to work.
///
/// A local target is never gated on reachability: a file, a loopback
/// server and a unix socket work with no network at all, and calling
/// them offline would stop a session that is fine.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ReachabilityTarget {
    Local,
    Remote(NetworkEndpoint),
}

impl ReachabilityTarget {
    /// The target as the request names it: the first SSH hop when
    /// tunnelled, else the service.
    pub fn for_request(request: &ConnectRequest) -> Self {
        match &request.target {
            RequestTarget::File(_) => Self::Local,
            RequestTarget::Network { ssh: Some(ssh), .. } => {
                let first = ssh.jump_hosts.first().unwrap_or(&ssh.destination);
                NetworkEndpoint::new(first.host(), first.port().unwrap_or(SSH_PORT))
                    .map_or(Self::Local, |endpoint| Self::for_endpoint(&endpoint))
            }
            RequestTarget::Network {
                endpoint, ssh: None, ..
            } => Self::for_endpoint(endpoint),
        }
    }

    /// The target once connected. An SSH alias is only resolved by ssh
    /// itself, so the first hop it reports wins over the typed name;
    /// a route only a ProxyCommand knows is treated as local rather
    /// than guessed.
    pub fn for_established(request: &ConnectRequest, established: &EstablishedConnection) -> Self {
        match &established.ssh_session {
            Some(session) => session.first_hop_endpoint().map_or(Self::Local, Self::for_endpoint),
            None => Self::for_request(request),
        }
    }

    pub fn is_local(&self) -> bool {
        matches!(self, Self::Local)
    }

    fn for_endpoint(endpoint: &NetworkEndpoint) -> Self {
        if is_local_host(endpoint.host()) {
            Self::Local
        } else {
            Self::Remote(endpoint.clone())
        }
    }
}

fn is_local_host(host: &str) -> bool {
    host.eq_ignore_ascii_case("localhost")
        || host == "."
        || host.starts_with('/')
        || host.parse::<IpAddr>().is_ok_and(|address| address.is_loopback())
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::Arc;

    use secrecy::SecretString;
    use tablepro_core::{Credentials, FileEndpoint, TlsConfig, WorkspaceSettings};
    use tablepro_ssh::{SshAuth, SshConfig, SshDestination};
    use tablepro_test_support::{ConnectionScript, FakeDriver};
    use uuid::Uuid;

    use super::*;
    use crate::connect::ConnectionMetadata;

    fn request(target: RequestTarget) -> ConnectRequest {
        ConnectRequest {
            metadata: ConnectionMetadata {
                id: Uuid::new_v4(),
                name: "n".to_owned(),
                driver_id: "fake".to_owned(),
            },
            driver: Arc::new(FakeDriver::connecting(
                &FakeDriver::NETWORK_CAPABILITIES,
                ConnectionScript::default(),
            )),
            target,
            workspace_settings: WorkspaceSettings::workspace(false),
        }
    }

    fn network(host: &str, ssh: Option<SshConfig>) -> RequestTarget {
        RequestTarget::Network {
            endpoint: NetworkEndpoint::new(host, 5432).unwrap(),
            ssh,
            credentials: Credentials::Password {
                username: "u".to_owned(),
                password: SecretString::from("p"),
            },
            database: None,
            tls: TlsConfig::disabled(),
        }
    }

    fn bastion(jumps: &[&str]) -> SshConfig {
        SshConfig {
            destination: SshDestination::new("bastion.example.com", Some(2222), None).unwrap(),
            jump_hosts: jumps
                .iter()
                .map(|jump| SshDestination::new(*jump, None, None).unwrap())
                .collect(),
            auth: SshAuth::Agent,
        }
    }

    fn remote(host: &str, port: u16) -> ReachabilityTarget {
        ReachabilityTarget::Remote(NetworkEndpoint::new(host, port).unwrap())
    }

    #[test]
    fn for_request_table() {
        let file = RequestTarget::File(FileEndpoint::open_existing(PathBuf::from("/srv/app.db")).unwrap());
        let cases = [
            (network("127.0.0.1", None), ReachabilityTarget::Local),
            (network("::1", None), ReachabilityTarget::Local),
            (network("localhost", None), ReachabilityTarget::Local),
            (network(".", None), ReachabilityTarget::Local),
            (network("/var/run/postgresql", None), ReachabilityTarget::Local),
            (file, ReachabilityTarget::Local),
            (network("db.example.com", None), remote("db.example.com", 5432)),
            (
                network("10.0.0.5", Some(bastion(&[]))),
                remote("bastion.example.com", 2222),
            ),
            (
                network("10.0.0.5", Some(bastion(&["jump.example.com"]))),
                remote("jump.example.com", 22),
            ),
            (
                network(
                    "db.example.com",
                    Some(SshConfig {
                        destination: SshDestination::new("localhost", None, None).unwrap(),
                        jump_hosts: Vec::new(),
                        auth: SshAuth::Agent,
                    }),
                ),
                ReachabilityTarget::Local,
            ),
        ];

        for (target, expected) in cases {
            let label = format!("{target:?}");
            assert_eq!(ReachabilityTarget::for_request(&request(target)), expected, "{label}");
        }
    }
}
