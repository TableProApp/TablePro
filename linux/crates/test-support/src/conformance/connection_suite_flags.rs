use crate::conformance::SuiteEndpoint;

/// The suite flags the driver's capability table can contradict.
///
/// The other flags have no capability behind them: whether a pool has a
/// size or a timeout bounds DDL is engine knowledge the adapter states.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConnectionSuiteFlags {
    pub endpoint: SuiteEndpoint,
    pub editor_transactions: bool,
}
