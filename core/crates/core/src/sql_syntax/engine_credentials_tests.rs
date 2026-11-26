use super::*;
use crate::sql_syntax::WithholdReason;

const WITHHELD: HistoryRecording = HistoryRecording::Withhold(WithholdReason::CredentialStatement);

// Each driver's statements that carry a secret, with a plain one of the same engine beside them.
const CASES: &[(SqlGrammar, &[&str], &str)] = &[
    (
        SqlGrammar::PostgreSql,
        &[
            "CREATE ROLE r LOGIN PASSWORD 'p'",
            "ALTER USER u WITH PASSWORD $$x$$",
            "CREATE USER MAPPING FOR u SERVER s OPTIONS (password 'b')",
            "CREATE SUBSCRIPTION s CONNECTION 'password=x' PUBLICATION p",
            "SELECT dblink_connect('password=x')",
            "ALTER SYSTEM SET primary_conninfo = 'password=x'",
            "DO $$ BEGIN CREATE ROLE app LOGIN PASSWORD 'p'; END $$",
            "SELECT pgp_sym_encrypt('data', 'passphrase')",
        ],
        "SELECT * FROM users",
    ),
    (
        SqlGrammar::MySql,
        &[
            "CREATE USER 'u'@'%' IDENTIFIED BY 'p'",
            "SET PASSWORD FOR 'u'@'h' = 'x'",
            "CHANGE REPLICATION SOURCE TO SOURCE_PASSWORD='x'",
            "CHANGE MASTER TO MASTER_PASSWORD='x'",
            "GRANT ALL ON *.* TO u IDENTIFIED BY 'p'",
            "START REPLICA USER='u' PASSWORD='p'",
        ],
        "SELECT * FROM users",
    ),
    (
        SqlGrammar::Sqlite,
        &[
            "PRAGMA key = 'x'",
            "PRAGMA main.rekey = 'x'",
            "ATTACH DATABASE 'other.db' AS other KEY 'x'",
        ],
        "ATTACH DATABASE 'other.db' AS other",
    ),
    (
        SqlGrammar::MsSql,
        &[
            "CREATE LOGIN l WITH PASSWORD = N'x'",
            "EXEC sp_password 'o','n'",
            "sp_addlogin 'l','p'",
            "SELECT * FROM OPENROWSET('SQLNCLI','Server=x;PWD=y','q')",
            "BACKUP DATABASE d TO DISK='f' WITH PASSWORD='x'",
            "SELECT ENCRYPTBYPASSPHRASE('passphrase', 'data')",
        ],
        "BACKUP DATABASE d TO DISK='f'",
    ),
    (
        SqlGrammar::ClickHouse,
        &[
            "CREATE USER u IDENTIFIED WITH sha256_password BY 'p'",
            "SELECT * FROM mysql('h','d','t','u','p')",
            "CREATE TABLE t ENGINE = PostgreSQL('h','d','t','u','p')",
            "SELECT * FROM remoteSecure('h', d.t, 'u', 'p')",
            "CREATE NAMED COLLECTION c AS password = 'p'",
        ],
        "SELECT * FROM system.tables",
    ),
    (
        SqlGrammar::DuckDb,
        &[
            "CREATE SECRET s (TYPE s3, KEY_ID 'k', SECRET 'v')",
            "ATTACH 'host=db user=u password=p' AS pg (TYPE postgres)",
            "SET s3_secret_access_key = 'v'",
            "SELECT * FROM postgres_scan('host=db password=p', 'public', 't')",
            "PRAGMA add_parquet_key('k', '0123456789112345')",
        ],
        "SET threads = 4",
    ),
    (
        SqlGrammar::Cql,
        &[
            "CREATE ROLE r WITH PASSWORD = 'secret' AND LOGIN = true",
            "ALTER ROLE r WITH PASSWORD = 'secret'",
            "CREATE ROLE r WITH HASHED PASSWORD = '$2a$10$x'",
            "CREATE USER u WITH PASSWORD 'secret'",
        ],
        "CREATE ROLE r WITH LOGIN = true",
    ),
    (SqlGrammar::Redis, &["AUTH s3cret"], "GET k"),
    (
        SqlGrammar::Mongo,
        &["db.createUser({user: 'a', pwd: 'b', roles: []})"],
        "db.users.find()",
    ),
];

#[test]
fn every_engine_withholds_its_driver_s_secret_carrying_statements_and_keeps_a_plain_one() {
    for (grammar, secrets, plain) in CASES {
        for sql in *secrets {
            assert_eq!(grammar.history_recording(sql), WITHHELD, "{grammar:?}: {sql}");
        }
        assert_eq!(
            grammar.history_recording(plain),
            HistoryRecording::Record,
            "{grammar:?}: {plain}"
        );
    }
}

#[test]
fn an_engine_is_named_by_its_driver_id_or_by_the_apple_apps_database_type() {
    for (names, grammar) in [
        (["postgres", "PostgreSQL"].as_slice(), SqlGrammar::PostgreSql),
        (&["mysql", "MySQL", "MariaDB"], SqlGrammar::MySql),
        (&["sqlite", "SQLite"], SqlGrammar::Sqlite),
        (&["mssql", "SQL Server"], SqlGrammar::MsSql),
        (&["clickhouse", "ClickHouse"], SqlGrammar::ClickHouse),
        (&["duckdb", "DuckDB"], SqlGrammar::DuckDb),
        (&["cassandra", "Cassandra", "ScyllaDB"], SqlGrammar::Cql),
        (&["redis", "Redis"], SqlGrammar::Redis),
        (&["mongodb", "MongoDB"], SqlGrammar::Mongo),
    ] {
        for name in names {
            assert_eq!(SqlGrammar::of_engine(name), Some(grammar), "{name}");
        }
    }
    for unknown in ["Oracle", "Redshift", "Snowflake", "", "postgresql"] {
        assert_eq!(SqlGrammar::of_engine(unknown), None, "{unknown}");
    }
}
