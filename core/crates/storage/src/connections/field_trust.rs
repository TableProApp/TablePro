use std::collections::BTreeMap;

/// What an additional field holds, which decides whether it may arrive from outside or leave this
/// device. The macOS app's `ConnectionFieldTrust` holds the same table until it reads this one;
/// `apple/scripts/ci/check-connection-field-trust.py` fails when the two differ.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FieldTrust {
    Setting,
    /// Where the connection goes: a host, an endpoint or a database file, which a pull applies only with approval.
    Destination,
    /// A file on this device that proves or trusts an identity, or code it loads: a key, a certificate, a CA bundle, an
    /// extension. It means nothing on another device, so a team copy never carries one.
    LocalFile,
    /// Any value outside `plain_values` (compared without case) signs in with something this device holds.
    LocalCredential {
        plain_values: &'static [&'static str],
    },
    /// Travels only in an envelope or an encrypted bundle's credentials, never as a field.
    Secret,
    /// Moves between the person's own devices by sync, never in a file or a link.
    OwnDevices,
    /// Set by the host at connect; a stored or imported value is never used.
    HostInternal,
}

/// The trust of a field id, `None` for one this build does not know.
pub fn field_trust(key: &str) -> Option<FieldTrust> {
    if let Some(option) = mongo_option(key) {
        return Some(
            MONGO_OPTION_TRUST
                .iter()
                .find(|(name, _)| *name == option)
                .map(|(_, trust)| *trust)
                .or_else(|| {
                    MONGO_SECRET_OPTIONS
                        .contains(&option.as_str())
                        .then_some(FieldTrust::Secret)
                })
                .unwrap_or(FieldTrust::Setting),
        );
    }
    TRUST_BY_KEY
        .binary_search_by(|(name, _)| (*name).cmp(key))
        .ok()
        .and_then(|index| TRUST_BY_KEY.get(index))
        .map(|(_, trust)| *trust)
}

/// The fields a file or a link may carry. A field this build does not know stays out, since it may be
/// a secret or a command a newer build added. A selector set to a plain value, such as
/// `mssqlAuthMethod=sql`, is a setting, so only a value that uses a local credential drops.
pub fn portable_fields(fields: &BTreeMap<String, String>, keep_local_credentials: bool) -> BTreeMap<String, String> {
    fields
        .iter()
        .filter(|(key, value)| {
            if is_secret_field(key, value) {
                return false;
            }
            match field_trust(key) {
                Some(FieldTrust::Setting | FieldTrust::Destination | FieldTrust::LocalFile) => true,
                Some(FieldTrust::LocalCredential { plain_values }) => {
                    keep_local_credentials || !uses_local_credential(value, plain_values)
                }
                Some(FieldTrust::Secret | FieldTrust::OwnDevices | FieldTrust::HostInternal) | None => false,
            }
        })
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect()
}

/// The fields sync carries. A field this build does not know still syncs, so one a newer build added
/// survives a round trip through an older one; a secret goes only in an envelope.
pub fn syncable_fields(fields: &BTreeMap<String, String>) -> BTreeMap<String, String> {
    without_secrets(fields)
        .into_iter()
        .filter(|(key, _)| !matches!(field_trust(key), Some(FieldTrust::Secret | FieldTrust::HostInternal)))
        .collect()
}

/// A field list sync brought, with each field sync never carries kept as this device holds it: a credential, a
/// value the host sets, and the session token in the mechanism properties, after the properties sync carries.
pub fn with_device_fields(
    synced: BTreeMap<String, String>,
    stored: &BTreeMap<String, String>,
) -> BTreeMap<String, String> {
    let mut fields = synced;
    for (key, value) in stored {
        let excluded = matches!(field_trust(key), Some(FieldTrust::Secret | FieldTrust::HostInternal));
        if !excluded && !is_secret_field(key, value) {
            continue;
        }
        if !excluded && mongo_option(key).as_deref() == Some(MECHANISM_PROPERTIES) {
            if let (_, Some(token)) = split_session_token(value) {
                let pair = format!("{SESSION_TOKEN_PROPERTY}:{token}");
                let joined = match fields.get(key).filter(|synced| !synced.is_empty()) {
                    Some(synced) => format!("{synced},{pair}"),
                    None => pair,
                };
                fields.insert(key.clone(), joined);
            }
            continue;
        }
        fields.insert(key.clone(), value.clone());
    }
    fields
}

