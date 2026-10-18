use tablepro_core::DriverError;

/// How closing a connection ended.
#[derive(Debug, Clone, PartialEq)]
pub enum CloseReport {
    Closed,
    /// Something closed it first, so this call had nothing to do.
    AlreadyClosed,
    CloseFailed(DriverError),
    /// The close did not finish within its deadline and was dropped.
    Abandoned,
}
