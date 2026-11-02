use std::time::Duration;

use super::OperationKind;

/// How long each kind of operation may run. `None` means no client-side
/// bound: a schema change can legitimately run for a long time.
pub trait DeadlinePolicy: Send + Sync {
    fn deadline(&self, kind: OperationKind) -> Option<Duration>;
}
