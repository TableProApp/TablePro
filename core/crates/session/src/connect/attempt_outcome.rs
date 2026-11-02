use super::{AttemptGeneration, ConnectError, PendingSession};

/// How one connect attempt ended, tagged with the attempt it was, so a
/// result that arrives after the user started another is discarded.
#[derive(Debug)]
pub struct AttemptOutcome {
    pub generation: AttemptGeneration,
    pub result: Result<PendingSession, ConnectError>,
}