/// Whether a field holds a credential: a MongoDB option named for one, or the session token in its
/// mechanism properties.
pub fn is_secret_field(key: &str, value: &str) -> bool {
    if key.eq_ignore_ascii_case(MONGO_SESSION_TOKEN_FIELD) {
        return true;
    }
    let Some(option) = mongo_option(key) else {
        return false;
    };
    MONGO_SECRET_OPTIONS.contains(&option.as_str())
        || (option == MECHANISM_PROPERTIES && split_session_token(value).1.is_some())
}

/// The fields with every credential taken out. Mechanism properties keep everything but the token.
pub fn without_secrets(fields: &BTreeMap<String, String>) -> BTreeMap<String, String> {
    let mut kept = BTreeMap::new();
    for (key, value) in fields {
        if !is_secret_field(key, value) {
            kept.insert(key.clone(), value.clone());
            continue;
        }
        if mongo_option(key).as_deref() == Some(MECHANISM_PROPERTIES)
            && let (Some(remaining), _) = split_session_token(value)
        {
            kept.insert(key.clone(), remaining);
        }
    }
    kept
}

fn uses_local_credential(value: &str, plain_values: &[&str]) -> bool {
    let trimmed = value.trim();
    !trimmed.is_empty() && !plain_values.iter().any(|plain| plain.eq_ignore_ascii_case(trimmed))
}

const MONGO_OPTION_PREFIX: &str = "mongoParam_";
const MONGO_SESSION_TOKEN_FIELD: &str = "mongoAWSSessionToken";
const MECHANISM_PROPERTIES: &str = "authmechanismproperties";
const SESSION_TOKEN_PROPERTY: &str = "AWS_SESSION_TOKEN";

// MongoDB connection-string options that hold a credential. A pasted URI keeps unknown options as
// plain `mongoParam_` fields, so these are named here to keep them out of files, links and sync.
const MONGO_SECRET_OPTIONS: &[&str] = &[
    "proxypassword",
    "sslclientcertificatekeypassword",
    "tlscertificatekeyfilepassword",
];

// An emulator signs in with nothing, and libmongoc reads no device credential for these mechanisms.
const GOOGLE_AUTH_PLAIN_VALUES: &[&str] = &["serviceaccount", "emulator"];
const MONGO_MECHANISM_PLAIN_VALUES: &[&str] = &["scram-sha-1", "scram-sha-256", "mongodb-x509", "plain"];

// Lowercased option names after `mongoParam_`. Every other option is a setting.
const MONGO_OPTION_TRUST: &[(&str, FieldTrust)] = &[
    (
        "authmechanism",
        FieldTrust::LocalCredential {
            plain_values: MONGO_MECHANISM_PLAIN_VALUES,
        },
    ),
    ("proxyhost", FieldTrust::Destination),
    ("proxyport", FieldTrust::Destination),
    ("sslcertificateauthorityfile", FieldTrust::LocalFile),
    ("sslclientcertificatekeyfile", FieldTrust::LocalFile),
    ("tlscafile", FieldTrust::LocalFile),
    ("tlscertificatekeyfile", FieldTrust::LocalFile),
];

// The lowercased option name of a `mongoParam_` field, `None` for any other field.
fn mongo_option(key: &str) -> Option<String> {
    let prefix = key.get(..MONGO_OPTION_PREFIX.len())?;
    if key.len() <= MONGO_OPTION_PREFIX.len() || !prefix.eq_ignore_ascii_case(MONGO_OPTION_PREFIX) {
        return None;
    }
    key.get(MONGO_OPTION_PREFIX.len()..).map(str::to_lowercase)
}

// `authMechanismProperties` is `KEY:value` pairs joined by commas; libmongoc reads keys without case.
fn split_session_token(properties: &str) -> (Option<String>, Option<String>) {
    let mut kept = Vec::new();
    let mut token = None;
    for pair in properties.split(',').filter(|pair| !pair.is_empty()) {
        let (name, value) = pair.split_once(':').unwrap_or((pair, ""));
        if name.trim().eq_ignore_ascii_case(SESSION_TOKEN_PROPERTY) {
            if !value.is_empty() {
                token = Some(value.to_owned());
            }
        } else {
            kept.push(pair);
        }
    }
    ((!kept.is_empty()).then(|| kept.join(",")), token)
}

