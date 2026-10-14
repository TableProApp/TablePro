use std::ffi::OsString;
use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use tablepro_core::NetworkEndpoint;
use tokio::process::Command;

use crate::SshDestination;
use crate::host_key_checking::HostKeyChecking;

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
    /// The ProxyJump chain, first hop first.
    Jump(Vec<SshDestination>),
    ProxyCommand,
}

/// One jump host the master goes through, with the StrictHostKeyChecking
/// the ssh OpenSSH starts for it reads from the configuration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct JumpHop {
    pub(crate) destination: SshDestination,
    pub(crate) host_keys: Option<HostKeyChecking>,
}

/// The jump hosts between this machine and the destination, as far as
/// `ssh -G` could follow them, and where the first TCP connection goes.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Route {
    pub(crate) hops: Vec<JumpHop>,
    /// `None` when the route starts at a ProxyCommand, whose first hop
    /// only that command knows, or could not be followed.
    pub(crate) first_hop: Option<NetworkEndpoint>,
}

/// Follow the route from what `ssh -G` printed for the destination.
///
/// An ssh_config alias is only a name until `ssh -G` resolves it, so
/// this asks ssh rather than trusting what the user typed. ssh.c runs
/// the last hop of a ProxyJump chain through a second ssh, given the
/// earlier hops as its own `-J`, so each hop is looked up the same way,
/// and only the first hop's own ProxyJump from the configuration applies.
pub(crate) async fn trace_route(ssh_program: &Path, config_file: Option<&Path>, destination: Option<&str>) -> Route {
    let mut route = Route::default();
    let Some(mut output) = destination.map(str::to_owned) else {
        return route;
    };
    loop {
        let chain = match parse_resolved(&output) {
            Some(Resolved::Direct(endpoint)) => {
                route.first_hop = Some(endpoint);
                return route;
            }
            Some(Resolved::Jump(chain)) => chain,
            Some(Resolved::ProxyCommand) | None => return route,
        };
        for index in (0..chain.len()).rev() {
            if route.hops.len() == MAX_HOPS {
                tracing::debug!("the ssh jump chain did not end");
                return route;
            }
            let Some(resolved) = lookup(ssh_program, config_file, &chain[index], &chain[..index]).await else {
                return route;
            };
            route.hops.push(JumpHop {
                destination: chain[index].clone(),
                host_keys: HostKeyChecking::from_ssh_g(&resolved),
            });
            output = resolved;
        }
    }
}

