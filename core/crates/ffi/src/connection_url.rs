use percent_encoding::percent_decode_str;
use url::Url;

use crate::error::CoreError;
use crate::library::TlsModeTag;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ParsedConnectionUrl {
    pub driver_id: String,
    pub host: String,
    pub port: Option<u16>,
    pub username: String,
    pub password: Option<String>,
    // The database name, or for a file engine the file's path.
    pub database: String,
    pub tls_mode: Option<TlsModeTag>,
}

#[uniffi::export]
pub fn parse_connection_url(url: String) -> Result<ParsedConnectionUrl, CoreError> {
    let trimmed = url.trim();
    let parsed = Url::parse(trimmed).map_err(|error| CoreError::failed("url.invalid", error.to_string()))?;
    let scheme = parsed.scheme().to_ascii_lowercase();
    let Some(driver_id) = driver_for(&scheme) else {
        return Err(CoreError::failed(
            "url.unknown_scheme",
            format!("no engine reads {scheme} URLs"),
        ));
    };
    if matches!(driver_id, "sqlite" | "duckdb") {
        return Ok(ParsedConnectionUrl {
            driver_id: driver_id.to_owned(),
            host: String::new(),
            port: None,
            username: String::new(),
            password: None,
            database: file_path(&parsed),
            tls_mode: None,
        });
    }
    let host = parsed
        .host_str()
        .map(|host| host.trim_start_matches('[').trim_end_matches(']').to_owned())
        .filter(|host| !host.is_empty())
        .ok_or_else(|| CoreError::failed("url.no_host", "the URL names no host"))?;
    let database = decoded(parsed.path().trim_start_matches('/'));
    Ok(ParsedConnectionUrl {
        driver_id: driver_id.to_owned(),
        host,
        port: parsed.port(),
        username: decoded(parsed.username()),
        password: parsed.password().map(decoded),
        database,
        tls_mode: tls_mode(&scheme, &parsed),
    })
}

fn driver_for(scheme: &str) -> Option<&'static str> {
    Some(match scheme {
        "postgres" | "postgresql" => "postgres",
        "mysql" | "mariadb" => "mysql",
        "sqlserver" | "mssql" => "mssql",
        "mongodb" | "mongodb+srv" => "mongodb",
        "redis" | "rediss" => "redis",
        "clickhouse" => "clickhouse",
        "cassandra" => "cassandra",
        "sqlite" | "sqlite3" => "sqlite",
        "duckdb" => "duckdb",
        _ => return None,
    })
}

fn decoded(text: &str) -> String {
    percent_decode_str(text).decode_utf8_lossy().into_owned()
}

// `sqlite:///C:/data/app.db` keeps the drive letter, and `sqlite://app.db` reads as a relative name.
fn file_path(parsed: &Url) -> String {
    let path = decoded(parsed.path());
    let host = parsed.host_str().unwrap_or_default();
    if !host.is_empty() {
        return format!("{host}{path}");
    }
    let bytes = path.as_bytes();
    if bytes.len() >= 3 && bytes[0] == b'/' && bytes[1].is_ascii_alphabetic() && bytes[2] == b':' {
        return path[1..].to_owned();
    }
    path
}