const fn local_credential(plain_values: &'static [&'static str]) -> FieldTrust {
    FieldTrust::LocalCredential { plain_values }
}

// Field ids as the drivers read them, case and all, sorted by byte so a lookup can bisect.
const TRUST_BY_KEY: &[(&str, FieldTrust)] = &[
    ("attachedDatabases", FieldTrust::Destination),
    ("awsAccessKeyId", FieldTrust::Setting),
    ("awsAuth", local_credential(&["off", "accesskey"])),
    // DynamoDB Local signs with fixed placeholder keys.
    ("awsAuthMethod", local_credential(&["credentials", "local"])),
    ("awsEndpointUrl", FieldTrust::Destination),
    ("awsProfileName", local_credential(&[])),
    ("awsRDSEndpoint", FieldTrust::Destination),
    ("awsRedshiftEndpoint", FieldTrust::Destination),
    ("awsRegion", FieldTrust::Destination),
    ("awsReplicationGroupId", FieldTrust::Destination),
    ("awsSecretAccessKey", FieldTrust::Secret),
    ("awsSessionToken", FieldTrust::Secret),
    ("beancountRunLedgerPlugins", FieldTrust::OwnDevices),
    ("binaryInlineLimitKB", FieldTrust::Setting),
    ("bqAuthMethod", local_credential(&["serviceaccount"])),
    ("bqLocation", FieldTrust::Setting),
    ("bqMaxBytesBilled", FieldTrust::Setting),
    // Google refresh tokens are cached by client id alone.
    ("bqOAuthClientId", local_credential(&[])),
    ("bqOAuthClientSecret", FieldTrust::Secret),
    ("bqOAuthRefreshToken", FieldTrust::Secret),
    ("bqProjectId", FieldTrust::Destination),
    ("bqServiceAccountJson", FieldTrust::Secret),
    ("btAppProfileId", FieldTrust::Destination),
    ("btAuthMethod", local_credential(&["serviceaccount"])),
    ("btInstanceId", FieldTrust::Destination),
    ("btProjectId", FieldTrust::Destination),
    ("btServiceAccountJson", FieldTrust::Secret),
    ("cassandraConsistency", FieldTrust::Setting),
    ("cassandraSerialConsistency", FieldTrust::Setting),
    ("cfAccountId", FieldTrust::Destination),
    ("commitMode", FieldTrust::Setting),
    ("completionIdentifierCase", FieldTrust::Setting),
    ("connectTimeoutMilliseconds", FieldTrust::HostInternal),
    ("connectTimeoutSeconds", FieldTrust::Setting),
    ("connectionId", FieldTrust::HostInternal),
    ("connectionOptions", FieldTrust::Setting),
    ("connectionPurpose", FieldTrust::HostInternal),
    ("databaseUrl", FieldTrust::Destination),
    ("driverVariant", FieldTrust::HostInternal),
    ("duckdbAlias", FieldTrust::Setting),
    ("duckdbCACertificateFilePath", FieldTrust::LocalFile),
    ("duckdbCertificateFingerprint", FieldTrust::Setting),
    ("duckdbFilePath", FieldTrust::Destination),
    ("duckdbHost", FieldTrust::Destination),
    ("duckdbIdleReleaseMinutes", FieldTrust::Setting),
    ("duckdbMode", FieldTrust::Setting),
    ("duckdbMotherDuckDatabase", FieldTrust::Destination),
    ("duckdbMotherDuckToken", FieldTrust::Secret),
    ("duckdbPort", FieldTrust::Destination),
    ("duckdbReadOnly", FieldTrust::Setting),
    ("duckdbSSLMode", FieldTrust::Setting),
    ("duckdbToken", FieldTrust::Secret),
    ("enableCleartextPlugin", FieldTrust::HostInternal),
    ("entraAccount", local_credential(&[])),
    ("entraClientId", local_credential(&[])),
    ("entraTenantId", local_credential(&[])),
    ("esApiKey", FieldTrust::Secret),
    ("esAuthMethod", FieldTrust::Setting),
    ("esHosts", FieldTrust::Destination),
    ("esSkipTLSVerify", FieldTrust::Setting),
    ("etcdCaCertPath", FieldTrust::LocalFile),
    ("etcdClientCertPath", FieldTrust::LocalFile),
    ("etcdClientKeyPath", FieldTrust::LocalFile),
    ("etcdKeyPrefix", FieldTrust::Setting),
    ("etcdTlsMode", FieldTrust::Setting),
    ("fbAuthMethod", local_credential(GOOGLE_AUTH_PLAIN_VALUES)),
    ("fbDatabaseId", FieldTrust::Destination),
    ("fbDatabaseURL", FieldTrust::Destination),
    ("fbEmulatorHost", FieldTrust::Destination),
    ("fbProjectId", FieldTrust::Destination),
    ("fbServiceAccountJson", FieldTrust::Secret),
    ("gcpServiceAccountKey", FieldTrust::Secret),
    ("gssEncryptionMode", FieldTrust::Setting),
    ("hanaTLSServerName", FieldTrust::Destination),
    ("influxOrg", FieldTrust::Setting),
    ("influxSkipTLSVerify", FieldTrust::Setting),
    ("influxToken", FieldTrust::Secret),
    ("kafkaBootstrapServers", FieldTrust::Destination),
    ("kafkaBrokerRouting", FieldTrust::Setting),
    ("kafkaConnectTimeout", FieldTrust::Setting),
    ("kafkaSaslMechanism", FieldTrust::Setting),
    ("kafkaSecurityProtocol", FieldTrust::Setting),
    ("kerberosPassword", FieldTrust::Secret),
    ("kerberosPrincipal", FieldTrust::Setting),
    ("libsqlFilePath", FieldTrust::Destination),
    ("libsqlMode", FieldTrust::Setting),
    ("localSocketPath", FieldTrust::Destination),
    ("maskingRules", FieldTrust::Setting),
    ("mongoAWSSessionToken", FieldTrust::Secret),
    ("mongoAuthMechanism", local_credential(MONGO_MECHANISM_PLAIN_VALUES)),
    ("mongoAuthSource", FieldTrust::Setting),
    ("mongoHosts", FieldTrust::Destination),
    ("mongoReadPreference", FieldTrust::Setting),
    ("mongoReplicaSet", FieldTrust::Setting),
    ("mongoUseSrv", FieldTrust::Setting),
    ("mongoUuidRepresentation", FieldTrust::Setting),
    ("mongoWriteConcern", FieldTrust::Setting),
    ("mssqlAuthMethod", local_credential(&["sql"])),
    ("mssqlKerberosPassword", FieldTrust::Secret),
    ("mssqlKerberosPrincipal", FieldTrust::Setting),
    ("mssqlLoginTimeout", FieldTrust::Setting),
    ("mssqlSchema", FieldTrust::Setting),
    ("mysqlConnectionEncoding", FieldTrust::Setting),
    ("mysqlIdleReleaseMinutes", FieldTrust::Setting),
    ("oracleConnectionType", FieldTrust::Setting),
    ("oracleDebugProtocol", FieldTrust::Setting),
    ("oracleDebuggerHost", FieldTrust::Destination),
    ("oracleDebuggerPorts", FieldTrust::Setting),
    ("oracleNetworkEncryption", FieldTrust::Setting),
    ("oracleRole", FieldTrust::Setting),
    ("oracleSID", FieldTrust::Setting),
    ("oracleServiceName", FieldTrust::Destination),
    ("postDisconnectScript", FieldTrust::OwnDevices),
    ("preConnectScript", FieldTrust::OwnDevices),
    ("preTunnelHost", FieldTrust::HostInternal),
    ("preTunnelPort", FieldTrust::HostInternal),
    ("promptForPassword", FieldTrust::OwnDevices),
    ("qdApiKey", FieldTrust::Secret),
    ("queryTimeoutSeconds", FieldTrust::Setting),
    ("r2AccountId", FieldTrust::Destination),
    ("r2Bucket", FieldTrust::Destination),
    ("redisClusterHosts", FieldTrust::Destination),
    ("redisDatabase", FieldTrust::Setting),
    ("redisMode", FieldTrust::Setting),
    ("redisSentinelHosts", FieldTrust::Destination),
    ("redisSentinelMasterName", FieldTrust::Setting),
    ("redisSentinelPassword", FieldTrust::Secret),
    ("redisSentinelUsername", FieldTrust::Setting),
    ("redisSeparator", FieldTrust::Setting),
    ("schemaRegistryPassword", FieldTrust::Secret),
    ("schemaRegistryUrl", FieldTrust::Destination),
    ("schemaRegistryUsername", FieldTrust::Setting),
    ("scriptTimeoutSeconds", FieldTrust::Setting),
    ("sdbAccess", FieldTrust::Setting),
    ("sdbAuthLevel", FieldTrust::Setting),
    ("sdbDatabase", FieldTrust::Setting),
    ("sdbSkipTLSVerify", FieldTrust::Setting),
    ("sdbToken", FieldTrust::Secret),
    ("snowflakeAccount", FieldTrust::Destination),
    // externalBrowser reuses the cached SSO token for the account and user.
    (
        "snowflakeAuthMethod",
        local_credential(&["password", "keypair", "oauth"]),
    ),
    ("snowflakeConnectionName", local_credential(&[])),
    ("snowflakeDatabase", FieldTrust::Setting),
    ("snowflakeMFAPasscode", FieldTrust::Secret),
    ("snowflakeOAuthToken", FieldTrust::Secret),
    ("snowflakePassword", FieldTrust::Secret),
    ("snowflakePrivateKeyPassphrase", FieldTrust::Secret),
    ("snowflakePrivateKeyPath", FieldTrust::LocalFile),
    ("snowflakeRole", FieldTrust::Setting),
    ("snowflakeSchema", FieldTrust::Setting),
    ("snowflakeUser", FieldTrust::Setting),
    ("snowflakeWarehouse", FieldTrust::Setting),
    ("spAuthMethod", local_credential(GOOGLE_AUTH_PLAIN_VALUES)),
    ("spDatabaseId", FieldTrust::Destination),
    ("spEndpoint", FieldTrust::Destination),
    ("spInstanceId", FieldTrust::Destination),
    ("spOAuthClientId", local_credential(&[])),
    ("spOAuthClientSecret", FieldTrust::Secret),
    ("spOAuthRefreshToken", FieldTrust::Secret),
    ("spProjectId", FieldTrust::Destination),
    ("spServiceAccountJson", FieldTrust::Secret),
    ("sqliteAgentToken", FieldTrust::HostInternal),
    ("sqliteBackend", FieldTrust::HostInternal),
    ("sqliteExtensions", FieldTrust::LocalFile),
    ("sshForwardUnixSocketPath", FieldTrust::Destination),
    ("sslCaCertPath", FieldTrust::LocalFile),
    ("sslClientKeyPassphrase", FieldTrust::Secret),
    ("teradataLogMech", FieldTrust::Setting),
    ("teradataTMode", FieldTrust::Setting),
    ("trinoAuthMethod", FieldTrust::Setting),
    ("trinoJwtToken", FieldTrust::Secret),
    ("trinoSchema", FieldTrust::Setting),
    ("trinoTimeZone", FieldTrust::Setting),
    ("tunnelSecuresTransport", FieldTrust::HostInternal),
    ("typesenseApiKey", FieldTrust::Secret),
    ("typesenseSkipTLSVerify", FieldTrust::Setting),
    ("usePgpass", local_credential(&["false"])),
    ("wvApiKey", FieldTrust::Secret),
    ("wvAuthMethod", FieldTrust::Setting),
    ("wvSkipTLSVerify", FieldTrust::Setting),
];

