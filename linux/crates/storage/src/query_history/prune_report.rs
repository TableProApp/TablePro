/// What a prune removed, so the caller can log or report it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct PruneReport {
    /// Unpinned rows older than the retention window.
    pub expired: u64,
    /// Unpinned rows beyond the entry cap, oldest first.
    pub over_cap: u64,
}

impl PruneReport {
    pub fn total(self) -> u64 {
        self.expired + self.over_cap
    }

    pub fn removed_anything(self) -> bool {
        self.total() > 0
    }
}
