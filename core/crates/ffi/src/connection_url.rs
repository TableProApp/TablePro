use std::path::Path;

use secrecy::{ExposeSecret, SecretString};
use tablepro_core::connection_url::{self, ConnectionUrl};
use tablepro_core::is_local_socket_host;

use crate::error::CoreError;
use crate::library::{Redacted, TlsModeTag};

#[derive(Clone, uniffi::Record)]
pub struct ParsedConnectionUrl {
    pub driver_id: String,
    pub host: String,
    pub port: Option<u16>,
    pub username: String,
    pub password: Option<SecretString>,
    // The database name, or for a file engine the file's path.
    pub database: String,
    pub tls_mode: Option<TlsModeTag>,
    pub ca_file: Option<String>,
    pub client_certificate: Option<String>,
    pub client_key: Option<String>,
    pub server_name: Option<String>,
}

impl std::fmt::Debug for ParsedConnectionUrl {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ParsedConnectionUrl")
            .field("driver_id", &self.driver_id)
            .field("host", &self.host)
            .field("port", &self.port)
            .field("username", &self.username)
            .field("password", &self.password.as_ref().map(|_| Redacted))
            .field("database", &self.database)
            .field("tls_mode", &self.tls_mode)
            .field("ca_file", &self.ca_file)
            .field("client_certificate", &self.client_certificate)
            .field("client_key", &self.client_key)
            .field("server_name", &self.server_name)
            .finish()
    }
}

#[uniffi::export]
pub fn parse_connection_url(url: SecretString) -> Result<ParsedConnectionUrl, CoreError> {
    let text = url.expose_secret();
    let parsed = connection_url::parse(text).map_err(|error| CoreError::failed(error.code(), error.to_string()))?;
    if let Some(setting) = unkept_setting(&parsed) {
        return Err(CoreError::failed(
            "url.settings_unsupported",
            format!("a saved connection here cannot keep {setting}"),
        ));
    }
    let tls = &parsed.tls;
    let path = |path: Option<&Path>| path.map(|path| path.display().to_string());
    Ok(ParsedConnectionUrl {
        driver_id: parsed.driver_id.to_owned(),
        tls_mode: tls.mode.map(TlsModeTag::from),
        ca_file: path(tls.ca_file.as_deref()),
        client_certificate: path(tls.client_certificate.as_deref()),
        client_key: path(tls.client_key.as_deref()),
        server_name: tls.server_name.clone(),
        host: parsed.host,
        port: parsed.port,
        username: parsed.username,
        password: parsed.password,
        database: parsed.database,
    })
}

