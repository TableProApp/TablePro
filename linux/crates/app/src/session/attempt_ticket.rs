use tokio_util::sync::CancellationToken;

use super::AttemptGeneration;

/// One connect attempt's identity and its cancel switch.
///
/// The attempt carries this from start to finish, so a late result can
/// say which try it came from and be discarded when the user has
/// already started another.
#[derive(Debug, Clone)]
pub struct AttemptTicket {
    generation: AttemptGeneration,
    cancel: CancellationToken,
}

impl AttemptTicket {
    pub(super) fn new(generation: AttemptGeneration, cancel: CancellationToken) -> Self {
        Self { generation, cancel }
    }

    pub fn generation(&self) -> AttemptGeneration {
        self.generation
    }

    pub fn cancel(&self) -> &CancellationToken {
        &self.cancel
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancel.is_cancelled()
    }
}
