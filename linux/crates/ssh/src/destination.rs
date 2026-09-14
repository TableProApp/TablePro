use std::fmt;

use tablepro_core::SshFailure;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SshDestination {
    host: String,
    port: Option<u16>,
    user: Option<String>,
}

impl SshDestination {
    pub fn new(host: impl AsRef<str>, port: Option<u16>, user: Option<String>) -> Result<Self, SshFailure> {
        let trimmed = host.as_ref().trim();
        let host = trimmed
            .strip_prefix('[')
            .and_then(|inner| inner.strip_suffix(']'))
            .unwrap_or(trimmed);
        check_part("host", host)?;
        if port == Some(0) {
            return Err(invalid("port 0 is not a valid port"));
        }
        if let Some(user) = &user {
            check_part("user", user)?;
        }
        Ok(Self {
            host: host.to_owned(),
            port,
            user,
        })
    }

    pub fn parse_jump_list(list: &str) -> Result<Vec<SshDestination>, SshFailure> {
        if list.trim().is_empty() {
            return Ok(Vec::new());
        }
        list.split(',').map(|entry| Self::parse(entry.trim())).collect()
    }

    fn parse(entry: &str) -> Result<SshDestination, SshFailure> {
        let (user, rest) = match entry.rsplit_once('@') {
            Some((user, rest)) => (Some(user.to_owned()), rest),
            None => (None, entry),
        };
        let (host, port) = if let Some(bracketed) = rest.strip_prefix('[') {
            let (host, after) = bracketed
                .split_once(']')
                .ok_or_else(|| invalid("an IPv6 host is missing its closing ']'"))?;
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

fn check_part(name: &str, value: &str) -> Result<(), SshFailure> {
    if value.is_empty() {
        return Err(invalid(&format!("the {name} is empty")));
    }
    if value.starts_with('-') {
        return Err(invalid(&format!("the {name} starts with '-'")));
    }
    if value.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(invalid(&format!("the {name} contains spaces or control characters")));
    }
    Ok(())
}

fn parse_port(text: &str) -> Result<u16, SshFailure> {
    text.parse::<u16>()
        .map_err(|_| invalid(&format!("'{text}' is not a port number")))
}

fn invalid(detail: &str) -> SshFailure {
    SshFailure::InvalidDestination {
        detail: detail.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn destination_rejects_empty_leading_dash_whitespace_control_and_port_zero() {
        let rejected = [
            SshDestination::new("", None, None),
            SshDestination::new("-oProxyCommand=x", None, None),
            SshDestination::new("bastion host", None, None),
            SshDestination::new("bastion\u{7}", None, None),
            SshDestination::new("bastion", Some(0), None),
            SshDestination::new("bastion", None, Some("-lroot".to_owned())),
            SshDestination::new("bastion", None, Some(String::new())),
        ];
        for result in rejected {
            assert!(
                matches!(result, Err(SshFailure::InvalidDestination { .. })),
                "{result:?}"
            );
        }
        let accepted = SshDestination::new(" bastion.example.com ", Some(2222), Some("deploy".to_owned())).unwrap();
        assert_eq!(accepted.host(), "bastion.example.com");
        assert_eq!(accepted.to_string(), "deploy@bastion.example.com:2222");
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
        assert!(SshDestination::parse_jump_list("jump1,,jump2").is_err());
        assert!(SshDestination::parse_jump_list("jump1:ssh").is_err());
    }
}