// What the host's connection record has no field for: refused rather than dropped, since the connection would fail without it.
fn unkept_setting(parsed: &ConnectionUrl) -> Option<&'static str> {
    let network = !matches!(parsed.driver_id, "sqlite" | "duckdb");
    if network && (parsed.host.is_empty() || is_local_socket_host(&parsed.host)) {
        return Some("a local socket");
    }
    if parsed.options.dns_seed_list {
        return Some("a DNS seed list");
    }
    if parsed.options.uses_host_list() {
        return Some("a replica set");
    }
    if parsed.options.channel_binding {
        return Some("required channel binding");
    }
    if parsed.read_only {
        return Some("read-only access");
    }
    // Without one the driver checks the login in the database, else in admin: the same database needs no field.
    let derived = Some(parsed.database.trim())
        .filter(|name| !name.is_empty())
        .unwrap_or("admin");
    if parsed.options.auth_database().is_some_and(|source| source != derived) {
        return Some("an authentication database");
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(url: &str) -> ParsedConnectionUrl {
        parse_connection_url(SecretString::from(url)).unwrap()
    }

    fn refusal(url: &str) -> String {
        parse_connection_url(SecretString::from(url))
            .unwrap_err()
            .code()
            .to_owned()
    }

    #[test]
    fn a_postgres_url_gives_every_field_decoded() {
        let parsed = parse("postgresql://app%40corp:p%40ss@db.example.com:6543/shop%20db?sslmode=verify-full");

        assert_eq!(parsed.driver_id, "postgres");
        assert_eq!(parsed.host, "db.example.com");
        assert_eq!(parsed.port, Some(6543));
        assert_eq!(parsed.username, "app@corp");
        assert_eq!(parsed.password.as_ref().map(ExposeSecret::expose_secret), Some("p@ss"));
        assert_eq!(parsed.database, "shop db");
        assert_eq!(parsed.tls_mode, Some(TlsModeTag::VerifyFull));
    }

    #[test]
    fn debug_output_shows_the_url_but_not_its_password() {
        let shown = format!("{:?}", parse("postgresql://app:hunter2@db.example.com/shop"));

        assert!(!shown.contains("hunter2"), "{shown}");
        assert!(shown.contains("db.example.com"), "{shown}");
        assert!(shown.contains("password: Some([REDACTED])"), "{shown}");
    }

    #[test]
    fn tls_modes_cross_as_tags() {
        assert_eq!(parse("mysql://root@localhost/app").tls_mode, None);
        assert_eq!(
            parse("sqlserver://db.example.com/sales?encrypt=strict").tls_mode,
            Some(TlsModeTag::Strict)
        );
        assert_eq!(
            parse("postgresql://db/x?sslmode=require").tls_mode,
            Some(TlsModeTag::Require)
        );
        assert_eq!(
            parse("rediss://cache.example.com").tls_mode,
            Some(TlsModeTag::VerifyFull)
        );
        assert_eq!(
            parse("postgresql://db/x?sslmode=disable").tls_mode,
            Some(TlsModeTag::Disable)
        );
        assert_eq!(
            parse("postgresql://db/x?sslmode=prefer").tls_mode,
            Some(TlsModeTag::Prefer)
        );
    }

    #[test]
    fn a_file_url_keeps_its_path() {
        assert_eq!(parse("sqlite:///C:/data/app.db").database, "C:/data/app.db");
        assert_eq!(parse("duckdb:///tmp/a%20b.duckdb").driver_id, "duckdb");
    }

    #[test]
    fn settings_the_record_cannot_keep_are_refused_by_code() {
        for url in [
            "postgresql:///shop?host=/var/run/postgresql",
            "mysql://root@/shop",
            "mongodb+srv://u:p@cluster0.example.net/",
            "mongodb://h1,h2/db?replicaSet=rs0",
            "mongodb://h1/db?authSource=admin",
            "postgresql://u:p@ep-x.neon.tech/db?sslmode=require&channel_binding=require",
        ] {
            assert_eq!(refusal(url), "url.settings_unsupported", "{url}");
        }
    }

    #[test]
    fn certificate_settings_and_a_matching_auth_database_cross() {
        let named = parse("sqlserver://db/s?encrypt=true&hostNameInCertificate=sql.internal");
        assert_eq!(named.server_name.as_deref(), Some("sql.internal"));
        assert_eq!(named.tls_mode, Some(TlsModeTag::VerifyFull));

        let ca = if cfg!(windows) {
            "C:/certs/rds.pem"
        } else {
            "/certs/rds.pem"
        };
        let rooted = parse(&format!("postgresql://db/x?sslmode=require&sslrootcert={ca}"));
        assert_eq!(rooted.tls_mode, Some(TlsModeTag::VerifyFull));
        assert_eq!(rooted.ca_file.as_deref().map(Path::new), Some(Path::new(ca)));

        assert_eq!(parse("mongodb://h/?authSource=admin").driver_id, "mongodb");
        assert_eq!(parse("mongodb://h/shop?authSource=shop").database, "shop");
    }

    #[test]
    fn an_unknown_scheme_and_a_missing_host_are_refused_by_code() {
        assert_eq!(refusal("ftp://example.com"), "url.unknown_scheme");
        assert_eq!(refusal("not a url"), "url.invalid");
        assert_eq!(refusal("redis:///0"), "url.no_host");
    }
}
