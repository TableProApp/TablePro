use tablepro_core::DriverError;

/// How a scripted read ends once it has sent its events.
#[derive(Debug, Clone, Default, PartialEq)]
pub enum StreamEnd {
    /// The summary, or `Cancelled` when the sink stopped the read.
    #[default]
    Summary,
    /// The summary even when the sink stopped the read early, which the
    /// contract allows and SQL Server's driver does.
    SummaryWhenStopped,
    /// `error` once every event is sent, as a statement that writes
    /// after it reads fails once its rows are in.
    Failed(DriverError),
}
