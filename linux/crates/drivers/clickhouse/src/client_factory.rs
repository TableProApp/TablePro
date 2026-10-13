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

/// The settings every request carries.
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
    // wrote rather than what was there before.
    ("mutations_sync", "1"),
    // A read whose connection the app dropped stops on the server even
    // when no KILL could be sent.
    ("cancel_http_readonly_queries_on_client_close", "1"),
];

/// The settings that hold a read-only connection to reads.
pub(crate) const READ_ONLY_SETTINGS: [(&str, &str); 2] = [("readonly", "2"), ("allow_ddl", "0")];

/// The client every request of one target goes through: hyper's pool
/// over the target's transport, the target's credentials and database,
/// and the settings every request carries.
///
/// The clickhouse crate's own TLS stays unused: TLS is negotiated here,
/// over the transport's stream, against the trust the target names.
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
    let mut client = client
        .with_url(service_url(scheme, target))
        .with_product_info(APPLICATION_NAME, environment.client_version.clone());
    for (name, value) in COMMON_SETTINGS {
        client = client.with_setting(name, value);
    }
    client = with_credentials(client, target)?;
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
        TlsSetupError::Rustls(error) => DriverError::Tls {
            failure: TlsFailure::ClientIdentityInvalid,
            detail: error.to_string(),
        },
        other => DriverError::Tls {
            failure: TlsFailure::Other,
            detail: other.to_string(),
        },
    }
}
