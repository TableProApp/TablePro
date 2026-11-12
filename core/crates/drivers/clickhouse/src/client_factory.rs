use std::time::Duration;

use hyper_rustls::{FixedServerNameResolver, HttpsConnectorBuilder};
use hyper_util::client::legacy::Client as HyperClient;
use hyper_util::rt::TokioExecutor;
use rustls_pki_types::ServerName;
use secrecy::ExposeSecret;
use tablepro_core::{
    APPLICATION_NAME, ConfigError, ConnectEnvironment, Credentials, DriverError, LivenessPolicy, NetworkTarget,
    TlsFailure,
};
use tablepro_net::tls::{TlsSetupError, build_client_config};

use crate::transport_connector::TransportConnector;

/// Shorter than the server's keep-alive, which is 3 s before 23.11 and
/// 10 s after, so a pooled connection is never one the server is about
/// to close.
const POOL_IDLE_TIMEOUT: Duration = Duration::from_secs(2);

/// The header that asks the server to log the user in by the client
/// certificate's common name instead of a password.
const CERTIFICATE_AUTH_HEADER: &str = "X-ClickHouse-SSL-Certificate-Auth";

const COMMON_SETTINGS: [(&str, &str); 7] = [
    // A Decimal is written at its column's scale, so a value read back
    // keeps the scale it was stored with and compares equal to it.
    ("output_format_decimal_trailing_zeros", "1"),
    // A DateTime is read as `YYYY-MM-DD hh:mm:ss` in its own time zone.
    // A profile or session that set `iso` would send it in UTC instead,
    // and a save keyed on it would miss its row.
    ("date_time_output_format", "simple"),
    // An error after the first rows is written as plain exception text,
    // which the clickhouse crate detects, rather than as one more row in
    // the output format, which would read as data.
    ("http_write_exception_in_output_format", "0"),
    // NaN and infinity are written as quoted words; without this they
    // come back as null.
    ("output_format_json_quote_denormals", "1"),
    // The bytes of a String go out as stored, so a value that is not
    // UTF-8 is read back exactly instead of with replacement characters.
    ("output_format_json_validate_utf8", "0"),
    // A save waits for its mutation, so the grid refetches what the save
    // wrote rather than what was there before. Not 2, which waits for
    // every replica: with one down, each save would wait out
    // `replication_wait_for_inactive_replica_timeout`, two minutes by
    // default, and then end with UNFINISHED although the live replicas
    // applied it.
    (MUTATIONS_SYNC, "1"),
    // A read whose connection the app dropped stops on the server even
    // when no KILL could be sent.
    ("cancel_http_readonly_queries_on_client_close", "1"),
];

pub(crate) const MAX_EXECUTION_TIME: &str = "max_execution_time";
pub(crate) const TIMEOUT_OVERFLOW_MODE: &str = "timeout_overflow_mode";
pub(crate) const MUTATIONS_SYNC: &str = "mutations_sync";

// A login at `readonly=1`, or one a profile constraint holds to a value, refuses the whole request that changes such a
// setting (164, 452), so the driver sends only what `system.settings` says this login may change.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ChangeableSettings(Vec<&'static str>);

impl ChangeableSettings {
    pub(crate) fn all() -> Self {
        Self(Self::asked().collect())
    }

    pub(crate) fn asked() -> impl Iterator<Item = &'static str> {
        COMMON_SETTINGS
            .into_iter()
            .map(|(name, _)| name)
            .chain([MAX_EXECUTION_TIME, TIMEOUT_OVERFLOW_MODE])
    }

    pub(crate) fn listed(names: &[String]) -> Self {
        Self(
            Self::asked()
                .filter(|asked| names.iter().any(|name| name == asked))
                .collect(),
        )
    }

    pub(crate) fn allows(&self, name: &str) -> bool {
        self.0.contains(&name)
    }

    pub(crate) fn common(&self) -> impl Iterator<Item = (&'static str, &'static str)> + '_ {
        COMMON_SETTINGS.into_iter().filter(|(name, _)| self.allows(name))
    }

    // A bound without the mode would let a profile's `timeout_overflow_mode=break` end a read at it with the rows read
    // so far, as if they were all.
    pub(crate) fn bounds_reads(&self) -> bool {
        self.allows(MAX_EXECUTION_TIME) && self.allows(TIMEOUT_OVERFLOW_MODE)
    }
}