fn tls_mode(scheme: &str, parsed: &Url) -> Option<TlsModeTag> {
    if scheme == "rediss" {
        return Some(TlsModeTag::VerifyFull);
    }
    // A seed list turns TLS on unless the URL turns it off, as mongosh reads it.
    let mut mode = (scheme == "mongodb+srv").then_some(TlsModeTag::VerifyFull);
    let mut trusts_any_certificate = false;
    for (key, value) in parsed.query_pairs() {
        let value = value.to_ascii_lowercase();
        match key.to_ascii_lowercase().as_str() {
            "sslmode" | "ssl-mode" => {
                mode = match value.as_str() {
                    "disable" | "disabled" => Some(TlsModeTag::Disable),
                    // allow takes TLS only when the server demands it; Prefer is the nearest mode.
                    "allow" | "prefer" | "preferred" => Some(TlsModeTag::Prefer),
                    "require" | "required" => Some(TlsModeTag::Require),
                    "verify-ca" | "verify-full" | "verify_ca" | "verify_identity" => Some(TlsModeTag::VerifyFull),
                    _ => mode,
                };
            }
            "ssl" | "tls" | "encrypt" => {
                mode = match value.as_str() {
                    // SQL Server's Encrypt=strict, TDS 8.0.
                    "strict" if key.eq_ignore_ascii_case("encrypt") => Some(TlsModeTag::Strict),
                    "true" | "1" | "yes" | "strict" | "mandatory" => Some(TlsModeTag::VerifyFull),
                    "false" | "0" | "no" | "optional" => Some(TlsModeTag::Disable),
                    _ => mode,
                };
            }
            "trustservercertificate" | "tlsallowinvalidcertificates" | "tlsinsecure" => {
                trusts_any_certificate = matches!(value.as_str(), "true" | "1" | "yes");
            }
            _ => {}
        }
    }
    // Microsoft's drivers encrypt by default, and refuse to trust the certificate under strict.
    let encrypts_by_default = matches!(scheme, "sqlserver" | "mssql");
    match mode {
        Some(TlsModeTag::VerifyFull) if trusts_any_certificate => Some(TlsModeTag::Require),
        None if trusts_any_certificate && encrypts_by_default => Some(TlsModeTag::Require),
        mode => mode,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(url: &str) -> ParsedConnectionUrl {
        parse_connection_url(url.to_owned()).unwrap()
    }

    #[test]
    fn a_postgres_url_gives_every_field_decoded() {
        let parsed = parse("postgresql://app%40corp:p%40ss@db.example.com:6543/shop%20db?sslmode=verify-full");

        assert_eq!(parsed.driver_id, "postgres");
        assert_eq!(parsed.host, "db.example.com");
        assert_eq!(parsed.port, Some(6543));
        assert_eq!(parsed.username, "app@corp");
        assert_eq!(parsed.password.as_deref(), Some("p@ss"));
        assert_eq!(parsed.database, "shop db");
        assert_eq!(parsed.tls_mode, Some(TlsModeTag::VerifyFull));
    }

    #[test]
    fn a_url_without_a_port_leaves_the_engine_s_default() {
        let parsed = parse("mysql://root@localhost/app");

        assert_eq!(parsed.driver_id, "mysql");
        assert_eq!(parsed.port, None);
        assert_eq!(parsed.password, None);
        assert_eq!(parsed.tls_mode, None);
    }

    #[test]
    fn an_ipv6_host_loses_its_brackets() {
        assert_eq!(parse("redis://[::1]:6380/2").host, "::1");
    }

    #[test]
    fn sql_servers_encrypt_strict_is_strict_tls() {
        assert_eq!(
            parse("sqlserver://db.example.com/sales?encrypt=strict").tls_mode,
            Some(TlsModeTag::Strict)
        );
        assert_eq!(
            parse("sqlserver://db.example.com/sales?encrypt=true").tls_mode,
            Some(TlsModeTag::VerifyFull)
        );
    }

    #[test]
    fn prefer_and_allow_are_prefer() {
        for url in [
            "postgres://db.example.com/app?sslmode=prefer",
            "postgres://db.example.com/app?sslmode=allow",
            "mysql://db.example.com/app?ssl-mode=PREFERRED",
        ] {
            assert_eq!(parse(url).tls_mode, Some(TlsModeTag::Prefer), "{url}");
        }
        assert_eq!(
            parse("postgres://db.example.com/app?sslmode=disable").tls_mode,
            Some(TlsModeTag::Disable)
        );
    }

    #[test]
    fn a_seed_list_url_means_tls_unless_it_says_otherwise() {
        assert_eq!(
            parse("mongodb+srv://cluster0.example.net/app").tls_mode,
            Some(TlsModeTag::VerifyFull)
        );
        assert_eq!(
            parse("mongodb+srv://cluster0.example.net/app?tls=false").tls_mode,
            Some(TlsModeTag::Disable)
        );
        assert_eq!(parse("mongodb://localhost/app").tls_mode, None);
    }

    #[test]
    fn a_url_that_trusts_any_certificate_does_not_check_it() {
        for url in [
            "sqlserver://db.example.com/sales?encrypt=true&trustServerCertificate=true",
            "mongodb://db.example.com/app?tls=true&tlsAllowInvalidCertificates=true",
            "mongodb+srv://cluster0.example.net/app?tlsInsecure=true",
            "sqlserver://db.example.com/sales?trustServerCertificate=true",
        ] {
            assert_eq!(parse(url).tls_mode, Some(TlsModeTag::Require), "{url}");
        }
        assert_eq!(
            parse("sqlserver://db.example.com/sales?encrypt=strict&trustServerCertificate=true").tls_mode,
            Some(TlsModeTag::Strict)
        );
        assert_eq!(
            parse("sqlserver://db.example.com/sales?encrypt=mandatory&trustServerCertificate=false").tls_mode,
            Some(TlsModeTag::VerifyFull)
        );
    }

    #[test]
    fn rediss_means_tls() {
        assert_eq!(
            parse("rediss://cache.example.com").tls_mode,
            Some(TlsModeTag::VerifyFull)
        );
    }

    #[test]
    fn a_file_url_keeps_a_windows_drive_and_a_unix_path() {
        assert_eq!(parse("sqlite:///C:/data/app.db").database, "C:/data/app.db");
        assert_eq!(parse("sqlite:///home/ada/app.db").database, "/home/ada/app.db");
        assert_eq!(parse("duckdb:///tmp/a%20b.duckdb").driver_id, "duckdb");
    }

    #[test]
    fn an_unknown_scheme_and_a_missing_host_are_refused_by_code() {
        let unknown = parse_connection_url("ftp://example.com".to_owned()).unwrap_err();
        let invalid = parse_connection_url("not a url".to_owned()).unwrap_err();

        assert_eq!(unknown.code(), "url.unknown_scheme");
        assert_eq!(invalid.code(), "url.invalid");
    }
}
