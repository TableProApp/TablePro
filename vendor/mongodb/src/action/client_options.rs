use macro_magic::export_tokens;

use crate::{
    client::options::{ClientOptions, ConnectionString, ResolverConfig},
    error::{Error, Result},
};

use super::options_doc;

impl ClientOptions {
    /// Parses a MongoDB connection string (as either a `&str` or a [`ConnectionString`]) into a
    /// [`ClientOptions`] struct. If the string is malformed or one of the options has an
    /// invalid value, an error will be returned.
    ///
    /// In the case that "mongodb+srv" is used, SRV and TXT record lookups will be done as
    /// part of this method.
    ///
    /// The format of a MongoDB connection string is described [here](https://www.mongodb.com/docs/manual/reference/connection-string/#connection-string-formats).
    ///
    /// Note that [default_database](ClientOptions::default_database) will be set from
    /// `/defaultauthdb` in connection string.
    ///
    /// The following options are supported in the options query string:
    ///
    ///   * `appName`: maps to the `app_name` field
    ///   * `authMechanism`: maps to the `mechanism` field of the `credential` field
    ///   * `authSource`: maps to the `source` field of the `credential` field
    ///   * `authMechanismProperties`: maps to the `mechanism_properties` field of the `credential`
    ///     field
    ///   * `compressors`: maps to the `compressors` field
    ///   * `connectTimeoutMS`: maps to the `connect_timeout` field
    ///   * `direct`: maps to the `direct` field
    ///   * `heartbeatFrequencyMS`: maps to the `heartbeat_frequency` field
    ///   * `journal`: maps to the `journal` field of the `write_concern` field
    ///   * `localThresholdMS`: maps to the `local_threshold` field
    ///   * `maxIdleTimeMS`: maps to the `max_idle_time` field
    ///   * `maxStalenessSeconds`: maps to the `max_staleness` field of the `selection_criteria`
    ///     field
    ///   * `maxPoolSize`: maps to the `max_pool_size` field
    ///   * `minPoolSize`: maps to the `min_pool_size` field
    ///   * `readConcernLevel`: maps to the `read_concern` field
    ///   * `readPreferenceField`: maps to the ReadPreference enum variant of the
    ///     `selection_criteria` field
    ///   * `readPreferenceTags`: maps to the `tags` field of the `selection_criteria` field. Note
    ///     that this option can appear more than once; each instance will be mapped to a separate
    ///     tag set
    ///   * `replicaSet`: maps to the `repl_set_name` field
    ///   * `retryWrites`: not yet implemented
    ///   * `retryReads`: maps to the `retry_reads` field
    ///   * `serverSelectionTimeoutMS`: maps to the `server_selection_timeout` field
    ///   * `socketTimeoutMS`: unsupported, does not map to any field
    ///   * `ssl`: an alias of the `tls` option
    ///   * `tls`: maps to the TLS variant of the `tls` field`.
    ///   * `tlsInsecure`: relaxes the TLS constraints on connections being made; if set, the
    ///     `allow_invalid_certificates` and `allow_invalid_hostnames` fields of the `tls` field are
    ///     set to its value
    ///   * `tlsAllowInvalidCertificates`: maps to the `allow_invalid_certificates` field of the
    ///     `tls` field
    ///   * `tlsCAFile`: maps to the `ca_file_path` field of the `tls` field
    ///   * `tlsCertificateKeyFile`: maps to the `cert_key_file_path` field of the `tls` field
    ///   * `w`: maps to the `w` field of the `write_concern` field
    ///   * `waitQueueTimeoutMS`: unsupported, does not map to any field
    ///   * `wTimeoutMS`: maps to the `w_timeout` field of the `write_concern` field
    ///   * `zlibCompressionLevel`: maps to the `level` field of the `Compressor::Zlib` variant
    ///     (which requires the `zlib-compression` feature flag) of the
    ///     [`Compressor`](crate::compression::compressors::Compressor) enum
    ///
    /// `await` will return `Result<ClientOptions>`.
    #[options_doc(parse_conn_str_setters)]
    pub fn parse<C, E>(conn_str: C) -> ParseConnectionString
    where
        C: TryInto<ConnectionString, Error = E>,
        E: Into<Error>,
    {
        ParseConnectionString {
            conn_str: conn_str.try_into().map_err(Into::into),
            resolver_config: None,
        }
    }
}

fn _assert_accept_str() {
    let _ = ClientOptions::parse("foo");
}

#[allow(unreachable_code, clippy::diverging_sub_expression)]
fn _assert_accept_conn_str() {
    let _c: ConnectionString = todo!();
    let _ = ClientOptions::parse(_c);
}

/// Parses a MongoDB connection string into a [`ClientOptions`] struct.  Construct with
/// [`ClientOptions::parse`].
#[must_use]
pub struct ParseConnectionString {
    pub(crate) conn_str: Result<ConnectionString>,
    pub(crate) resolver_config: Option<ResolverConfig>,
}

#[export_tokens(parse_conn_str_setters)]
impl ParseConnectionString {
    /// In the case that "mongodb+srv" is used, SRV and TXT record lookups will be done using the
    /// provided `ResolverConfig` as part of this method. In the case that "GSSAPI" auth is used,
    /// hostname canonicalization will be done using the provided `ResolverConfig`.
    #[cfg(feature = "dns-resolver")]
    pub fn resolver_config(mut self, value: ResolverConfig) -> Self {
        self.resolver_config = Some(value);
        self
    }
}

// Action impl in src/client/options/parse.rs.
