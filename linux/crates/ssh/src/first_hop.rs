use std::ffi::OsString;
use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use tablepro_core::NetworkEndpoint;
use tokio::process::Command;

use crate::{SshConfig, SshDestination};

/// `ssh -G` does no network I/O, but a `Match exec` line can run a
/// command, so each lookup is still bounded.
const LOOKUP_TIMEOUT: Duration = Duration::from_secs(5);
/// A ProxyJump chain whose hops name each other never ends; real chains
/// are a few hops long.
const MAX_HOPS: usize = 8;
const DEFAULT_PORT: u16 = 22;

#[derive(Debug, PartialEq, Eq)]
enum Resolved {
    Direct(NetworkEndpoint),
    Jump(SshDestination),
    ProxyCommand,
}

/// The host and port the first TCP connection of a session goes to.
///
/// An ssh_config alias is only a name until `ssh -G` resolves it, and a
/// jump chain starts at its first hop, so this asks ssh rather than
/// trusting what the user typed. `None` when the route is a
/// ProxyCommand, whose first hop only that command knows.
pub(crate) async fn resolve_first_hop(ssh_program: &Path, config: &SshConfig) -> Option<NetworkEndpoint> {
    let mut destination = config.destination.clone();
    let mut jumps = config.jump_hosts.clone();
    for _ in 0..MAX_HOPS {
        let output = lookup(ssh_program, &destination, &jumps).await?;
        match parse_resolved(&output)? {
            Resolved::Direct(endpoint) => return Some(endpoint),
            Resolved::ProxyCommand => return None,
            Resolved::Jump(first) => {
                destination = first;
                jumps = Vec::new();
            }
        }
    }
    tracing::debug!(destination = %config.destination, "the ssh jump chain did not end");
    None
}

