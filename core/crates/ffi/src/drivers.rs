use std::sync::Arc;

use tablepro_core::{DataModel, DatabaseDriver, DriverRegistry, EndpointKind};

/// Every engine the library links in. Drivers are compiled in until the
/// driver ABI lands (core/docs/decisions/0004-driver-plugin-abi.md).
pub(crate) fn registry() -> DriverRegistry {
    let mut registry = DriverRegistry::new();
    registry.register(Arc::new(tablepro_driver_cassandra::CassandraDriver));
    registry.register(Arc::new(tablepro_driver_clickhouse::ClickhouseDriver));
    registry.register(Arc::new(tablepro_driver_duckdb::DuckDbDriver));
    registry.register(Arc::new(tablepro_driver_mongodb::MongoDriver));
    registry.register(Arc::new(tablepro_driver_mssql::MssqlDriver));
    registry.register(Arc::new(tablepro_driver_mysql::MysqlDriver));
    registry.register(Arc::new(tablepro_driver_postgres::PgDriver));
    registry.register(Arc::new(tablepro_driver_redis::RedisDriver));
    registry.register(Arc::new(tablepro_driver_sqlite::SqliteDriver));
    registry
}

/// An engine, as the connect dialog lists it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DriverInfo {
    pub id: String,
    pub display_name: String,
    pub data_model: DataModelTag,
    pub endpoint: EndpointInfo,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DataModelTag {
    Relational,
    KeyValue,
    Document,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum EndpointInfo {
    Network {
        default_port: u16,
    },
    /// Opens a file, and claims these name suffixes, the one a new file
    /// gets first.
    File {
        suffixes: Vec<String>,
    },
}

impl DriverInfo {
    pub(crate) fn of(driver: &dyn DatabaseDriver) -> Self {
        let capabilities = driver.capabilities();
        Self {
            id: driver.id().to_owned(),
            display_name: driver.display_name().to_owned(),
            data_model: match capabilities.data_model {
                DataModel::Relational => DataModelTag::Relational,
                DataModel::KeyValue => DataModelTag::KeyValue,
                DataModel::Document => DataModelTag::Document,
            },
            endpoint: match &capabilities.endpoint {
                EndpointKind::Network { default_port } => EndpointInfo::Network {
                    default_port: *default_port,
                },
                EndpointKind::File(format) => EndpointInfo::File {
                    suffixes: format.suffixes.iter().map(|suffix| (*suffix).to_owned()).collect(),
                },
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_nine_engines_of_the_first_windows_release_are_linked_in() {
        let registry = registry();
        let mut ids: Vec<&str> = registry.iter().map(|driver| driver.id()).collect();
        ids.sort_unstable();

        assert_eq!(
            ids,
            [
                "cassandra",
                "clickhouse",
                "duckdb",
                "mongodb",
                "mssql",
                "mysql",
                "postgres",
                "redis",
                "sqlite"
            ]
        );
    }

    #[test]
    fn a_file_engine_lists_its_suffixes() {
        let sqlite = DriverInfo::of(&tablepro_driver_sqlite::SqliteDriver);

        assert_eq!(sqlite.display_name, "SQLite");
        assert!(matches!(&sqlite.endpoint, EndpointInfo::File { suffixes } if suffixes.iter().any(|s| s == "sqlite")));
    }
}
