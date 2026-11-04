// What another app's connections and queries become in the core library: a row per collected
// connection with its duplicate and notes, a selection over the rows, a plan, and its write.

mod analyze;
mod apply;
mod mapping;
mod match_key;
mod notes;
mod plan;
mod selection;

use std::path::Path;

use tablepro_core::DriverRegistry;
use tablepro_storage::{ConnectionList, SavedConnection};
use uuid::Uuid;

use crate::{ForeignApp, ForeignAppDirs, PasswordOutcome};

pub use apply::{AppliedConnection, AppliedImport, ImportedQuery, QueryImportOutcome, apply_blocking, save_queries};
pub use mapping::ImportedSecret;
pub use notes::{RowNote, TlsFileReason};
pub use plan::{ImportPlan, PlannedConnection, PlannedQuery, QueryAvailability, QueryStatus, QueryTarget, plan};
pub use selection::ImportSelection;

pub struct ReviewInputs<'a> {
    pub drivers: &'a DriverRegistry,
    // The list the rows are checked against, and the one the write expects to find unchanged.
    pub library: ConnectionList,
    pub dirs: &'a ForeignAppDirs,
    pub file_exists: &'a dyn Fn(&Path) -> bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Resolution {
    Add,
    AddCopy,
    Replace(Uuid),
    // Writes nothing, so the row's saved queries land on the saved connection.
    KeepExisting(Uuid),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExistingConnection {
    pub id: Uuid,
    pub name: String,
}

#[derive(Debug, Clone)]
pub struct ConnectionRow {
    pub reference: String,
    pub name: String,
    // As the other app named it.
    pub engine: String,
    // None when no driver here opens the engine; such a row cannot be selected.
    pub connection: Option<SavedConnection>,
    pub group_path: Vec<String>,
    pub duplicate: Option<ExistingConnection>,
    // The first is the default once the row is selected.
    pub resolutions: Vec<Resolution>,
    pub selected_by_default: bool,
    pub notes: Vec<RowNote>,
    pub saved_query_count: usize,
    // Whether the write hands back secrets for the keyring.
    pub carries_credentials: bool,
    secrets: Vec<ImportedSecret>,
}

#[derive(Debug, Clone)]
pub struct QueryRow {
    pub reference: String,
    pub name: String,
    // The reference of the connection row it runs on.
    pub connection: Option<String>,
    pub connection_name: Option<String>,
    pub byte_count: u64,
    pub too_large: bool,
    pub suggested: bool,
    // None when the other app's file was too large to read.
    text: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ImportReview {
    app: ForeignApp,
    passwords: PasswordOutcome,
    connections: Vec<ConnectionRow>,
    queries: Vec<QueryRow>,
    library: ConnectionList,
}

impl ImportReview {
    pub fn app(&self) -> ForeignApp {
        self.app
    }

    pub fn passwords(&self) -> PasswordOutcome {
        self.passwords
    }

    pub fn connections(&self) -> &[ConnectionRow] {
        &self.connections
    }

    pub fn saved_queries(&self) -> &[QueryRow] {
        &self.queries
    }

    pub fn library(&self) -> &ConnectionList {
        &self.library
    }

    pub fn connection_row(&self, reference: &str) -> Option<&ConnectionRow> {
        self.connections.iter().find(|row| row.reference == reference)
    }

    pub fn query_row(&self, reference: &str) -> Option<&QueryRow> {
        self.queries.iter().find(|row| row.reference == reference)
    }
}
