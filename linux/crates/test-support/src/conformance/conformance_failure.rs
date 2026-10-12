use std::fmt;

use tablepro_core::DriverError;

/// Why a conformance case did not pass.
///
/// Cases return this rather than panicking, so a failure says which
/// rule of the contract the driver broke and what it did instead.
#[derive(Debug)]
pub enum ConformanceFailure {
    /// The engine could not be started or prepared; nothing about the
    /// driver was tested.
    Setup(String),
    /// A call the case relies on failed where the contract says it must
    /// succeed.
    Driver(DriverError),
    /// The driver answered, and the answer breaks the contract.
    Expectation { case: &'static str, detail: String },
}

impl ConformanceFailure {
    pub fn setup(detail: impl fmt::Display) -> Self {
        Self::Setup(detail.to_string())
    }
}

impl fmt::Display for ConformanceFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Setup(detail) => write!(f, "setup failed: {detail}"),
            Self::Driver(error) => write!(f, "driver call failed: {error}"),
            Self::Expectation { case, detail } => write!(f, "{case}: {detail}"),
        }
    }
}

impl std::error::Error for ConformanceFailure {}

impl From<DriverError> for ConformanceFailure {
    fn from(error: DriverError) -> Self {
        Self::Driver(error)
    }
}
