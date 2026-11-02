use std::ffi::OsString;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Stdio;

use tablepro_core::{SshDestinationPart, SshDestinationProblem, SshFailure};
use tokio::process::Command;

use crate::route::{lookup, trace_route};
use crate::{SshConfig, SshServices};

/// Why a key ssh reported as changed was left in known_hosts.
#[derive(Debug, thiserror::Error)]
pub enum ForgetHostKeyError {
    /// `ssh -G` names no host of this connection by `host` that reads
    /// `known_hosts`, so the report did not come from ssh's own check.
    #[error("{host} in {} is not a host key this connection uses", .known_hosts.display())]
    NotThisConnection { host: String, known_hosts: PathBuf },
    #[error(transparent)]
    Ssh(#[from] SshFailure),
}

pub async fn forget_host_key(services: &SshServices, config: &SshConfig, known_hosts: &Path) -> Result<(), SshFailure> {
    let mut args: Vec<OsString> = vec!["-G".into()];
    if let Some(config_file) = &services.config_file {
        args.push("-F".into());
        args.push(config_file.as_os_str().to_owned());
    }
    if let Some(port) = config.destination.port() {
        args.push("-p".into());
        args.push(port.to_string().into());
    }
    if let Some(user) = config.destination.user() {
        args.push("-l".into());
        args.push(user.into());
    }
    args.push("--".into());
    args.push(config.destination.host().into());

    let resolved = run(&services.ssh_program, &args).await?;
    let lookup = known_hosts_lookup(&resolved).ok_or_else(|| {
        tracing::warn!("ssh -G printed no hostname");
        SshFailure::Protocol {
            status: None,
            detail: String::new(),
        }
    })?;
    forget_known_host(services, &lookup, known_hosts).await
}

/// Remove the old key of a host whose key ssh reported as changed.
///
/// The report is read from ssh's stderr, where a server's login banner
/// is printed too, so `host` and `known_hosts` are taken only when
/// `ssh -G` resolves the connection's destination or one of its jump
/// hosts to `host`, and lists `known_hosts` among the UserKnownHostsFile
/// entries for it.
pub async fn forget_changed_host_key(
    services: &SshServices,
    config: &SshConfig,
    host: &str,
    known_hosts: &Path,
) -> Result<(), ForgetHostKeyError> {
    let program = &services.ssh_program;
    let config_file = services.config_file.as_deref();
    let resolved = lookup(program, config_file, &config.destination, &config.jump_hosts).await;
    let route = trace_route(program, config_file, resolved.as_deref()).await;
    let mut hosts: Vec<String> = resolved.into_iter().collect();
    for hop in &route.hops {
        hosts.extend(lookup(program, config_file, &hop.destination, &[]).await);
    }
    let ours = hosts.iter().find_map(|resolved| {
        let name = known_hosts_lookup(resolved)?;
        let reads = user_known_hosts_files(resolved).iter().any(|file| file == known_hosts);
        (reads && name.eq_ignore_ascii_case(host)).then_some(name)
    });
    let Some(name) = ours else {
        return Err(ForgetHostKeyError::NotThisConnection {
            host: host.to_owned(),
            known_hosts: known_hosts.to_owned(),
        });
    };
    Ok(forget_known_host(services, &name, known_hosts).await?)
}

/// Remove every key `known_hosts` holds for `lookup`, the name ssh looks
/// the host up by: `host`, `[host]:port` or a HostKeyAlias, as ssh
/// prints it when a key changes.
pub(crate) async fn forget_known_host(
    services: &SshServices,
    lookup: &str,
    known_hosts: &Path,
) -> Result<(), SshFailure> {
    if lookup.trim().is_empty() {
        return Err(SshDestinationProblem::Empty {
            part: SshDestinationPart::Host,
        }
        .into());
    }
    let keygen_args: Vec<OsString> = vec![
        "-R".into(),
        lookup.into(),
        "-f".into(),
        known_hosts.as_os_str().to_owned(),
    ];
    run(&services.ssh_keygen_program, &keygen_args).await.map(|_| ())
}

pub(crate) fn known_hosts_lookup(ssh_g_output: &str) -> Option<String> {
    let mut hostname = None;
    let mut port = None;
    let mut alias = None;
    for line in ssh_g_output.lines() {
        let Some((key, value)) = line.split_once(' ') else {
            continue;
        };
        match key {
            "hostname" => hostname = Some(value.trim()),
            "port" => port = Some(value.trim()),
            "hostkeyalias" if value.trim() != "none" => alias = Some(value.trim()),
            _ => {}
        }
    }
    if let Some(alias) = alias {
        return Some(alias.to_owned());
    }
    let hostname = hostname?;
    match port {
        Some(port) if port != "22" => Some(format!("[{hostname}]:{port}")),
        _ => Some(hostname.to_owned()),
    }
}

/// The UserKnownHostsFile entries `ssh -G` printed, `~` and `%` tokens
/// already expanded. ssh prints them unquoted, so a path with a space
/// in it splits and matches nothing.
fn user_known_hosts_files(ssh_g_output: &str) -> Vec<PathBuf> {
    ssh_g_output
        .lines()
        .filter_map(|line| line.strip_prefix("userknownhostsfile "))
        .flat_map(str::split_whitespace)
        .map(PathBuf::from)
        .collect()
}

async fn run(program: &Path, args: &[OsString]) -> Result<String, SshFailure> {
    let output = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .output()
        .await
        .map_err(|error| spawn_failure(program, &error))?;
    if !output.status.success() {
        return Err(SshFailure::ConfigRejected {
            detail: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        });
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

pub(crate) fn spawn_failure(program: &Path, error: &io::Error) -> SshFailure {
    if error.kind() == io::ErrorKind::NotFound {
        SshFailure::OpenSshClientMissing {
            program: program.to_owned(),
        }
    } else {
        tracing::debug!(%error, program = %program.display(), "could not start a program");
        SshFailure::LaunchFailed {
            program: program.to_owned(),
            kind: error.kind(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_hosts_lookup_from_ssh_g_output() {
        let alias = "user deploy\nhostname 192.0.2.10\nport 2222\nhostkeyalias db-bastion\n";
        assert_eq!(known_hosts_lookup(alias).as_deref(), Some("db-bastion"));

        let custom_port = "user deploy\nhostname db.example.com\nport 2222\n";
        assert_eq!(
            known_hosts_lookup(custom_port).as_deref(),
            Some("[db.example.com]:2222")
        );

        let default_port = "hostname db.example.com\nport 22\nhostkeyalias none\n";
        assert_eq!(known_hosts_lookup(default_port).as_deref(), Some("db.example.com"));

        assert_eq!(known_hosts_lookup("port 22\n"), None);
    }

    fn services(dir: &Path) -> SshServices {
        SshServices {
            runtime: std::sync::Arc::new(crate::SshRuntimeCell::new(dir.join("runtime"))),
            ssh_program: "ssh".into(),
            ssh_keygen_program: "ssh-keygen".into(),
            askpass_program: "tablepro-askpass".into(),
            config_file: None,
        }
    }

    const KEY: &str = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8g";

    #[tokio::test]
    async fn forget_known_host_removes_only_that_host() {
        let dir = tempfile::tempdir().unwrap();
        let known_hosts = dir.path().join("known_hosts");
        std::fs::write(
            &known_hosts,
            format!("[db.example.com]:2222 {KEY}\ndb.example.com {KEY}\n"),
        )
        .unwrap();

        forget_known_host(&services(dir.path()), "[db.example.com]:2222", &known_hosts)
            .await
            .unwrap();

        let left = std::fs::read_to_string(&known_hosts).unwrap();
        assert!(!left.contains("[db.example.com]:2222"), "{left}");
        assert!(left.contains(&format!("db.example.com {KEY}")), "{left}");
    }

    /// An `ssh` whose `-G` prints what `hosts` gives for the host named
    /// last, the way an ssh_config would resolve it, and fails for any
    /// other.
    fn fake_ssh(dir: &Path, hosts: &[(&str, String)]) -> PathBuf {
        let cases: String = hosts
            .iter()
            .map(|(host, resolved)| format!("  {host}) printf '{resolved}' ;;\n"))
            .collect();
        let program = dir.join("ssh");
        tablepro_test_support::write_executable(
            &program,
            format!("#!/bin/sh\nfor last; do :; done\ncase \"$last\" in\n{cases}  *) exit 255 ;;\nesac\n").as_bytes(),
            0o755,
        )
        .unwrap();
        program
    }

    fn tunnel(host: &str) -> SshConfig {
        SshConfig {
            destination: crate::SshDestination::new(host, None, None).unwrap(),
            jump_hosts: Vec::new(),
            auth: crate::SshAuth::Agent,
        }
    }

    /// A banner can print the lines of a changed key for any host and
    /// file, so only a host and file `ssh -G` gives for the connection
    /// lose a key.
    #[tokio::test]
    async fn a_changed_key_is_removed_only_for_this_connections_hosts_and_files() {
        let dir = tempfile::tempdir().unwrap();
        let known_hosts = dir.path().join("known_hosts");
        let elsewhere = dir.path().join("elsewhere");
        let keys = format!("[db.example.com]:2222 {KEY}\nother.example.com {KEY}\n");
        for path in [&known_hosts, &elsewhere] {
            std::fs::write(path, &keys).unwrap();
        }
        let resolved = format!(
            "hostname db.example.com\\nport 2222\\nuserknownhostsfile {} {}/known_hosts2\\n",
            known_hosts.display(),
            dir.path().display()
        );
        let services = SshServices {
            ssh_program: fake_ssh(dir.path(), &[("db", resolved)]),
            ..services(dir.path())
        };

        let other_host = forget_changed_host_key(&services, &tunnel("db"), "other.example.com", &known_hosts).await;
        let other_file = forget_changed_host_key(&services, &tunnel("db"), "[db.example.com]:2222", &elsewhere).await;

        assert!(
            matches!(other_host, Err(ForgetHostKeyError::NotThisConnection { .. })),
            "{other_host:?}"
        );
        assert!(
            matches!(other_file, Err(ForgetHostKeyError::NotThisConnection { .. })),
            "{other_file:?}"
        );
        assert_eq!(std::fs::read_to_string(&known_hosts).unwrap(), keys);
        assert_eq!(std::fs::read_to_string(&elsewhere).unwrap(), keys);

        forget_changed_host_key(&services, &tunnel("db"), "[db.example.com]:2222", &known_hosts)
            .await
            .unwrap();

        let left = std::fs::read_to_string(&known_hosts).unwrap();
        assert!(!left.contains("[db.example.com]:2222"), "{left}");
        assert!(left.contains("other.example.com"), "{left}");
    }

    /// A jump host the configuration adds is one of the connection's
    /// hosts, by the name and file its own `ssh -G` gives.
    #[tokio::test]
    async fn a_jump_hosts_changed_key_is_removed_from_its_own_file() {
        let dir = tempfile::tempdir().unwrap();
        let known_hosts = dir.path().join("known_hosts");
        std::fs::write(&known_hosts, format!("bastion.example.com {KEY}\n10.0.0.5 {KEY}\n")).unwrap();
        let file = known_hosts.display();
        let services = SshServices {
            ssh_program: fake_ssh(
                dir.path(),
                &[
                    (
                        "db",
                        format!("hostname 10.0.0.5\\nport 22\\nproxyjump bastion\\nuserknownhostsfile {file}\\n"),
                    ),
                    (
                        "bastion",
                        format!("hostname bastion.example.com\\nport 22\\nuserknownhostsfile {file}\\n"),
                    ),
                ],
            ),
            ..services(dir.path())
        };

        forget_changed_host_key(&services, &tunnel("db"), "bastion.example.com", &known_hosts)
            .await
            .unwrap();

        let left = std::fs::read_to_string(&known_hosts).unwrap();
        assert!(!left.contains("bastion.example.com"), "{left}");
        assert!(left.contains("10.0.0.5"), "{left}");
    }

    #[test]
    fn user_known_hosts_files_from_ssh_g_output() {
        let output = "hostname h\nuserknownhostsfile /home/u/.ssh/known_hosts /home/u/.ssh/known_hosts2\n";

        assert_eq!(
            user_known_hosts_files(output),
            [
                PathBuf::from("/home/u/.ssh/known_hosts"),
                PathBuf::from("/home/u/.ssh/known_hosts2")
            ]
        );
        assert!(user_known_hosts_files("hostname h\n").is_empty());
    }

    #[tokio::test]
    async fn forget_known_host_refuses_an_empty_name() {
        let dir = tempfile::tempdir().unwrap();
        let known_hosts = dir.path().join("known_hosts");

        let refused = forget_known_host(&services(dir.path()), " ", &known_hosts).await;

        assert_eq!(
            refused,
            Err(SshFailure::InvalidDestination {
                problem: SshDestinationProblem::Empty {
                    part: SshDestinationPart::Host
                }
            })
        );
    }

    #[test]
    fn missing_program_is_open_ssh_client_missing() {
        let error = io::Error::from(io::ErrorKind::NotFound);
        assert!(matches!(
            spawn_failure(Path::new("/nonexistent/ssh"), &error),
            SshFailure::OpenSshClientMissing { .. }
        ));
    }

    #[tokio::test]
    async fn a_program_that_will_not_start_keeps_the_kind_and_not_the_text() {
        let dir = tempfile::tempdir().unwrap();
        let program = dir.path().join("ssh");
        tablepro_test_support::write_executable(&program, b"#!/bin/sh\n", 0o644).unwrap();
        let services = SshServices {
            ssh_program: program.clone(),
            ..services(dir.path())
        };

        let refused = forget_host_key(&services, &tunnel("db"), &dir.path().join("known_hosts")).await;

        assert_eq!(
            refused,
            Err(SshFailure::LaunchFailed {
                program,
                kind: io::ErrorKind::PermissionDenied,
            })
        );
    }

    #[tokio::test]
    async fn ssh_g_without_a_hostname_is_unexpected_output_with_no_words_of_ours() {
        let dir = tempfile::tempdir().unwrap();
        let services = SshServices {
            ssh_program: fake_ssh(dir.path(), &[("db", "port 22\\n".to_owned())]),
            ..services(dir.path())
        };

        let refused = forget_host_key(&services, &tunnel("db"), &dir.path().join("known_hosts")).await;

        assert_eq!(
            refused,
            Err(SshFailure::Protocol {
                status: None,
                detail: String::new(),
            })
        );
    }
}
