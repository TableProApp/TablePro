use std::collections::BTreeMap;

// Where a file engine's connection keeps the file's path.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum LocalFilePathField {
    Database,
    AdditionalField(&'static str),
}

// A connection form field that takes the built-in password's place.
struct PasswordField {
    id: &'static str,
    shown: Shown,
}

enum Shown {
    // A toggle hides the password while it is on.
    Toggle,
    // A picker hides it once moved off its default.
    Picker {
        default: &'static str,
    },
    // Any other field hides it while it is on screen.
    Always,
    When {
        field: &'static str,
        values: &'static [&'static str],
        field_default: &'static str,
    },
}

struct Engine {
    name: &'static str,
    default_port: u16,
    file_path: Option<LocalFilePathField>,
    hides_password: bool,
    password_fields: &'static [PasswordField],
}

const AWS_PICKER: PasswordField = PasswordField {
    id: "awsAuth",
    shown: Shown::Picker { default: "off" },
};
const PGPASS: PasswordField = PasswordField {
    id: "usePgpass",
    shown: Shown::Toggle,
};
const LIBSQL_MODE: PasswordField = PasswordField {
    id: "libsqlMode",
    shown: Shown::Picker { default: "remote" },
};
const TRINO_TOKEN: PasswordField = PasswordField {
    id: "trinoJwtToken",
    shown: Shown::When {
        field: "trinoAuthMethod",
        values: &["jwt"],
        field_default: "password",
    },
};

const fn server(name: &'static str, default_port: u16) -> Engine {
    Engine {
        name,
        default_port,
        file_path: None,
        hides_password: false,
        password_fields: &[],
    }
}

const fn signs_in(name: &'static str, default_port: u16, password_fields: &'static [PasswordField]) -> Engine {
    Engine {
        password_fields,
        ..server(name, default_port)
    }
}

const fn own_sign_in(name: &'static str, default_port: u16) -> Engine {
    Engine {
        hides_password: true,
        ..server(name, default_port)
    }
}

const fn file(name: &'static str, field: LocalFilePathField) -> Engine {
    Engine {
        file_path: Some(field),
        ..server(name, 0)
    }
}

// The macOS app's built-in plugin metadata: every engine it knows, with the facts an import needs.
const ENGINES: &[Engine] = &[
    signs_in("MySQL", 3306, &[AWS_PICKER]),
    signs_in("MariaDB", 3306, &[AWS_PICKER]),
    signs_in("PostgreSQL", 5432, &[PGPASS, AWS_PICKER]),
    signs_in("Redshift", 5439, &[PGPASS, AWS_PICKER]),
    signs_in("CockroachDB", 26257, &[PGPASS]),
    own_sign_in("PGlite", 5432),
    file("SQLite", LocalFilePathField::Database),
    server("TiDB", 4000),
    server("Databend", 3307),
    server("OceanBase", 2881),
    signs_in("KingbaseES", 54321, &[PGPASS]),
    server("StarRocks", 9030),
    server("MongoDB", 27017),
    signs_in("Redis", 6379, &[AWS_PICKER]),
    signs_in(
        "SQL Server",
        1433,
        &[
            PasswordField {
                id: "mssqlKerberosPassword",
                shown: Shown::When {
                    field: "mssqlAuthMethod",
                    values: &["windows"],
                    field_default: "sql",
                },
            },
            PasswordField {
                id: "entraClientId",
                shown: Shown::When {
                    field: "mssqlAuthMethod",
                    values: &["entra"],
                    field_default: "sql",
                },
            },
        ],
    ),
    server("Teradata", 1025),
    server("Oracle", 1521),
    server("Dameng", 5236),
    server("ClickHouse", 8123),
    file("Beancount", LocalFilePathField::Database),
    signs_in("Cassandra", 9042, &[AWS_PICKER]),
    server("ScyllaDB", 9042),
    server("etcd", 2379),
    server("Cloudflare D1", 0),
    Engine {
        password_fields: &[LIBSQL_MODE],
        ..file("libSQL", LocalFilePathField::AdditionalField("libsqlFilePath"))
    },
    Engine {
        password_fields: &[LIBSQL_MODE],
        ..file("Turso", LocalFilePathField::AdditionalField("libsqlFilePath"))
    },
    Engine {
        default_port: 9494,
        hides_password: true,
        ..file("DuckDB", LocalFilePathField::AdditionalField("duckdbFilePath"))
    },
    own_sign_in("DynamoDB", 0),
    own_sign_in("BigQuery", 0),
    own_sign_in("Spanner", 0),
    own_sign_in("Snowflake", 443),
    signs_in(
        "Elasticsearch",
        9200,
        &[PasswordField {
            id: "esAuthMethod",
            shown: Shown::Picker { default: "basic" },
        }],
    ),
    signs_in(
        "SurrealDB",
        8000,
        &[PasswordField {
            id: "sdbToken",
            shown: Shown::When {
                field: "sdbAuthLevel",
                values: &["token"],
                field_default: "root",
            },
        }],
    ),
    server("Kafka", 9092),
    signs_in(
        "Typesense",
        8108,
        &[PasswordField {
            id: "typesenseApiKey",
            shown: Shown::Always,
        }],
    ),
    server("Cloudflare R2 SQL", 0),
    own_sign_in("Weaviate", 8080),
    server("SAP HANA", 443),
    own_sign_in("Firestore", 0),
    own_sign_in("Firebase Realtime Database", 0),
    own_sign_in("Bigtable", 0),
    server("Neo4j", 7687),
    signs_in("Trino", 8080, &[TRINO_TOKEN]),
    signs_in("Presto", 8080, &[TRINO_TOKEN]),
    server("Memcached", 11211),
    own_sign_in("Qdrant", 6333),
    own_sign_in("InfluxDB", 8086),
];

