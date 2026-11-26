// Each engine's statements whose text can hold a password or a connection secret, in the one place every build links:
// a driver keeps a run out of the history by them, and sync keeps an entry another app recorded on the device by the
// engine the entry names.

use super::{CredentialRules, HistoryRecording, SqlGrammar, classify_for_history};

impl SqlGrammar {
    // The engine a history entry names: the core's driver id, or the database type the Apple apps record.
    pub fn of_engine(engine: &str) -> Option<Self> {
        match engine {
            "postgres" | "PostgreSQL" => Some(Self::PostgreSql),
            "mysql" | "MySQL" | "MariaDB" => Some(Self::MySql),
            "sqlite" | "SQLite" => Some(Self::Sqlite),
            "mssql" | "SQL Server" => Some(Self::MsSql),
            "clickhouse" | "ClickHouse" => Some(Self::ClickHouse),
            "duckdb" | "DuckDB" => Some(Self::DuckDb),
            "cassandra" | "Cassandra" | "ScyllaDB" => Some(Self::Cql),
            "redis" | "Redis" => Some(Self::Redis),
            "mongodb" | "MongoDB" => Some(Self::Mongo),
            _ => None,
        }
    }

    // Whether a run of this engine may be kept in the history, read every way its server may read it.
    pub fn history_recording(self, sql: &str) -> HistoryRecording {
        classify_for_history(self, self.credential_rules(), sql)
    }

    // Redis and MongoDB carry a secret in a command's arguments, which their own rules read.
    const fn credential_rules(self) -> &'static CredentialRules {
        match self {
            Self::PostgreSql => &POSTGRESQL,
            Self::MySql => &MYSQL,
            Self::Sqlite => &SQLITE,
            Self::MsSql => &MSSQL,
            Self::ClickHouse => &CLICKHOUSE,
            Self::DuckDb => &DUCKDB,
            Self::Cql => &CQL,
            Self::Redis | Self::Mongo => &ARGUMENTS,
        }
    }
}

const ARGUMENTS: CredentialRules = CredentialRules {
    statement_prefixes: &[],
    conditional_prefixes: &[],
    carriers: &[],
    secret_parameters: &[],
};

// Statements whose text can hold a password or a connection string.
// `CREATE USER` also covers `CREATE USER MAPPING`, whose options carry
// the remote login, and pgcrypto's `crypt` and passphrase functions take
// the password itself.
const POSTGRESQL: CredentialRules = CredentialRules {
    statement_prefixes: &[
        &["CREATE", "ROLE"],
        &["ALTER", "ROLE"],
        &["CREATE", "USER"],
        &["ALTER", "USER"],
        &["CREATE", "GROUP"],
        &["ALTER", "GROUP"],
        &["CREATE", "SERVER"],
        &["ALTER", "SERVER"],
        &["CREATE", "SUBSCRIPTION"],
        &["ALTER", "SUBSCRIPTION"],
    ],
    conditional_prefixes: &[(&["ALTER", "SYSTEM"], &["PRIMARY_CONNINFO"])],
    carriers: &[
        "dblink",
        "dblink_connect",
        "dblink_connect_u",
        "dblink_exec",
        "crypt",
        "pgp_sym_encrypt",
        "pgp_sym_encrypt_bytea",
        "pgp_sym_decrypt",
        "pgp_sym_decrypt_bytea",
        "pgp_pub_decrypt",
        "pgp_pub_decrypt_bytea",
        "encrypt",
        "decrypt",
        "encrypt_iv",
        "decrypt_iv",
        "hmac",
    ],
    secret_parameters: &[],
};

// Statements whose text can hold a password or a connection string. A
// FEDERATED or CONNECT table keeps its remote login in `CONNECTION`, and
// `PASSWORD()` takes the password it hashes.
const MYSQL: CredentialRules = CredentialRules {
    statement_prefixes: &[
        &["CREATE", "USER"],
        &["ALTER", "USER"],
        &["CREATE", "SERVER"],
        &["ALTER", "SERVER"],
        &["SET", "PASSWORD"],
        &["CHANGE", "MASTER"],
        &["CHANGE", "REPLICATION", "SOURCE"],
    ],
    conditional_prefixes: &[
        (&["GRANT"], &["IDENTIFIED"]),
        (&["START", "SLAVE"], &["PASSWORD"]),
        (&["START", "REPLICA"], &["PASSWORD"]),
        (&["START", "GROUP_REPLICATION"], &["PASSWORD"]),
        (&["CREATE"], &["CONNECTION"]),
        (&["ALTER"], &["CONNECTION"]),
        (&["CLONE"], &["IDENTIFIED"]),
    ],
    carriers: &[
        "PASSWORD",
        "OLD_PASSWORD",
        "AES_ENCRYPT",
        "AES_DECRYPT",
        "DES_ENCRYPT",
        "DES_DECRYPT",
        "ENCODE",
        "DECODE",
        "VALIDATE_PASSWORD_STRENGTH",
    ],
    secret_parameters: &[],
};

