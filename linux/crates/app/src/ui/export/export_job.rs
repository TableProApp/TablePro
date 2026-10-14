use gtk4::gio;

use super::{ExportFormat, ExportSource};

/// One export, as the dialog hands it to the ledger.
#[derive(Debug)]
pub(crate) struct ExportJob {
    pub destination: gio::File,
    pub format: ExportFormat,
    pub source: ExportSource,
    pub expected_rows: Option<ExpectedRows>,
}

/// Names a running export in its ledger.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub(crate) struct ExportJobId(u64);

impl ExportJobId {
    pub(crate) fn new(id: u64) -> Self {
        Self(id)
    }
}

/// How many rows an export will write, as far as anyone knows before it
/// does.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExpectedRows {
    Exact(u64),
    /// The server's estimate, which the export may pass.
    About(u64),
}

impl ExpectedRows {
    pub(crate) fn total(self) -> u64 {
        match self {
            Self::Exact(total) | Self::About(total) => total,
        }
    }
}