fn known(engine: &str) -> Option<&'static Engine> {
    ENGINES.iter().find(|known| known.name == engine)
}

// The exact name, else the one name that matches in any case, else the identifier as it came.
pub(crate) fn resolve(identifier: &str) -> String {
    if let Some(engine) = known(identifier) {
        return engine.name.to_owned();
    }
    let folded = identifier.to_lowercase();
    let mut matches = ENGINES.iter().filter(|engine| engine.name.to_lowercase() == folded);
    match (matches.next(), matches.next()) {
        (Some(engine), None) => engine.name.to_owned(),
        _ => identifier.to_owned(),
    }
}

pub(crate) fn default_port(engine: &str) -> u16 {
    known(engine).map_or(0, |known| known.default_port)
}

pub(crate) fn local_file_path_field(engine: &str) -> Option<LocalFilePathField> {
    known(engine).and_then(|known| known.file_path)
}

// Whether the engine's connection form shows no password of its own for these fields.
pub(crate) fn hides_built_in_password(engine: &str, fields: &BTreeMap<String, String>) -> bool {
    let Some(engine) = known(engine) else {
        return false;
    };
    engine.hides_password
        || engine.password_fields.iter().any(|field| match field.shown {
            Shown::Toggle => fields.get(field.id).is_some_and(|value| value == "true"),
            Shown::Picker { default } => fields.get(field.id).is_some_and(|value| value != default),
            Shown::Always => true,
            Shown::When {
                field: gate,
                values,
                field_default,
            } => {
                let current = fields.get(gate).map_or(field_default, String::as_str);
                values.contains(&current)
            }
        })
}

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
    fn every_engine_name_is_listed_once() {
        let mut names: Vec<&str> = ENGINES.iter().map(|engine| engine.name).collect();
        assert_eq!(names.len(), 47);
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), 47);
    }

    #[test]
    fn resolve_prefers_the_exact_name_then_a_single_match_in_any_case() {
        assert_eq!(resolve("SQL Server"), "SQL Server");
        assert_eq!(resolve("sql server"), "SQL Server");
        assert_eq!(resolve("LIBSQL"), "libSQL");
        assert_eq!(resolve("ETCD"), "etcd");
        assert_eq!(resolve("firebase realtime database"), "Firebase Realtime Database");
        assert_eq!(resolve("Vertica"), "Vertica");
        assert_eq!(resolve("Greenplum"), "Greenplum");
        assert_eq!(resolve(""), "");
    }

    #[test]
    fn default_ports_follow_the_macos_metadata() {
        let expected = [
            ("MySQL", 3306),
            ("PostgreSQL", 5432),
            ("Redshift", 5439),
            ("CockroachDB", 26257),
            ("KingbaseES", 54321),
            ("TiDB", 4000),
            ("Databend", 3307),
            ("OceanBase", 2881),
            ("StarRocks", 9030),
            ("MongoDB", 27017),
            ("Redis", 6379),
            ("SQL Server", 1433),
            ("Teradata", 1025),
            ("Oracle", 1521),
            ("Dameng", 5236),
            ("ClickHouse", 8123),
            ("Cassandra", 9042),
            ("etcd", 2379),
            ("DuckDB", 9494),
            ("Snowflake", 443),
            ("Elasticsearch", 9200),
            ("SurrealDB", 8000),
            ("Kafka", 9092),
            ("Typesense", 8108),
            ("Weaviate", 8080),
            ("SAP HANA", 443),
            ("Neo4j", 7687),
            ("Trino", 8080),
            ("Memcached", 11211),
            ("Qdrant", 6333),
            ("InfluxDB", 8086),
            ("SQLite", 0),
            ("DynamoDB", 0),
            ("Vertica", 0),
        ];
        for (engine, port) in expected {
            assert_eq!(default_port(engine), port, "{engine}");
        }
    }

    #[test]
    fn file_engines_name_the_field_that_holds_the_path() {
        assert_eq!(local_file_path_field("SQLite"), Some(LocalFilePathField::Database));
        assert_eq!(local_file_path_field("Beancount"), Some(LocalFilePathField::Database));
        assert_eq!(
            local_file_path_field("DuckDB"),
            Some(LocalFilePathField::AdditionalField("duckdbFilePath"))
        );
        assert_eq!(
            local_file_path_field("libSQL"),
            Some(LocalFilePathField::AdditionalField("libsqlFilePath"))
        );
        assert_eq!(
            local_file_path_field("Turso"),
            Some(LocalFilePathField::AdditionalField("libsqlFilePath"))
        );
        assert_eq!(local_file_path_field("MySQL"), None);
        assert_eq!(local_file_path_field("sqlite"), None);
    }

    #[test]
    fn engines_that_sign_in_their_own_way_always_hide_the_password() {
        for engine in [
            "PGlite",
            "DuckDB",
            "DynamoDB",
            "BigQuery",
            "Spanner",
            "Snowflake",
            "Weaviate",
            "Firestore",
            "Firebase Realtime Database",
            "Bigtable",
            "Qdrant",
            "InfluxDB",
            "Typesense",
        ] {
            assert!(hides_built_in_password(engine, &BTreeMap::new()), "{engine}");
        }
        for engine in [
            "MySQL",
            "PostgreSQL",
            "SQL Server",
            "Oracle",
            "libSQL",
            "Trino",
            "Vertica",
        ] {
            assert!(!hides_built_in_password(engine, &BTreeMap::new()), "{engine}");
        }
    }

    #[test]
    fn sign_in_fields_hide_the_password_only_when_set() {
        assert!(hides_built_in_password("MySQL", &fields(&[("awsAuth", "accessKey")])));
        assert!(!hides_built_in_password("MySQL", &fields(&[("awsAuth", "off")])));
        assert!(hides_built_in_password("PostgreSQL", &fields(&[("usePgpass", "true")])));
        assert!(!hides_built_in_password(
            "PostgreSQL",
            &fields(&[("usePgpass", "false")])
        ));
        assert!(hides_built_in_password("KingbaseES", &fields(&[("usePgpass", "true")])));
        assert!(!hides_built_in_password("TiDB", &fields(&[("usePgpass", "true")])));
        assert!(hides_built_in_password(
            "SQL Server",
            &fields(&[("mssqlAuthMethod", "windows")])
        ));
        assert!(hides_built_in_password(
            "SQL Server",
            &fields(&[("mssqlAuthMethod", "entra")])
        ));
        assert!(!hides_built_in_password(
            "SQL Server",
            &fields(&[("mssqlAuthMethod", "sql")])
        ));
        assert!(hides_built_in_password("libSQL", &fields(&[("libsqlMode", "local")])));
        assert!(!hides_built_in_password(
            "libSQL",
            &fields(&[("libsqlFilePath", "/data/local.db")])
        ));
        assert!(hides_built_in_password(
            "Elasticsearch",
            &fields(&[("esAuthMethod", "apiKey")])
        ));
        assert!(hides_built_in_password(
            "SurrealDB",
            &fields(&[("sdbAuthLevel", "token")])
        ));
        assert!(!hides_built_in_password(
            "SurrealDB",
            &fields(&[("sdbAuthLevel", "record")])
        ));
        assert!(hides_built_in_password(
            "Presto",
            &fields(&[("trinoAuthMethod", "jwt")])
        ));
        assert!(!hides_built_in_password(
            "Trino",
            &fields(&[("trinoAuthMethod", "password")])
        ));
    }
}