pub(crate) async fn lookup(
    ssh_program: &Path,
    destination: &SshDestination,
    jumps: &[SshDestination],
) -> Option<String> {
    let mut args: Vec<OsString> = vec!["-G".into()];
    if !jumps.is_empty() {
        let hops: Vec<String> = jumps.iter().map(ToString::to_string).collect();
        args.push("-J".into());
        args.push(hops.join(",").into());
    }
    if let Some(port) = destination.port() {
        args.push("-p".into());
        args.push(port.to_string().into());
    }
    if let Some(user) = destination.user() {
        args.push("-l".into());
        args.push(user.into());
    }
    args.push("--".into());
    args.push(destination.host().into());

    let run = Command::new(ssh_program)
        .args(&args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .output();
    match tokio::time::timeout(LOOKUP_TIMEOUT, run).await {
        Ok(Ok(output)) if output.status.success() => Some(String::from_utf8_lossy(&output.stdout).into_owned()),
        Ok(Ok(output)) => {
            tracing::debug!(status = ?output.status.code(), "ssh -G could not resolve the first hop");
            None
        }
        Ok(Err(error)) => {
            tracing::debug!(%error, "could not run ssh -G");
            None
        }
        Err(_) => {
            tracing::debug!("ssh -G did not finish");
            None
        }
    }
}

fn parse_resolved(ssh_g_output: &str) -> Option<Resolved> {
    let mut hostname = None;
    let mut port = None;
    let mut proxy_jump = None;
    let mut proxy_command = false;
    for line in ssh_g_output.lines() {
        let Some((key, value)) = line.split_once(' ') else {
            continue;
        };
        let value = value.trim();
        match key {
            "hostname" => hostname = Some(value),
            "port" => port = value.parse::<u16>().ok(),
            "proxyjump" if value != "none" => proxy_jump = Some(value),
            "proxycommand" if value != "none" => proxy_command = true,
            _ => {}
        }
    }
    if let Some(chain) = proxy_jump {
        let first = chain.split(',').next()?.trim();
        let first = first.strip_prefix("ssh://").unwrap_or(first);
        let mut hops = SshDestination::parse_jump_list(first).ok()?;
        return hops.pop().map(Resolved::Jump);
    }
    if proxy_command {
        return Some(Resolved::ProxyCommand);
    }
    NetworkEndpoint::new(hostname?, port.unwrap_or(DEFAULT_PORT))
        .ok()
        .map(Resolved::Direct)
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;

    use super::*;
    use crate::SshAuth;

    fn endpoint(host: &str, port: u16) -> NetworkEndpoint {
        NetworkEndpoint::new(host, port).unwrap()
    }

    #[test]
    fn a_direct_destination_resolves_to_its_hostname_and_port() {
        let output = "user deploy\nhostname 192.0.2.10\nport 2222\n";

        assert_eq!(
            parse_resolved(output),
            Some(Resolved::Direct(endpoint("192.0.2.10", 2222)))
        );
    }

    #[test]
    fn a_jump_chain_starts_at_its_first_hop() {
        let output = "hostname db.internal\nport 22\nproxyjump ops@jump.example.com:2200,second\n";

        assert_eq!(
            parse_resolved(output),
            Some(Resolved::Jump(
                SshDestination::new("jump.example.com", Some(2200), Some("ops".to_owned())).unwrap()
            ))
        );
    }

    #[test]
    fn a_uri_jump_and_an_ipv6_jump_parse() {
        let uri = "hostname t\nproxyjump ssh://ops@jump.example.com:2200\n";
        let ipv6 = "hostname t\nproxyjump [::1]:2201\n";

        assert_eq!(
            parse_resolved(uri),
            Some(Resolved::Jump(
                SshDestination::new("jump.example.com", Some(2200), Some("ops".to_owned())).unwrap()
            ))
        );
        assert_eq!(
            parse_resolved(ipv6),
            Some(Resolved::Jump(SshDestination::new("::1", Some(2201), None).unwrap()))
        );
    }

    #[test]
    fn a_proxy_command_has_no_known_first_hop() {
        let output = "hostname t\nport 22\nproxycommand nc %h %p\n";

        assert_eq!(parse_resolved(output), Some(Resolved::ProxyCommand));
    }

    #[test]
    fn none_values_are_not_proxies() {
        let output = "hostname t\nport 22\nproxyjump none\nproxycommand none\n";

        assert_eq!(parse_resolved(output), Some(Resolved::Direct(endpoint("t", 22))));
    }

    fn fake_ssh(dir: &Path, script: &str) -> PathBuf {
        let program = dir.join("ssh");
        std::fs::write(&program, format!("#!/bin/sh\n{script}\n")).unwrap();
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
        program
    }

    fn config(host: &str, jumps: &[&str]) -> SshConfig {
        SshConfig {
            destination: SshDestination::new(host, None, None).unwrap(),
            jump_hosts: jumps
                .iter()
                .map(|jump| SshDestination::new(*jump, None, None).unwrap())
                .collect(),
            auth: SshAuth::Agent,
        }
    }

    /// The fake prints a jump for the database host and resolves the
    /// alias the jump names, the way an ssh_config would.
    #[tokio::test]
    async fn an_alias_behind_a_jump_resolves_through_ssh_g() {
        let temp = tempfile::tempdir().unwrap();
        let program = fake_ssh(
            temp.path(),
            r#"for last; do :; done
case "$last" in
  db) printf 'hostname 10.0.0.5\nport 5432\nproxyjump bastion\n' ;;
  bastion) printf 'hostname 192.0.2.10\nport 2222\n' ;;
  *) exit 255 ;;
esac"#,
        );

        let first = resolve_first_hop(&program, &config("db", &["bastion"])).await;

        assert_eq!(first, Some(endpoint("192.0.2.10", 2222)));
    }

    #[tokio::test]
    async fn a_failing_lookup_and_a_jump_loop_resolve_to_nothing() {
        let temp = tempfile::tempdir().unwrap();
        let failing = fake_ssh(temp.path(), "exit 255");
        assert_eq!(resolve_first_hop(&failing, &config("db", &[])).await, None);

        let looping = tempfile::tempdir().unwrap();
        let program = fake_ssh(looping.path(), r"printf 'hostname x\nproxyjump loop\n'");
        assert_eq!(resolve_first_hop(&program, &config("loop", &[])).await, None);
    }
}
