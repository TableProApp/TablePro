use std::collections::HashSet;
use std::io;
use std::path::Path;
use std::process::Stdio;
use std::time::Instant;

use tokio::io::AsyncReadExt;
use tokio::process::Command;
use tokio_util::sync::CancellationToken;

use super::error::{OpenSshError, TimeoutPhase, spawn_failure};
use super::{OpenSshConfig, OpenSshContext, SshDestination};

const MAX_ROUTE_HOSTS: usize = 32;
const MAX_CONFIG_OUTPUT_BYTES: usize = 65_536;

pub(super) async fn validate_route(
    config: &OpenSshConfig,
    context: &OpenSshContext,
    ssh_config: &Path,
    cancel: &CancellationToken,
) -> Result<(), OpenSshError> {
    let deadline = Instant::now() + context.timeouts.connect;
    let mut pending = vec![config.destination.clone()];
    let mut visited = HashSet::new();
    while let Some(destination) = pending.pop() {
        if !visited.insert(destination.clone()) {
            continue;
        }
        if visited.len() > MAX_ROUTE_HOSTS {
            return Err(OpenSshError::ConfigRejected {
                detail: "the configured SSH route is too long".into(),
            });
        }
        let jump_hosts = if destination == config.destination {
            config.jump_hosts.as_slice()
        } else {
            &[]
        };
        pending.extend(query_route(&destination, jump_hosts, context, ssh_config, deadline, cancel).await?);
    }
    Ok(())
}

async fn query_route(
    destination: &SshDestination,
    jump_hosts: &[SshDestination],
    context: &OpenSshContext,
    ssh_config: &Path,
    deadline: Instant,
    cancel: &CancellationToken,
) -> Result<Vec<SshDestination>, OpenSshError> {
    let mut child = route_command(destination, jump_hosts, context, ssh_config)
        .spawn()
        .map_err(|error| spawn_failure(&context.ssh_program, &error))?;
    let stdout = child.stdout.take().ok_or_else(|| OpenSshError::ConfigRejected {
        detail: "OpenSSH did not return its effective route".into(),
    })?;
    let read = async move {
        let mut bytes = Vec::new();
        stdout
            .take((MAX_CONFIG_OUTPUT_BYTES + 1) as u64)
            .read_to_end(&mut bytes)
            .await?;
        Ok::<_, io::Error>(bytes)
    };
    let result = tokio::select! {
        _ = cancel.cancelled() => {
            let _ = child.kill().await;
            return Err(OpenSshError::Cancelled);
        }
        result = tokio::time::timeout_at(deadline.into(), async {
            let (bytes, status) = tokio::try_join!(read, child.wait())?;
            Ok::<_, io::Error>((bytes, status))
        }) => result,
    };
    let (bytes, status) = match result {
        Ok(Ok(result)) => result,
        Ok(Err(_)) => {
            return Err(OpenSshError::ConfigRejected {
                detail: "OpenSSH could not read its effective route".into(),
            });
        }
        Err(_) => {
            let _ = child.kill().await;
            return Err(OpenSshError::Timeout {
                phase: TimeoutPhase::Connect,
            });
        }
    };
    if bytes.len() > MAX_CONFIG_OUTPUT_BYTES || !status.success() {
        return Err(OpenSshError::ConfigRejected {
            detail: "OpenSSH rejected its configuration".into(),
        });
    }
    parse_effective_route(&bytes)
}

fn route_command(
    destination: &SshDestination,
    jump_hosts: &[SshDestination],
    context: &OpenSshContext,
    ssh_config: &Path,
) -> Command {
    let mut command = Command::new(&context.ssh_program);
    command
        .args(["-G", "-F"])
        .arg(ssh_config)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    if !jump_hosts.is_empty() {
        let chain = jump_hosts.iter().map(ToString::to_string).collect::<Vec<_>>().join(",");
        command.args(["-J", &chain]);
    }
    if let Some(port) = destination.port() {
        command.args(["-p", &port.to_string()]);
    }
    if let Some(user) = destination.user() {
        command.args(["-l", user]);
    }
    command.args(["--", destination.host()]);
    command
}

fn parse_effective_route(output: &[u8]) -> Result<Vec<SshDestination>, OpenSshError> {
    let output = String::from_utf8_lossy(output);
    let mut jump_hosts = Vec::new();
    for line in output.lines() {
        if let Some(command) = line.strip_prefix("proxycommand ")
            && !command.trim().eq_ignore_ascii_case("none")
        {
            return Err(OpenSshError::UnsupportedProxyCommand);
        }
        if let Some(jump) = line.strip_prefix("proxyjump ")
            && !jump.trim().is_empty()
            && !jump.trim().eq_ignore_ascii_case("none")
        {
            jump_hosts.extend(SshDestination::parse_jump_list(jump)?);
        }
    }
    Ok(jump_hosts)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn effective_proxy_commands_are_rejected_and_jump_hosts_are_parsed() {
        assert!(matches!(
            parse_effective_route(b"proxycommand /bin/touch marker\n"),
            Err(OpenSshError::UnsupportedProxyCommand)
        ));
        let route = parse_effective_route(b"proxyjump deploy@jump.example:2200,second\n").unwrap();
        assert_eq!(
            route.iter().map(ToString::to_string).collect::<Vec<_>>(),
            ["deploy@jump.example:2200", "second"]
        );
    }
}