#[cfg(test)]
mod tests {
    use super::*;

    fn fields(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
            .collect()
    }

    #[test]
    fn the_table_is_sorted_with_each_key_once() {
        for pair in TRUST_BY_KEY.windows(2) {
            assert!(pair[0].0 < pair[1].0, "{} then {}", pair[0].0, pair[1].0);
        }
    }

    #[test]
    fn every_key_reads_back_its_trust() {
        for (key, trust) in TRUST_BY_KEY {
            assert_eq!(field_trust(key), Some(*trust), "{key}");
        }
        assert_eq!(field_trust("notAField"), None);
    }

    #[test]
    fn a_file_keeps_settings_and_destinations_and_drops_the_rest() {
        let saved = fields(&[
            ("mongoAuthSource", "admin"),
            ("mongoHosts", "a:1,b:2"),
            ("snowflakePassword", "hunter2"),
            ("preConnectScript", "./open-vpn.sh"),
            ("sqliteAgentToken", "t"),
            ("newerBuildField", "x"),
            ("awsProfileName", "prod"),
            ("mssqlAuthMethod", "sql"),
        ]);

        let exported = portable_fields(&saved, true);
        let imported = portable_fields(&saved, false);

        assert_eq!(
            exported,
            fields(&[
                ("awsProfileName", "prod"),
                ("mongoAuthSource", "admin"),
                ("mongoHosts", "a:1,b:2"),
                ("mssqlAuthMethod", "sql"),
            ])
        );
        assert_eq!(
            imported,
            fields(&[
                ("mongoAuthSource", "admin"),
                ("mongoHosts", "a:1,b:2"),
                ("mssqlAuthMethod", "sql")
            ])
        );
    }

