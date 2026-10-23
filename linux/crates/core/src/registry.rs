use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

use crate::driver::DatabaseDriver;

#[derive(Default)]
pub struct DriverRegistry {
    drivers: HashMap<&'static str, Arc<dyn DatabaseDriver>>,
}

impl DriverRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(&mut self, driver: Arc<dyn DatabaseDriver>) {
        self.drivers.insert(driver.id(), driver);
    }

    pub fn get(&self, id: &str) -> Option<Arc<dyn DatabaseDriver>> {
        self.drivers.get(id).cloned()
    }

    pub fn iter(&self) -> impl Iterator<Item = &Arc<dyn DatabaseDriver>> {
        self.drivers.values()
    }

    pub fn len(&self) -> usize {
        self.drivers.len()
    }

    pub fn is_empty(&self) -> bool {
        self.drivers.is_empty()
    }

    /// How many bytes of a file `file_driver_for` needs to see.
    pub fn file_header_len(&self) -> usize {
        self.file_drivers()
            .filter_map(|driver| driver.capabilities().file_format())
            .map(|format| format.signature.header_len())
            .max()
            .unwrap_or(0)
    }

    /// The engine that opens the file at `path`, whose first bytes are
    /// `header`.
    ///
    /// What the file holds decides first, since a name can be anything.
    /// A file too short to carry any signature goes by its name, so the
    /// engine it names reports what is wrong with it, and an empty file
    /// with a name no engine claims goes to the one engine that reads an
    /// empty file as a new database. Anything else is no engine's.
    pub fn file_driver_for(&self, header: &[u8], path: &Path) -> Option<Arc<dyn DatabaseDriver>> {
        let format_of = |driver: &&Arc<dyn DatabaseDriver>| driver.capabilities().file_format().copied();
        if let Some(signed) = self
            .file_drivers()
            .find(|driver| format_of(driver).is_some_and(|format| format.signature.matches(header)))
        {
            return Some(signed.clone());
        }
        let shortest = self
            .file_drivers()
            .filter_map(|driver| format_of(&driver))
            .map(|format| format.signature.header_len())
            .min()
            .unwrap_or(0);
        if header.len() >= shortest {
            return None;
        }
        if let Some(named) = self
            .file_drivers()
            .find(|driver| format_of(driver).is_some_and(|format| format.names(path)))
        {
            return Some(named.clone());
        }
        if !header.is_empty() {
            return None;
        }
        let mut empty_readers = self
            .file_drivers()
            .filter(|driver| format_of(driver).is_some_and(|format| format.empty_file_is_database));
        match (empty_readers.next(), empty_readers.next()) {
            (Some(only), None) => Some(only.clone()),
            _ => None,
        }
    }

    fn file_drivers(&self) -> impl Iterator<Item = &Arc<dyn DatabaseDriver>> {
        self.drivers
            .values()
            .filter(|driver| driver.capabilities().is_file_based())
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use async_trait::async_trait;
    use tokio_util::sync::CancellationToken;

    use super::*;
    use crate::capabilities::{
        CommitResolutionSupport, DriverCapabilities, EndpointKind, EstimateQuality, ReadOnlyEnforcement,
        ScriptExecution,
    };
    use crate::connect_options::ConnectOptions;
    use crate::connection::Connection;
    use crate::error::DriverError;
    use crate::file_format::{FileFormat, FileSignature};
    use crate::write_ledger::WriteAtomicity;

    const fn capabilities(endpoint: EndpointKind) -> DriverCapabilities {
        DriverCapabilities {
            endpoint,
            auth_modes: &[],
            tls: None,
            read_only: ReadOnlyEnforcement::EngineEnforced,
            dml_writes: WriteAtomicity::Transactional,
            ddl_writes: WriteAtomicity::Transactional,
            script_execution: ScriptExecution::NativeBatch,
            commit_resolution: CommitResolutionSupport::Unavailable,
            row_count_estimate: EstimateQuality::Unavailable,
            object_kinds: &[],
            database_required: false,
        }
    }

    static SQLITE: DriverCapabilities = capabilities(EndpointKind::File(FileFormat {
        signature: FileSignature {
            offset: 0,
            bytes: b"SQLite format 3\0",
        },
        suffixes: &["sqlite3", "sqlite", "db", "db3"],
        mime_types: &["application/vnd.sqlite3"],
        empty_file_is_database: true,
    }));

    static DUCKDB: DriverCapabilities = capabilities(EndpointKind::File(FileFormat {
        signature: FileSignature {
            offset: 8,
            bytes: b"DUCK",
        },
        suffixes: &["duckdb", "ddb"],
        mime_types: &[],
        empty_file_is_database: false,
    }));

    static NETWORK: DriverCapabilities = capabilities(EndpointKind::Network { default_port: 5432 });

    struct Engine(&'static str, &'static DriverCapabilities);

    #[async_trait]
    impl DatabaseDriver for Engine {
        fn id(&self) -> &'static str {
            self.0
        }

        fn display_name(&self) -> &'static str {
            self.0
        }

        fn capabilities(&self) -> &'static DriverCapabilities {
            self.1
        }

        async fn connect(
            &self,
            _options: ConnectOptions,
            _cancel: CancellationToken,
        ) -> Result<Arc<dyn Connection>, DriverError> {
            Err(DriverError::Cancelled)
        }
    }

    fn registry() -> DriverRegistry {
        let mut registry = DriverRegistry::new();
        registry.register(Arc::new(Engine("postgres", &NETWORK)));
        registry.register(Arc::new(Engine("sqlite", &SQLITE)));
        registry.register(Arc::new(Engine("duckdb", &DUCKDB)));
        registry
    }

    fn chosen(registry: &DriverRegistry, header: &[u8], name: &str) -> Option<&'static str> {
        registry
            .file_driver_for(header, &PathBuf::from("/srv").join(name))
            .map(|driver| driver.id())
    }

    fn duckdb_header() -> Vec<u8> {
        let mut header = vec![0x8b, 0x88, 0x5d, 0xf0, 0xba, 0x46, 0x13, 0x98];
        header.extend_from_slice(b"DUCK");
        header.extend_from_slice(&[0; 4]);
        header
    }

    #[test]
    fn what_a_file_holds_decides_over_its_name() {
        let registry = registry();

        assert_eq!(chosen(&registry, &duckdb_header(), "data.db"), Some("duckdb"));
        assert_eq!(chosen(&registry, &duckdb_header(), "data.sqlite3"), Some("duckdb"));
        assert_eq!(
            chosen(&registry, b"SQLite format 3\0rest", "data.duckdb"),
            Some("sqlite")
        );
        assert_eq!(chosen(&registry, b"SQLite format 3\0", "notes"), Some("sqlite"));
    }

    #[test]
    fn a_file_with_no_signature_goes_by_its_name() {
        let registry = registry();

        assert_eq!(chosen(&registry, b"", "new.duckdb"), Some("duckdb"));
        assert_eq!(chosen(&registry, b"", "new.sqlite3"), Some("sqlite"));
        assert_eq!(chosen(&registry, b"garbage", "broken.ddb"), Some("duckdb"));
        assert_eq!(chosen(&registry, b"garbage", "notes.txt"), None);
        assert_eq!(
            chosen(&registry, b"plain text, long enough", "notes.db"),
            None,
            "a header long enough to carry a signature carries none"
        );
    }

    #[test]
    fn an_empty_unclaimed_file_opens_as_the_engine_that_reads_one() {
        let registry = registry();

        assert_eq!(chosen(&registry, b"", "untitled"), Some("sqlite"));
        assert_eq!(
            chosen(&DriverRegistry::new(), b"", "untitled"),
            None,
            "no engine opens files"
        );
    }

    #[test]
    fn the_header_read_covers_every_signature() {
        assert_eq!(registry().file_header_len(), 16);
        assert_eq!(DriverRegistry::new().file_header_len(), 0);
    }
}
