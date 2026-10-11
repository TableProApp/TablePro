use std::fmt;
use std::net::SocketAddr;
use std::path::PathBuf;

use super::OpenSshError;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SshDestination {
    host: String,
    port: Option<u16>,
    user: Option<String>,
}

impl SshDestination {
    pub fn new(host: impl AsRef<str>, port: Option<u16>, user: Option<String>) -> Result<Self, OpenSshError> {
        let host = unbracketed(host.as_ref());
        check_part("host", host).map_err(invalid_destination)?;
        if port == Some(0) {
            return Err(invalid_destination("port 0 is not a valid port".to_owned()));
        }
        if let Some(user) = &user {
            check_part("user", user).map_err(invalid_destination)?;
        }
        Ok(Self {
            host: host.to_owned(),
            port,
            user,
        })
    }

    pub fn parse_jump_list(list: &str) -> Result<Vec<SshDestination>, OpenSshError> {
        if list.trim().is_empty() {
            return Ok(Vec::new());
        }
        list.split(',').map(|entry| Self::parse(entry.trim())).collect()
    }

    fn parse(entry: &str) -> Result<SshDestination, OpenSshError> {
        let (user, rest) = match entry.rsplit_once('@') {
            Some((user, rest)) => (Some(user.to_owned()), rest),
            None => (None, entry),
        };
        let (host, port) = split_host_port(rest).map_err(invalid_destination)?;
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
        write_host(f, &self.host)?;
        if let Some(port) = self.port {
            write!(f, ":{port}")?;
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ForwardTarget {
    host: String,
    port: u16,
}

impl ForwardTarget {
    pub fn new(host: impl AsRef<str>, port: u16) -> Result<Self, OpenSshError> {
        let host = unbracketed(host.as_ref());
        check_part("host", host).map_err(invalid_target)?;
        if host.contains(['/', '[', ']']) {
            return Err(invalid_target("the host contains '/', '[' or ']'".to_owned()));
        }
        if port == 0 {
            return Err(invalid_target("port 0 is not a valid port".to_owned()));
        }
        Ok(Self {
            host: host.to_owned(),
            port,
        })
    }

    pub fn host(&self) -> &str {
        &self.host
    }

    pub fn port(&self) -> u16 {
        self.port
    }
}

impl fmt::Display for ForwardTarget {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write_host(f, &self.host)?;
        write!(f, ":{}", self.port)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum LocalEndpoint {
    Unix(PathBuf),
    Tcp(SocketAddr),
}

fn write_host(f: &mut fmt::Formatter<'_>, host: &str) -> fmt::Result {
    if host.contains(':') {
        write!(f, "[{host}]")
    } else {
        f.write_str(host)
    }
}

fn unbracketed(host: &str) -> &str {
    let trimmed = host.trim();
    trimmed
        .strip_prefix('[')
        .and_then(|inner| inner.strip_suffix(']'))
        .unwrap_or(trimmed)
}

fn split_host_port(rest: &str) -> Result<(&str, Option<u16>), String> {
    if let Some(bracketed) = rest.strip_prefix('[') {
        let (host, after) = bracketed
            .split_once(']')
            .ok_or_else(|| "an IPv6 host is missing its closing ']'".to_owned())?;
        if after.is_empty() {
            return Ok((host, None));
        }
        let port = after.strip_prefix(':').unwrap_or(after);
        return Ok((host, Some(parse_port(port)?)));
    }
    match rest.split_once(':') {
        Some((host, port)) if !port.contains(':') => Ok((host, Some(parse_port(port)?))),
        _ => Ok((rest, None)),
    }
}

fn check_part(name: &str, value: &str) -> Result<(), String> {
    if value.is_empty() {
        return Err(format!("the {name} is empty"));
    }
    if value.starts_with('-') {
        return Err(format!("the {name} starts with '-'"));
    }
    if value.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(format!("the {name} contains spaces or control characters"));
    }
    Ok(())
}

fn parse_port(text: &str) -> Result<u16, String> {
    text.parse::<u16>()
        .map_err(|_| format!("'{text}' is not a port number"))
}

fn invalid_destination(detail: String) -> OpenSshError {
    OpenSshError::InvalidDestination { detail }
}

fn invalid_target(detail: String) -> OpenSshError {
    OpenSshError::InvalidForwardTarget { detail }
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
                matches!(result, Err(OpenSshError::InvalidDestination { .. })),
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
        assert!(SshDestination::parse_jump_list("[fd00::1").is_err());
    }

    #[test]
    fn forward_target_brackets_ipv6_and_rejects_socket_paths_and_options() {
        assert_eq!(
            ForwardTarget::new("fd00::5", 5432).unwrap().to_string(),
            "[fd00::5]:5432"
        );
        assert_eq!(ForwardTarget::new("[fd00::5]", 5432).unwrap().host(), "fd00::5");
        assert_eq!(
            ForwardTarget::new("db.internal", 5432).unwrap().to_string(),
            "db.internal:5432"
        );
        for (host, port) in [("/run/db.sock", 5432), ("-oX", 5432), ("db", 0), ("a]b", 1), ("", 1)] {
            assert!(
                matches!(
                    ForwardTarget::new(host, port),
                    Err(OpenSshError::InvalidForwardTarget { .. })
                ),
                "{host}"
            );
        }
    }
}