// Statements whose text can hold an encryption key, on builds with
// SQLCipher or the SQLite Encryption Extension.
const SQLITE: CredentialRules = CredentialRules {
    statement_prefixes: &[],
    conditional_prefixes: &[
        (
            &["PRAGMA"],
            &["KEY", "REKEY", "HEXKEY", "HEXREKEY", "TEXTKEY", "TEXTREKEY"],
        ),
        (&["ATTACH"], &["KEY"]),
    ],
    carriers: &[],
    secret_parameters: &[],
};

// Statements whose text can hold a password or a connection string.
// The procedures run without EXEC as the first statement of a batch,
// and the crypto functions take the passphrase or key password itself.
const MSSQL: CredentialRules = CredentialRules {
    statement_prefixes: &[
        &["CREATE", "LOGIN"],
        &["ALTER", "LOGIN"],
        &["CREATE", "USER"],
        &["ALTER", "USER"],
        &["CREATE", "APPLICATION", "ROLE"],
        &["ALTER", "APPLICATION", "ROLE"],
        &["CREATE", "CREDENTIAL"],
        &["ALTER", "CREDENTIAL"],
        &["CREATE", "DATABASE", "SCOPED", "CREDENTIAL"],
        &["ALTER", "DATABASE", "SCOPED", "CREDENTIAL"],
        &["CREATE", "MASTER", "KEY"],
        &["ALTER", "MASTER", "KEY"],
        &["ALTER", "SERVICE", "MASTER", "KEY"],
        &["CREATE", "CERTIFICATE"],
        &["ALTER", "CERTIFICATE"],
        &["CREATE", "SYMMETRIC", "KEY"],
        &["ALTER", "SYMMETRIC", "KEY"],
        &["CREATE", "ASYMMETRIC", "KEY"],
        &["ALTER", "ASYMMETRIC", "KEY"],
        &["OPEN", "MASTER", "KEY"],
        &["OPEN", "SYMMETRIC", "KEY"],
    ],
    conditional_prefixes: &[
        (&["BACKUP"], &["PASSWORD", "MEDIAPASSWORD", "ENCRYPTION"]),
        (&["RESTORE"], &["PASSWORD", "MEDIAPASSWORD", "ENCRYPTION"]),
        (&["ADD", "SIGNATURE"], &["PASSWORD"]),
        (&["ADD", "COUNTER", "SIGNATURE"], &["PASSWORD"]),
    ],
    carriers: &[
        "sp_addlogin",
        "sp_password",
        "sp_addlinkedsrvlogin",
        "sp_addapprole",
        "sp_setapprole",
        "sp_approlepassword",
        "sp_control_dbmasterkey_password",
        "sp_change_users_login",
        "sp_addlinkedserver",
        "OPENROWSET",
        "OPENDATASOURCE",
        "ENCRYPTBYPASSPHRASE",
        "DECRYPTBYPASSPHRASE",
        "DECRYPTBYASYMKEY",
        "DECRYPTBYCERT",
        "DECRYPTBYKEYAUTOASYMKEY",
        "DECRYPTBYKEYAUTOCERT",
        "SIGNBYASYMKEY",
        "SIGNBYCERT",
        "CERTPRIVATEKEY",
        "PWDCOMPARE",
        "PWDENCRYPT",
        "sp_xp_cmdshell_proxy_account",
        "sysmail_add_account_sp",
        "sysmail_update_account_sp",
        // Replication and log shipping: the distributor_admin, Publisher,
        // Subscriber, agent job, snapshot FTP and monitor passwords, as
        // arguments or as a property value.
        "sp_adddistributor",
        "sp_changedistributor_password",
        "sp_adddistributiondb",
        "sp_adddistpublisher",
        "sp_changedistpublisher",
        "sp_changepublication",
        "sp_changemergepublication",
        "sp_addsubscriber",
        "sp_changesubscriber",
        "sp_addlogreader_agent",
        "sp_changelogreader_agent",
        "sp_addqreader_agent",
        "sp_changeqreader_agent",
        "sp_addpublication_snapshot",
        "sp_changepublication_snapshot",
        "sp_addpushsubscription_agent",
        "sp_addpullsubscription_agent",
        "sp_addmergepushsubscription_agent",
        "sp_addmergepullsubscription_agent",
        "sp_changesubscription",
        "sp_changemergesubscription",
        "sp_changemergepullsubscription",
        "sp_change_subscription_properties",
        "sp_changereplicationserverpasswords",
        "sp_adddynamicsnapshot_job",
        "sp_changedynamicsnapshot_job",
        "sp_attachsubscription",
        "sp_link_publication",
        "sp_add_log_shipping_primary_database",
        "sp_change_log_shipping_primary_database",
        "sp_add_log_shipping_secondary_primary",
        "sp_change_log_shipping_secondary_primary",
        "sp_add_log_shipping_secondary_database",
        "sp_change_log_shipping_secondary_database",
    ],
    secret_parameters: &["PASSWORD", "PASSWD", "PWD"],
};

