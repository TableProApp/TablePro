use std::path::{Path, PathBuf};

use super::{ConnectionUrlError, UrlTls};
use crate::TlsMode;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Wanted {
    Disable,
    // Try TLS, fall back to none: libpq's prefer, MySQL's PREFERRED.
    Prefer,
    Require,
    VerifyFull,
    Strict,
}

// What a URL says about TLS, read in any order and resolved once: a mode wins over a switch, which wins over the scheme.
#[derive(Debug, Default)]
pub(super) struct TlsHints {
    mode: Option<Wanted>,
    switch: Option<Wanted>,
    pub(super) by_scheme: Option<Wanted>,
    // The last of the switches that turn the certificate check off, as JDBC reads a property given twice.
    weakened: Option<bool>,
    verify_server: bool,
    // MariaDB's Connector/J checks the certificate under useSsl; MySQL's checks it only with verifyServerCertificate.
    pub(super) use_ssl_verifies: bool,
    system_roots: bool,
    ca_file: Option<PathBuf>,
    certificate: Option<PathBuf>,
    key: Option<PathBuf>,
    server_name: Option<String>,
    wildcard_name: Option<String>,
}

impl TlsHints {
    // Returns whether the key is one TLS reads.
    pub(super) fn read(&mut self, key: &str, value: &str) -> Result<bool, ConnectionUrlError> {
        let lower = value.trim().to_ascii_lowercase();
        match key {
            // A mode the parser does not know may ask for more than any it does, so it refuses the URL.
            "sslmode" | "ssl-mode" | "ssl_mode" => self.mode = Some(named_mode(&lower).ok_or_else(|| unknown(key))?),
            "tlsmode" => self.mode = Some(numbered_mode(&lower).ok_or_else(|| unknown(key))?),
            "ssl" | "tls" | "secure" | "s" => self.switch = switch(&lower).or(self.switch),
            "usessl" => {
                self.switch = match switch(&lower) {
                    Some(Wanted::VerifyFull) if !self.use_ssl_verifies => Some(Wanted::Require),
                    other => other.or(self.switch),
                }
            }
            "verifyservercertificate" => self.verify_server |= is_true(&lower),
            "sslaccept" => {
                self.switch = match lower.as_str() {
                    "strict" => Some(Wanted::VerifyFull),
                    "accept_invalid_certs" => Some(Wanted::Require),
                    _ => self.switch,
                }
            }
            "encrypt" => {
                self.switch = match lower.as_str() {
                    "strict" => Some(Wanted::Strict),
                    "true" | "yes" | "mandatory" => Some(Wanted::VerifyFull),
                    "false" | "no" | "optional" => Some(Wanted::Disable),
                    _ => self.switch,
                }
            }
            // Only a check of the whole certificate can be turned off; a name check alone stays on.
            "trustservercertificate" | "tlsinsecure" | "tlsallowinvalidcertificates" => {
                self.weakened = Some(is_true(&lower));
            }
            "sslrootcert" if lower == "system" => self.system_roots = true,
            // libpq's, MongoDB's and the mysql client's spellings.
            "sslrootcert" | "tlscafile" | "ssl-ca" | "ssl_ca" => self.ca_file = Some(absolute(value)?),
            "sslcert" | "ssl-cert" | "ssl_cert" => self.certificate = Some(absolute(value)?),
            "sslkey" | "ssl-key" | "ssl_key" => self.key = Some(absolute(value)?),
            // One PEM holding both, which each loader reads its part of.
            "tlscertificatekeyfile" => {
                let both = absolute(value)?;
                self.certificate = Some(both.clone());
                self.key = Some(both);
            }
            "hostnameincertificate" => {
                let name = value.trim();
                match name.contains('*') {
                    true => self.wildcard_name = Some(name.to_ascii_lowercase()),
                    false if !name.is_empty() => self.server_name = Some(name.to_owned()),
                    false => {}
                }
            }
            _ => return Ok(false),
        }
        Ok(true)
    }

    pub(super) fn asks_for_tls(&self) -> bool {
        matches!(
            self.mode.or(self.switch).or(self.by_scheme),
            Some(Wanted::Require | Wanted::VerifyFull | Wanted::Strict)
        )
    }

    // TLS, a CA or a client certificate: what a server that takes no TLS cannot give.
    pub(super) fn requires_protection(&self) -> bool {
        self.asks_for_tls() || self.ca_file.is_some() || self.certificate.is_some() || self.system_roots
    }

