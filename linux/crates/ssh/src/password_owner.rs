use std::path::Path;

use crate::SshConfig;
use crate::first_hop::lookup;

/// The `user@host` OpenSSH puts in the destination's password prompt, so
/// a stored password goes to that prompt and never to a jump host's.
///
/// sshconnect2.c prints `%.30s@%.128s's password: ` with the server user
/// and HostKeyAlias, or the resolved HostName when there is no alias.
pub(crate) async fn resolve_password_owner(ssh_program: &Path, config: &SshConfig) -> Option<String> {
    let output = lookup(ssh_program, &config.destination, &config.jump_hosts).await?;
    password_owner(&output)
}

fn password_owner(ssh_g_output: &str) -> Option<String> {
    let mut user = None;
    let mut hostname = None;
    let mut alias = None;
    for line in ssh_g_output.lines() {
        let Some((key, value)) = line.split_once(' ') else {
            continue;
        };
        let value = value.trim();
        match key {
            "user" => user = Some(value),
            "hostname" => hostname = Some(value),
            "hostkeyalias" if value != "none" => alias = Some(value),
            _ => {}
        }
    }
    let host = alias.or(hostname)?;
    Some(format!("{}@{}", printed(user?, 30), printed(host, 128)))
}

/// What C's `%.Ns` prints of `text`.
fn printed(text: &str, bytes: usize) -> &str {
    text.get(..bytes).unwrap_or(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_owner_is_the_resolved_user_and_host() {
        let output = "host prod\nuser deploy\nhostname 10.0.0.5\nport 22\nproxyjump ops@jump1\n";

        assert_eq!(password_owner(output).as_deref(), Some("deploy@10.0.0.5"));
    }

    #[test]
    fn a_host_key_alias_names_the_host() {
        let output = "user deploy\nhostname 10.0.0.5\nhostkeyalias db-prod\n";

        assert_eq!(password_owner(output).as_deref(), Some("deploy@db-prod"));
    }

    #[test]
    fn long_names_are_cut_where_openssh_cuts_them() {
        let user = "u".repeat(40);
        let output = format!("user {user}\nhostname db\n");

        assert_eq!(password_owner(&output), Some(format!("{}@db", "u".repeat(30))));
    }

    #[test]
    fn no_owner_without_a_user_or_host() {
        assert_eq!(password_owner("hostname db\n"), None);
        assert_eq!(password_owner("user deploy\n"), None);
    }
}