    #[test]
    fn sync_keeps_unknown_fields_and_own_device_fields_but_no_secret() {
        let saved = fields(&[
            ("preConnectScript", "./open-vpn.sh"),
            ("newerBuildField", "x"),
            ("influxToken", "t"),
            ("driverVariant", "v"),
        ]);

        assert_eq!(
            syncable_fields(&saved),
            fields(&[("newerBuildField", "x"), ("preConnectScript", "./open-vpn.sh")])
        );
    }

    #[test]
    fn a_mongo_option_is_classed_by_its_name_in_any_case() {
        assert_eq!(field_trust("mongoParam_TLSCAFile"), Some(FieldTrust::LocalFile));
        assert_eq!(field_trust("mongoParam_proxyPassword"), Some(FieldTrust::Secret));
        assert_eq!(field_trust("mongoParam_appName"), Some(FieldTrust::Setting));
        assert_eq!(field_trust("mongoParam_"), None);
    }

    #[test]
    fn the_session_token_leaves_mechanism_properties_and_the_rest_stays() {
        let saved = fields(&[(
            "mongoParam_authMechanismProperties",
            "SERVICE_NAME:mongodb,aws_session_token:abc",
        )]);

        assert!(is_secret_field(
            "mongoParam_authMechanismProperties",
            "SERVICE_NAME:mongodb,aws_session_token:abc"
        ));
        assert_eq!(
            without_secrets(&saved),
            fields(&[("mongoParam_authMechanismProperties", "SERVICE_NAME:mongodb")])
        );
        assert!(!is_secret_field(
            "mongoParam_authMechanismProperties",
            "SERVICE_NAME:mongodb"
        ));
    }

    #[test]
    fn a_pulled_field_list_keeps_what_sync_never_carries_as_this_device_holds_it() {
        let stored = fields(&[
            ("connectTimeoutSeconds", "30"),
            ("connectTimeoutMilliseconds", "9000"),
            ("mongoParam_proxyPassword", "hunter2"),
            (
                "mongoParam_authMechanismProperties",
                "SERVICE_NAME:mongodb,AWS_SESSION_TOKEN:abc",
            ),
        ]);
        let pulled = fields(&[
            ("connectTimeoutSeconds", "60"),
            ("mongoParam_authMechanismProperties", "SERVICE_NAME:other"),
        ]);

        assert_eq!(
            with_device_fields(pulled, &stored),
            fields(&[
                ("connectTimeoutSeconds", "60"),
                ("connectTimeoutMilliseconds", "9000"),
                ("mongoParam_proxyPassword", "hunter2"),
                (
                    "mongoParam_authMechanismProperties",
                    "SERVICE_NAME:other,AWS_SESSION_TOKEN:abc"
                ),
            ])
        );
        assert_eq!(
            with_device_fields(BTreeMap::new(), &stored)["mongoParam_authMechanismProperties"],
            "AWS_SESSION_TOKEN:abc"
        );
    }
}