    // The host is the name checked, so a wildcard the URL asks for holds only when the host is one it covers,
    // as `*.database.windows.net` covers `srv.database.windows.net`.
    pub(super) fn check_wildcard(&self, host: &str) -> Result<(), ConnectionUrlError> {
        let Some(wildcard) = &self.wildcard_name else {
            return Ok(());
        };
        let host = host.to_ascii_lowercase();
        let covered = wildcard
            .strip_prefix("*.")
            .and_then(|domain| host.strip_suffix(domain))
            .and_then(|label| label.strip_suffix('.'))
            .is_some_and(|label| !label.is_empty() && !label.contains('.'));
        match covered {
            true => Ok(()),
            false => Err(ConnectionUrlError::UnsupportedParameter {
                name: "hostNameInCertificate".to_owned(),
            }),
        }
    }

    pub(super) fn weaken(&mut self) {
        self.weakened = Some(true);
    }

    // No mode leaves it to the form: the URL said nothing, or asked for prefer, which the core does not have.
    pub(super) fn resolve(self) -> UrlTls {
        let mut wanted = self.mode.or(self.switch).or(self.by_scheme);
        if self.verify_server && matches!(wanted, None | Some(Wanted::Prefer | Wanted::Require)) {
            wanted = Some(Wanted::VerifyFull);
        }
        let verifies_with_roots = self.ca_file.is_some() || self.system_roots;
        if verifies_with_roots && matches!(wanted, None | Some(Wanted::Prefer | Wanted::Require)) {
            wanted = Some(Wanted::VerifyFull);
        }
        if self.weakened == Some(true) && wanted == Some(Wanted::VerifyFull) {
            wanted = Some(Wanted::Require);
        }
        let mode = wanted.and_then(|wanted| match wanted {
            Wanted::Disable => Some(TlsMode::Disable),
            Wanted::Prefer => None,
            Wanted::Require => Some(TlsMode::Require),
            Wanted::VerifyFull => Some(TlsMode::VerifyFull),
            Wanted::Strict => Some(TlsMode::Strict),
        });
        if mode == Some(TlsMode::Disable) {
            return UrlTls {
                mode,
                ..UrlTls::default()
            };
        }
        UrlTls {
            mode,
            ca_file: self.ca_file.filter(|_| mode.is_none_or(TlsMode::verifies_certificate)),
            client_certificate: self.certificate,
            client_key: self.key,
            server_name: self.server_name,
        }
    }
}

fn named_mode(value: &str) -> Option<Wanted> {
    Some(match value.replace('_', "-").as_str() {
        "disable" | "disabled" => Wanted::Disable,
        "allow" | "prefer" | "preferred" => Wanted::Prefer,
        "require" | "required" => Wanted::Require,
        "verify-ca" | "verify-full" | "verify-identity" => Wanted::VerifyFull,
        // ClickHouse JDBC's own spellings, and MariaDB Connector/J's trust.
        "strict" => Wanted::VerifyFull,
        "none" | "trust" => Wanted::Require,
        _ => return None,
    })
}

fn numbered_mode(value: &str) -> Option<Wanted> {
    Some(match value {
        "0" => Wanted::Disable,
        "1" => Wanted::Prefer,
        "2" => Wanted::Require,
        "3" | "4" => Wanted::VerifyFull,
        _ => return None,
    })
}

fn switch(value: &str) -> Option<Wanted> {
    // mysql2's `ssl={"rejectUnauthorized":true}`, which checks the certificate unless told not to.
    if value.starts_with('{') {
        let options: serde_json::Value = serde_json::from_str(value).ok()?;
        return Some(match options.get("rejectunauthorized") {
            Some(serde_json::Value::Bool(false)) => Wanted::Require,
            _ => Wanted::VerifyFull,
        });
    }
    match value {
        // clickhouse-client's `secure` and `s` need no value.
        "" | "true" | "1" | "yes" => Some(Wanted::VerifyFull),
        "false" | "0" | "no" => Some(Wanted::Disable),
        _ => None,
    }
}

fn is_true(value: &str) -> bool {
    matches!(value, "" | "true" | "1" | "yes")
}

fn unknown(key: &str) -> ConnectionUrlError {
    ConnectionUrlError::UnsupportedParameter { name: key.to_owned() }
}

fn absolute(value: &str) -> Result<PathBuf, ConnectionUrlError> {
    let path = Path::new(value.trim());
    if path.is_absolute() {
        Ok(path.to_path_buf())
    } else {
        Err(ConnectionUrlError::RelativePath)
    }
}
