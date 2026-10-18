use super::OpenSessionsRecord;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OpenSessionsLoad {
    Restored(OpenSessionsRecord),
    /// Nothing was recorded, or the record could not be used and was
    /// moved aside.
    Empty,
}
