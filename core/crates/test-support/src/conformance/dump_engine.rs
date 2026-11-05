use async_trait::async_trait;
use tablepro_core::ConnectOptions;
use tablepro_core::dump::DumpScope;

use crate::conformance::{ConformanceEngine, ConformanceFailure};

/// An engine the dump round trip writes a database of and loads it back
/// into an empty one.
#[async_trait]
pub trait DumpEngine: ConformanceEngine {
    /// Writable options that connect to a database of this name on the
    /// engine's server, dropped and made again empty, or to a new file
    /// where the engine opens one.
    async fn empty_database(&self, name: &str) -> Result<ConnectOptions, ConformanceFailure>;

    /// The statements that fill an empty database with the sample, each
    /// sent on its own to an editor session, in order. They make what a
    /// restore has to get right on this engine: tables joined by a foreign
    /// key, a table whose key points at itself, a counter past the highest
    /// key, a sequence where the engine has them, a view over a view, a
    /// routine, a trigger that changes the row it fires on, and a value of
    /// every kind the value corpus covers that has a literal.
    fn dump_fixture(&self) -> Vec<String>;

    /// What the dump covers.
    fn dump_scope(&self) -> DumpScope {
        DumpScope::Database
    }

    /// A file the engine's own dump tool wrote, and reads that each give
    /// one value once it loaded, with that value as text. `None` where the
    /// engine has no such tool.
    fn native_dump(&self) -> Option<NativeDump> {
        None
    }
}

/// A dump the engine's own tool wrote, as the import must read it.
pub struct NativeDump {
    pub file: &'static str,
    pub checks: Vec<(String, String)>,
}
