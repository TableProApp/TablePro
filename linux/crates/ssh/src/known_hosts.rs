use std::ffi::OsString;
use std::io;
use std::path::Path;
use std::process::Stdio;

use tablepro_core::SshFailure;
use tokio::process::Command;

use crate::{SshConfig, SshServices};

pub async fn forget_host_key(services: &SshServices, config: &SshConfig, known_hosts: &Path) -> Result<(), SshFailure> {
    let mut args: Vec<OsString> = vec!["-G".into()];
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
    let lookup = known_hosts_lookup(&resolved).ok_or_else(|| SshFailure::ConfigRejected {
        detail: "ssh -G printed no hostname".to_owned(),
    })?;
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
        SshFailure::ConfigRejected {
            detail: format!("could not run {}: {error}", program.display()),
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

    #[test]
    fn missing_program_is_open_ssh_client_missing() {
        let error = io::Error::from(io::ErrorKind::NotFound);
        assert!(matches!(
            spawn_failure(Path::new("/nonexistent/ssh"), &error),
            SshFailure::OpenSshClientMissing { .. }
        ));
    }
}
