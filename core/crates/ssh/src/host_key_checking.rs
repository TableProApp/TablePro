/// The StrictHostKeyChecking value the user's ssh config gives a
/// destination.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum HostKeyChecking {
    Yes,
    Ask,
    AcceptNew,
    No,
}

impl HostKeyChecking {
    /// `ssh -G` prints the value as `true`, `false`, `ask` or
    /// `accept-new`, whichever spelling the config used.
    pub(crate) fn from_ssh_g(ssh_g_output: &str) -> Option<Self> {
        let value = ssh_g_output
            .lines()
            .find_map(|line| line.strip_prefix("stricthostkeychecking "))?;
        match value.trim() {
            "true" => Some(Self::Yes),
            "ask" => Some(Self::Ask),
            "accept-new" => Some(Self::AcceptNew),
            "false" => Some(Self::No),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_value_ssh_g_prints_is_read() {
        let cases = [
            ("true", HostKeyChecking::Yes),
            ("ask", HostKeyChecking::Ask),
            ("accept-new", HostKeyChecking::AcceptNew),
            ("false", HostKeyChecking::No),
        ];
        for (printed, expected) in cases {
            let output = format!("user deploy\nhostname 10.0.0.5\nstricthostkeychecking {printed}\nport 22\n");

            assert_eq!(HostKeyChecking::from_ssh_g(&output), Some(expected), "{printed}");
        }
    }

    #[test]
    fn a_missing_or_unknown_value_is_not_guessed() {
        assert_eq!(HostKeyChecking::from_ssh_g("hostname 10.0.0.5\n"), None);
        assert_eq!(HostKeyChecking::from_ssh_g("stricthostkeychecking sometimes\n"), None);
    }
}