// `readonly=2` still lets `INSERT INTO FUNCTION file(...)` write a file (measured on 26.8); 1 refuses it and still
// takes the settings a request carries. A login at 2 refuses any change of `readonly`. One at 1 takes the 1 as no
// change, and it puts back a session that ran `SET readonly = 0`, which a profile marking `readonly`
// `changeable_in_readonly` lets it run.
pub(crate) fn strict_readonly(login_level: u8) -> Option<&'static str> {
    (login_level <= 1).then_some("1")
}

// User SQL and everything on a read-only connection is held strictly. The app's own reads keep 2, which still lets
// them carry settings of their own.
pub(crate) fn read_level(read_only: bool, user_sql: bool, login_level: u8) -> Option<&'static str> {
    if read_only || user_sql {
        return strict_readonly(login_level);
    }
    (login_level != 1).then_some("2")
}

pub(crate) fn read_only_settings(login_level: u8) -> Vec<(&'static str, &'static str)> {
    let mut settings = Vec::new();
    // A login at 1 refuses the change, and `readonly=1` refuses the DDL it would.
    if login_level != 1 {
        settings.push(("allow_ddl", "0"));
    }
    settings.extend(strict_readonly(login_level).map(|level| ("readonly", level)));
    settings
}

// No setting goes on here: the login's first answer says which of the driver's it may change. The crate's own TLS
// stays unused, since TLS is negotiated over the transport's stream against the trust the target names.
pub(crate) fn base_client(
    target: &NetworkTarget,
    liveness: &LivenessPolicy,
    environment: &ConnectEnvironment,
) -> Result<clickhouse::Client, DriverError> {
    let connector = TransportConnector::new(target.transport.clone(), liveness.connect_timeout);
    let tls = build_client_config(&target.tls).map_err(setup_error)?;
    let mut builder = HyperClient::builder(TokioExecutor::new());
    builder.pool_idle_timeout(POOL_IDLE_TIMEOUT);
    let scheme = if tls.is_some() { "https" } else { "http" };
    let client = match tls {
        None => clickhouse::Client::with_http_client(builder.build(connector)),
        Some(config) => {
            let name = ServerName::try_from(target.tls_server_name().to_owned())
                .map_err(|_| DriverError::Config(ConfigError::InvalidServerName))?;
            let https = HttpsConnectorBuilder::new()
                .with_tls_config((*config).clone())
                .https_only()
                .with_server_name_resolver(FixedServerNameResolver::new(name))
                .enable_http1()
                .wrap_connector(connector);
            clickhouse::Client::with_http_client(builder.build(https))
        }
    };
    // A typed fetch then reads RowBinary, which names no column types, so no type name the server sends is parsed,
    // however deep it nests, nor a list sized by the column count the server claims.
    let client = client
        .with_url(service_url(scheme, target))
        .with_validation(false)
        .with_product_info(APPLICATION_NAME, environment.client_version.clone());
    let mut client = with_credentials(client, target)?;
    if let Some(database) = target.database.as_deref().filter(|name| !name.is_empty()) {
        client = client.with_database(database);
    }
    Ok(client)
}

/// The URL names the service the transport reaches, not the socket it
/// opens, since that name is what the Host header and the certificate
/// are about.
fn service_url(scheme: &str, target: &NetworkTarget) -> String {
    let service = target.transport.service_endpoint();
    let host = service.host();
    if host.contains(':') {
        format!("{scheme}://[{host}]:{}", service.port())
    } else {
        format!("{scheme}://{host}:{}", service.port())
    }
}

fn with_credentials(client: clickhouse::Client, target: &NetworkTarget) -> Result<clickhouse::Client, DriverError> {
    let Credentials::Password { username, password } = &target.credentials else {
        return Err(DriverError::Config(ConfigError::AuthModeUnsupported));
    };
    let mut client = client;
    if !username.is_empty() {
        client = client.with_user(username.as_str());
    }
    if target.tls.client_identity.is_some() {
        return Ok(client.with_header(CERTIFICATE_AUTH_HEADER, "on"));
    }
    let password = password.expose_secret();
    if !password.is_empty() {
        client = client.with_password(password);
    }
    Ok(client)
}

