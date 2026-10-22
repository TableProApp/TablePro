use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use tokio::process::Command;

const PROBE_LIMIT: Duration = Duration::from_secs(5);

/// Whether the master gets `IdentitiesOnly=yes` for the key file `key`.
/// ssh puts a key file the agent holds first, with the agent's
/// certificates for it after, so only a key the agent lacks needs the
/// agent's other keys held back. ssh matches the file to the agent by
/// its public half, which an encrypted PEM file without `.pub` hides.
pub(crate) async fn pin_key_file(ssh_keygen: &Path, key: &Path, ssh_g_output: Option<&str>) -> bool {
    let Some(fingerprint) = fingerprint(ssh_keygen, key).await else {
        return false;
    };
    let Some(socket) = agent_socket(ssh_g_output, std::env::var_os("SSH_AUTH_SOCK")) else {
        return true;
    };
    // ssh-add ships beside ssh-keygen in every OpenSSH client package.
    match agent_fingerprints(&ssh_keygen.with_file_name("ssh-add"), &socket).await {
        Some(held) => !held.contains(&fingerprint),
        None => true,
    }
}

/// The SHA256 fingerprint `ssh-keygen -l` prints when it can read the
/// public half without the passphrase, as ssh must.
async fn fingerprint(ssh_keygen: &Path, key: &Path) -> Option<String> {
    let output = Command::new(ssh_keygen)
        .arg("-l")
        .arg("-f")
        .arg(key)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .output();
    // A FIFO or a stalled mount never answers; the key then goes to ssh as before.
    let output = tokio::time::timeout(PROBE_LIMIT, output).await.ok()?.ok()?;
    if !output.status.success() {
        return None;
    }
    second_field(&String::from_utf8_lossy(&output.stdout))
}

/// The agent ssh would ask, from the `identityagent` line `ssh -G`
/// prints with its tokens expanded, or `SSH_AUTH_SOCK` when it prints
/// none.
fn agent_socket(ssh_g_output: Option<&str>, environment: Option<OsString>) -> Option<PathBuf> {
    let configured = ssh_g_output
        .and_then(|output| output.lines().find_map(|line| line.strip_prefix("identityagent ")))
        .map(str::trim);
    let socket = match configured {
        Some("none") => return None,
        Some("SSH_AUTH_SOCK") | None => environment,
        // ssh_config(5): a value starting with `$` names the variable that holds the socket.
        Some(value) => match value.strip_prefix('$') {
            Some(variable) if !variable.starts_with('{') => std::env::var_os(variable),
            _ => Some(OsString::from(value)),
        },
    };
    socket.filter(|socket| !socket.is_empty()).map(PathBuf::from)
}

/// What `ssh-add -l` lists, or `None` when the agent could not be asked.
async fn agent_fingerprints(ssh_add: &Path, socket: &Path) -> Option<Vec<String>> {
    let output = Command::new(ssh_add)
        .arg("-l")
        .env("SSH_AUTH_SOCK", socket)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .output();
    let output = tokio::time::timeout(PROBE_LIMIT, output).await.ok()?.ok()?;
    match output.status.code() {
        Some(0) => Some(
            String::from_utf8_lossy(&output.stdout)
                .lines()
                .filter_map(second_field)
                .collect(),
        ),
        // An agent with no keys exits 1.
        Some(1) => Some(Vec::new()),
        _ => None,
    }
}

fn second_field(line: &str) -> Option<String> {
    line.split_whitespace().nth(1).map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use tablepro_test_fixtures::{SshAgent, SshKeyPair, SshKeyType};

    use super::*;

    #[test]
    fn the_agent_is_the_one_ssh_g_names_or_ssh_auth_sock() {
        let environment = || Some(OsString::from("/run/user/1000/agent.sock"));
        let from_env = Some(PathBuf::from("/run/user/1000/agent.sock"));

        assert_eq!(agent_socket(None, environment()), from_env);
        assert_eq!(agent_socket(Some("user deploy\nport 22\n"), environment()), from_env);
        assert_eq!(
            agent_socket(Some("identityagent SSH_AUTH_SOCK\n"), environment()),
            from_env
        );
        assert_eq!(
            agent_socket(Some("identityagent /home/u/.1password/agent.sock\n"), environment()),
            Some(PathBuf::from("/home/u/.1password/agent.sock"))
        );
        assert_eq!(agent_socket(Some("identityagent none\n"), environment()), None);
        assert_eq!(agent_socket(None, Some(OsString::new())), None);
        assert_eq!(agent_socket(None, None), None);
    }

    /// ssh reads an OpenSSH key's public half from the file itself and a
    /// PEM key's from its `.pub`; an encrypted PEM key alone hides it.
    #[tokio::test]
    async fn a_fingerprint_needs_the_public_half_in_the_clear() {
        let dir = tempfile::tempdir().unwrap();
        let generate = |name: &str, format: &[&str]| {
            let path = dir.path().join(name);
            let status = std::process::Command::new("ssh-keygen")
                .args(["-q", "-t", "rsa", "-b", "2048", "-N", "secret phrase", "-f"])
                .arg(&path)
                .args(format)
                .status()
                .unwrap();
            assert!(status.success());
            path
        };
        let openssh = generate("openssh", &[]);
        let pem = generate("pem", &["-m", "PEM"]);
        std::fs::remove_file(openssh.with_extension("pub")).unwrap();
        let keygen = Path::new("ssh-keygen");

        assert!(
            fingerprint(keygen, &openssh)
                .await
                .is_some_and(|print| print.starts_with("SHA256:"))
        );
        assert!(fingerprint(keygen, &pem).await.is_some());
        std::fs::remove_file(pem.with_extension("pub")).unwrap();
        assert_eq!(fingerprint(keygen, &pem).await, None);
        assert_eq!(fingerprint(keygen, &dir.path().join("missing")).await, None);
    }

    #[tokio::test]
    async fn a_key_file_is_pinned_unless_the_agent_already_holds_it() {
        let agent = SshAgent::start().await.unwrap();
        let held = SshKeyPair::generate("tablepro-held").await.unwrap();
        let other = SshKeyPair::generate_with(SshKeyType::EcdsaP256, None, "tablepro-other")
            .await
            .unwrap();
        agent.add(&held).await.unwrap();
        let ssh_g = format!("identityagent {}\n", agent.socket().display());
        let keygen = Path::new("ssh-keygen");

        assert!(!pin_key_file(keygen, held.private_key(), Some(&ssh_g)).await);
        assert!(pin_key_file(keygen, other.private_key(), Some(&ssh_g)).await);
        assert!(pin_key_file(keygen, held.private_key(), Some("identityagent none\n")).await);
        assert!(!pin_key_file(keygen, &held.private_key().with_extension("missing"), Some(&ssh_g)).await);
    }
}
