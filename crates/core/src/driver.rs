use async_trait::async_trait;

use crate::connection::{ConnectOptions, Connection};
use crate::error::DriverError;

/// How complete a driver is for day-to-day use.
///
/// `Stable` drivers support browse, SQL (or the engine's query dialect),
/// and the common write paths. `Experimental` drivers connect and browse
/// but may lack parameter binding, interactive transactions, or full
/// write coverage. See `docs/adding-drivers.md`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum DriverMaturity {
    #[default]
    Stable,
    Experimental,
}

impl DriverMaturity {
    pub fn label(self) -> &'static str {
        match self {
            Self::Stable => "Stable",
            Self::Experimental => "Experimental",
        }
    }
}

#[async_trait]
pub trait DatabaseDriver: Send + Sync {
    fn id(&self) -> &'static str;
    fn display_name(&self) -> &'static str;
    fn default_port(&self) -> u16;

    fn default_database(&self) -> &'static str {
        ""
    }

    fn default_username(&self) -> &'static str {
        ""
    }

    fn maturity(&self) -> DriverMaturity {
        DriverMaturity::Stable
    }

    fn is_file_based(&self) -> bool {
        false
    }

    /// Whether a multi-statement DDL batch can roll back as a unit, so
    /// the structure editor's Save runs through
    /// `Connection::execute_in_transaction` instead of statement by
    /// statement. MySQL commits implicitly on every DDL statement: the
    /// transaction would end after the first one and a later failure
    /// would leave the earlier statements applied, which is worse than
    /// not opening one at all.
    fn ddl_is_transactional(&self) -> bool {
        false
    }

    /// Whether `ExecResult::rows_affected` carries a real count for
    /// UPDATE and DELETE. The inline-edit Save path reads a zero count
    /// as an optimistic-concurrency conflict, so a driver that cannot
    /// produce one must say so or every successful save reports a lost
    /// update. ClickHouse applies both as asynchronous mutations and
    /// returns no row count for either.
    fn reports_rows_affected(&self) -> bool {
        true
    }

    /// Whether `Connection::list_databases` answers with the databases the
    /// connected account can open. Engines with a single database per
    /// connection, such as the file-based ones, declare false.
    fn supports_database_listing(&self) -> bool {
        false
    }

    /// Whether this driver can enumerate the indexes on a table.
    /// `Connection::fetch_indexes` answers with an empty list when it
    /// cannot, and the structure tab has no way to tell that apart from
    /// a table that genuinely has no index. A driver must declare true
    /// only when it implements the fetch against real catalog data.
    fn supports_index_metadata(&self) -> bool {
        false
    }

    /// Whether this driver can enumerate the foreign keys on a table,
    /// for the same reason as `supports_index_metadata`. Engines with no
    /// foreign-key concept declare false even when the driver overrides
    /// the fetch to return an empty list.
    fn supports_foreign_key_metadata(&self) -> bool {
        false
    }

    /// Whether this driver's engine stores a comment on a column. The
    /// answer comes from the DDL builder's placement table rather than
    /// a per-driver override, so a driver cannot advertise a capability
    /// the builder would refuse to emit.
    fn supports_column_comments(&self) -> bool {
        !matches!(
            crate::sql_ddl::column_comment_placement(self.id()),
            crate::sql_ddl::CommentPlacement::Unsupported
        )
    }

    fn supports_view_metadata(&self) -> bool {
        false
    }

    fn catalog_object_kinds(&self) -> &'static [crate::CatalogObjectKind] {
        &[]
    }

    fn supports_integrated_auth(&self) -> bool {
        false
    }

    fn supports_local_socket(&self) -> bool {
        false
    }

    /// Whether this driver can authenticate TLS connections with a client
    /// certificate and private key. Transport refuses configured identities
    /// for drivers that do not explicitly opt in.
    fn supports_client_tls_auth(&self) -> bool {
        false
    }

    /// File name a forwarded Unix socket must use for this driver to
    /// dial it while verifying TLS against the original service
    /// hostname. `None` means the driver has no socket transport and an
    /// SSH tunnel must forward TCP instead.
    fn forwarded_socket_name(&self, _service_port: u16) -> Option<String> {
        None
    }

    async fn connect(&self, opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConnectionFormDefaults {
    pub port: u16,
    pub database: &'static str,
    pub username: &'static str,
}

pub fn connection_form_defaults(driver: &dyn DatabaseDriver) -> ConnectionFormDefaults {
    ConnectionFormDefaults {
        port: driver.default_port(),
        database: driver.default_database(),
        username: driver.default_username(),
    }
}

pub fn initial_connection_form_defaults(drivers: &[&dyn DatabaseDriver]) -> Option<ConnectionFormDefaults> {
    drivers
        .iter()
        .min_by(|left, right| left.display_name().cmp(right.display_name()))
        .map(|driver| connection_form_defaults(*driver))
}

#[cfg(test)]
mod tests {
    use super::*;

    struct BareDriver;

    #[async_trait]
    impl DatabaseDriver for BareDriver {
        fn id(&self) -> &'static str {
            "bare"
        }

        fn display_name(&self) -> &'static str {
            "Bare"
        }

        fn default_port(&self) -> u16 {
            0
        }

        async fn connect(&self, _opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
            Err(DriverError::Unsupported("bare".into()))
        }
    }

    #[test]
    fn a_driver_that_declares_nothing_claims_no_structure_metadata() {
        let driver = BareDriver;
        assert!(!driver.supports_database_listing());
        assert!(!driver.supports_index_metadata());
        assert!(!driver.supports_foreign_key_metadata());
        assert!(!driver.supports_view_metadata());
        assert!(!driver.supports_column_comments());
        assert_eq!(driver.default_database(), "");
        assert_eq!(driver.default_username(), "");
    }

    struct NamedDriver {
        name: &'static str,
        port: u16,
        database: &'static str,
        username: &'static str,
    }

    #[async_trait]
    impl DatabaseDriver for NamedDriver {
        fn id(&self) -> &'static str {
            self.name
        }

        fn display_name(&self) -> &'static str {
            self.name
        }

        fn default_port(&self) -> u16 {
            self.port
        }

        fn default_database(&self) -> &'static str {
            self.database
        }

        fn default_username(&self) -> &'static str {
            self.username
        }

        async fn connect(&self, _opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
            Err(DriverError::Unsupported(self.name.into()))
        }
    }

    #[test]
    fn the_first_sorted_driver_supplies_the_connection_form() {
        let clickhouse = NamedDriver {
            name: "ClickHouse",
            port: 8123,
            database: "default",
            username: "default",
        };
        let postgres = NamedDriver {
            name: "PostgreSQL",
            port: 5432,
            database: "postgres",
            username: "postgres",
        };
        let drivers: [&dyn DatabaseDriver; 2] = [&postgres, &clickhouse];
        let mut sorted = drivers;
        sorted.sort_by(|left, right| left.display_name().cmp(right.display_name()));

        let initial = initial_connection_form_defaults(&drivers).unwrap();
        assert_eq!(initial, connection_form_defaults(sorted[0]));
        assert_eq!(initial.port, 8123);
        assert_eq!(initial.database, "default");
        assert_eq!(initial.username, "default");
        assert_ne!(
            (initial.port, initial.database, initial.username),
            (5432, "postgres", "postgres")
        );

        let switched = connection_form_defaults(&postgres);
        assert_eq!(switched.port, 5432);
        assert_eq!(switched.database, "postgres");
        assert_eq!(switched.username, "postgres");
        assert_ne!(switched, initial);
    }
}