pub(crate) async fn lookup(
    ssh_program: &Path,
    config_file: Option<&Path>,
    destination: &SshDestination,
    jumps: &[SshDestination],
) -> Option<String> {
    let mut args: Vec<OsString> = vec!["-G".into()];
    if let Some(config_file) = config_file {
        args.push("-F".into());
        args.push(config_file.as_os_str().to_owned());
    }
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
            tracing::debug!(status = ?output.status.code(), "ssh -G could not resolve a host");
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
        let hops: Option<Vec<SshDestination>> = chain
            .split(',')
            .map(|hop| {
                let hop = hop.trim();
                let hop = hop.strip_prefix("ssh://").unwrap_or(hop);
                SshDestination::parse_jump_list(hop).ok()?.pop()
            })
            .collect();
        return hops.filter(|hops| !hops.is_empty()).map(Resolved::Jump);
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

    fn endpoint(host: &str, port: u16) -> NetworkEndpoint {
        NetworkEndpoint::new(host, port).unwrap()
    }

    fn hop(host: &str) -> SshDestination {
        SshDestination::new(host, None, None).unwrap()
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
    fn a_jump_chain_lists_every_hop_first_hop_first() {
        let output = "hostname db.internal\nport 22\nproxyjump ops@jump.example.com:2200,second\n";

        assert_eq!(
            parse_resolved(output),
            Some(Resolved::Jump(vec![
                SshDestination::new("jump.example.com", Some(2200), Some("ops".to_owned())).unwrap(),
                hop("second"),
            ]))
        );
    }

    #[test]
    fn a_uri_jump_and_an_ipv6_jump_parse() {
        let uri = "hostname t\nproxyjump ssh://ops@jump.example.com:2200,ssh://second\n";
        let ipv6 = "hostname t\nproxyjump [::1]:2201\n";

        assert_eq!(
            parse_resolved(uri),
            Some(Resolved::Jump(vec![
                SshDestination::new("jump.example.com", Some(2200), Some("ops".to_owned())).unwrap(),
                hop("second"),
            ]))
        );
        assert_eq!(
            parse_resolved(ipv6),
            Some(Resolved::Jump(vec![
                SshDestination::new("::1", Some(2201), None).unwrap()
            ]))
        );
    }

    #[test]
    fn a_hop_that_does_not_parse_leaves_the_route_unknown() {
        assert_eq!(parse_resolved("hostname t\nproxyjump jump1,,jump2\n"), None);
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

    async fn route(program: &Path, host: &str, jumps: &[&str]) -> Route {
        let destination = hop(host);
        let jumps: Vec<SshDestination> = jumps.iter().map(|jump| hop(jump)).collect();
        let resolved = lookup(program, None, &destination, &jumps).await;
        trace_route(program, None, resolved.as_deref()).await
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
  bastion) printf 'hostname 192.0.2.10\nport 2222\nstricthostkeychecking accept-new\n' ;;
  *) exit 255 ;;
esac"#,
        );

        let route = route(&program, "db", &["bastion"]).await;

        assert_eq!(route.first_hop, Some(endpoint("192.0.2.10", 2222)));
        assert_eq!(
            route.hops,
            [JumpHop {
                destination: hop("bastion"),
                host_keys: Some(HostKeyChecking::AcceptNew),
            }]
        );
    }

    /// The last hop is looked up with the earlier ones as its `-J`, the
    /// way its ssh is started, and the first hop's own ProxyJump from the
    /// configuration adds the hop before it.
    #[tokio::test]
    async fn every_hop_of_a_chain_is_looked_up_as_its_ssh_starts() {
        let temp = tempfile::tempdir().unwrap();
        let program = fake_ssh(
            temp.path(),
            r#"for last; do :; done
case "$*" in
  "-G -- db") printf 'hostname 10.0.0.5\nproxyjump j1,j2\n' ;;
  "-G -J j1 -- j2") printf 'hostname 10.0.0.2\nproxyjump j1\nstricthostkeychecking false\n' ;;
  "-G -- j1") printf 'hostname 10.0.0.1\nproxyjump j0\nstricthostkeychecking true\n' ;;
  "-G -- j0") printf 'hostname 192.0.2.1\nport 2200\nstricthostkeychecking ask\n' ;;
  *) exit 255 ;;
esac"#,
        );

        let route = route(&program, "db", &[]).await;

        let looked_up: Vec<(String, Option<HostKeyChecking>)> = route
            .hops
            .iter()
            .map(|hop| (hop.destination.to_string(), hop.host_keys))
            .collect();
        assert_eq!(
            looked_up,
            [
                ("j2".to_owned(), Some(HostKeyChecking::No)),
                ("j1".to_owned(), Some(HostKeyChecking::Yes)),
                ("j0".to_owned(), Some(HostKeyChecking::Ask)),
            ]
        );
        assert_eq!(route.first_hop, Some(endpoint("192.0.2.1", 2200)));
    }

    #[tokio::test]
    async fn a_failing_lookup_and_a_jump_loop_resolve_to_nothing() {
        let temp = tempfile::tempdir().unwrap();
        let failing = fake_ssh(temp.path(), "exit 255");
        assert_eq!(route(&failing, "db", &[]).await, Route::default());

        let looping = tempfile::tempdir().unwrap();
        let program = fake_ssh(looping.path(), r"printf 'hostname x\nproxyjump loop\n'");
        let looped = route(&program, "loop", &[]).await;
        assert_eq!(looped.first_hop, None);
        assert_eq!(looped.hops.len(), MAX_HOPS);
    }

    #[tokio::test]
    async fn a_config_file_reaches_every_lookup() {
        let temp = tempfile::tempdir().unwrap();
        let program = fake_ssh(
            temp.path(),
            r#"case "$*" in
  "-G -F /etc/tablepro-test.conf -- db") printf 'hostname 10.0.0.5\nproxyjump j1\n' ;;
  "-G -F /etc/tablepro-test.conf -- j1") printf 'hostname 192.0.2.1\n' ;;
  *) exit 255 ;;
esac"#,
        );
        let config = Path::new("/etc/tablepro-test.conf");

        let resolved = lookup(&program, Some(config), &hop("db"), &[]).await;
        let route = trace_route(&program, Some(config), resolved.as_deref()).await;

        assert_eq!(route.first_hop, Some(endpoint("192.0.2.1", 22)));
    }
}