fn setup_error(error: TlsSetupError) -> DriverError {
    match error {
        TlsSetupError::Config(error) => DriverError::Config(error),
        TlsSetupError::ClientIdentity(error) => DriverError::Tls {
            failure: TlsFailure::ClientIdentityInvalid,
            detail: error.to_string(),
        },
        other => DriverError::Tls {
            failure: TlsFailure::Other,
            detail: other.to_string(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_read_only_connection_asks_for_readonly_1_which_refuses_writing_a_file() {
        assert_eq!(read_only_settings(0), vec![("allow_ddl", "0"), ("readonly", "1")]);
    }

    #[test]
    fn a_login_with_a_readonly_level_of_its_own_keeps_it() {
        assert_eq!(read_only_settings(2), vec![("allow_ddl", "0")]);
    }

    #[test]
    fn a_read_only_connection_holds_a_login_at_readonly_1_to_its_level_without_allow_ddl() {
        assert_eq!(read_only_settings(1), vec![("readonly", "1")]);
    }

    #[test]
    fn only_the_drivers_own_settings_the_server_lists_are_changeable() {
        let listed = ["mutations_sync", "max_threads", MAX_EXECUTION_TIME].map(str::to_owned);

        let changeable = ChangeableSettings::listed(&listed);

        assert!(changeable.allows("mutations_sync"));
        assert!(changeable.allows(MAX_EXECUTION_TIME));
        assert!(!changeable.allows("max_threads"));
        assert!(!changeable.allows("output_format_json_quote_denormals"));
        assert_eq!(changeable.common().collect::<Vec<_>>(), vec![("mutations_sync", "1")]);
    }

    #[test]
    fn a_read_is_bounded_on_the_server_only_with_its_overflow_mode() {
        let bound_only = ChangeableSettings::listed(&[MAX_EXECUTION_TIME.to_owned()]);
        let both = ChangeableSettings::listed(&[MAX_EXECUTION_TIME.to_owned(), TIMEOUT_OVERFLOW_MODE.to_owned()]);

        assert!(!bound_only.bounds_reads());
        assert!(both.bounds_reads());
        assert!(ChangeableSettings::all().bounds_reads());
    }

    #[test]
    fn a_login_that_may_change_nothing_gets_no_common_setting() {
        let changeable = ChangeableSettings::listed(&[]);

        assert_eq!(changeable.common().count(), 0);
        assert!(!changeable.bounds_reads());
        assert_eq!(ChangeableSettings::all().common().count(), COMMON_SETTINGS.len());
    }

    #[test]
    fn user_sql_is_held_to_readonly_1_on_any_connection() {
        assert_eq!(read_level(false, true, 0), Some("1"));
        assert_eq!(read_level(true, true, 0), Some("1"));
        assert_eq!(read_level(true, false, 0), Some("1"));
        assert_eq!(read_level(false, false, 0), Some("2"));
    }

    #[test]
    fn no_read_asks_a_login_at_its_own_level_for_another() {
        assert_eq!(read_level(false, true, 2), None);
        assert_eq!(read_level(false, false, 2), Some("2"));
        assert_eq!(read_level(false, false, 1), None);
    }

    #[test]
    fn user_sql_and_a_read_only_connection_hold_a_login_at_readonly_1_to_its_level() {
        assert_eq!(read_level(false, true, 1), Some("1"));
        assert_eq!(read_level(true, true, 1), Some("1"));
        assert_eq!(read_level(true, false, 1), Some("1"));
    }

    #[test]
    fn only_a_refused_client_certificate_is_a_client_identity_failure() {
        let refused_identity = setup_error(TlsSetupError::ClientIdentity(rustls::Error::InconsistentKeys(
            rustls::InconsistentKeys::KeyMismatch,
        )));
        let no_trust_store = setup_error(TlsSetupError::Rustls(rustls::Error::General(
            "no system certificates".to_owned(),
        )));

        assert!(matches!(
            refused_identity,
            DriverError::Tls {
                failure: TlsFailure::ClientIdentityInvalid,
                ..
            }
        ));
        assert!(
            matches!(
                no_trust_store,
                DriverError::Tls {
                    failure: TlsFailure::Other,
                    ..
                }
            ),
            "{no_trust_store:?}"
        );
    }
}