// Statements whose text can hold a password or an access key. The
// carriers are table functions and engines (`ENGINE = MySQL(...)`)
// whose arguments include the remote login; the Kafka, RabbitMQ and
// NATS engines and a password-protected backup take theirs as settings.
const CLICKHOUSE: CredentialRules = CredentialRules {
    statement_prefixes: &[
        &["CREATE", "USER"],
        &["ALTER", "USER"],
        &["CREATE", "NAMED", "COLLECTION"],
        &["ALTER", "NAMED", "COLLECTION"],
    ],
    conditional_prefixes: &[
        (&["CREATE", "DICTIONARY"], &["PASSWORD"]),
        (&["BACKUP"], &["PASSWORD"]),
        (&["RESTORE"], &["PASSWORD"]),
        (
            &["CREATE"],
            &["KAFKA_SASL_PASSWORD", "RABBITMQ_PASSWORD", "NATS_PASSWORD"],
        ),
        (
            &["ALTER"],
            &["KAFKA_SASL_PASSWORD", "RABBITMQ_PASSWORD", "NATS_PASSWORD"],
        ),
    ],
    carriers: &[
        "mysql",
        "postgresql",
        "mongodb",
        "redis",
        "s3",
        "s3Cluster",
        "S3Queue",
        "azureBlobStorage",
        "azureBlobStorageCluster",
        "AzureQueue",
        "gcs",
        "remote",
        "remoteSecure",
        "MaterializedPostgreSQL",
        "MaterializedMySQL",
        "ExternalDistributed",
        "deltaLake",
        "deltaLakeCluster",
        "iceberg",
        "icebergS3",
        "icebergS3Cluster",
        "icebergAzure",
        "icebergAzureCluster",
        "hudi",
        "hudiCluster",
        "url",
        "urlCluster",
        "ytsaurus",
        "odbc",
        "jdbc",
        "encrypt",
        "decrypt",
        "tryDecrypt",
        "aes_encrypt_mysql",
        "aes_decrypt_mysql",
    ],
    secret_parameters: &[],
};

// The settings that hold a credential, and PRAGMA's Parquet key.
const DUCKDB_SECRET_SETTINGS: &[&str] = &[
    "s3_access_key_id",
    "s3_secret_access_key",
    "s3_session_token",
    "azure_storage_connection_string",
    "azure_account_key",
    "azure_proxy_password",
    "motherduck_token",
    "http_proxy",
    "http_proxy_password",
    "hf_token",
    "add_parquet_key",
];

// Statements and calls whose text can hold a secret: a stored secret,
// a setting that is one, and the connection strings of the scanners
// that reach other databases. ATTACH names any database, an encrypted
// file's key or a server's login among them.
const DUCKDB: CredentialRules = CredentialRules {
    statement_prefixes: &[
        &["CREATE", "SECRET"],
        &["CREATE", "PERSISTENT", "SECRET"],
        &["CREATE", "TEMPORARY", "SECRET"],
        &["CREATE", "TEMP", "SECRET"],
        &["ATTACH"],
    ],
    // A setting is set by SET or by PRAGMA, and PRAGMA also adds a
    // Parquet key.
    conditional_prefixes: &[
        (&["SET"], DUCKDB_SECRET_SETTINGS),
        (&["PRAGMA"], DUCKDB_SECRET_SETTINGS),
    ],
    carriers: &[
        "postgres_attach",
        "postgres_scan",
        "postgres_scan_pushdown",
        "postgres_query",
        "postgres_execute",
        "mysql_query",
        "mysql_execute",
        "add_parquet_key",
    ],
    secret_parameters: &[],
};

// Statements whose text can hold a password. `CREATE ROLE` and
// `ALTER ROLE` carry one only with PASSWORD or HASHED PASSWORD; the
// older `CREATE USER` and `ALTER USER` exist to set one.
const CQL: CredentialRules = CredentialRules {
    statement_prefixes: &[&["CREATE", "USER"], &["ALTER", "USER"]],
    conditional_prefixes: &[
        (&["CREATE", "ROLE"], &["PASSWORD", "HASHED"]),
        (&["ALTER", "ROLE"], &["PASSWORD", "HASHED"]),
    ],
    carriers: &[],
    secret_parameters: &[],
};

#[cfg(test)]
#[path = "engine_credentials_tests.rs"]
mod tests;
