use std::time::Duration;

use tokio_util::sync::CancellationToken;

use crate::byte_limit::ByteLimit;
use crate::row_limit::RowLimit;

/// What one run of editor SQL is allowed to do.
#[derive(Debug, Clone)]
pub struct RunOptions {
    pub row_limit: RowLimit,
    pub byte_limit: ByteLimit,
    pub deadline: Option<Duration>,
    pub cancel: CancellationToken,
}

impl RunOptions {
    pub fn new(cancel: CancellationToken) -> Self {
        Self {
            row_limit: RowLimit::EDITOR_DEFAULT,
            byte_limit: ByteLimit::EDITOR_DEFAULT,
            deadline: None,
            cancel,
        }
    }

    pub fn with_row_limit(self, row_limit: RowLimit) -> Self {
        Self { row_limit, ..self }
    }

    pub fn with_byte_limit(self, byte_limit: ByteLimit) -> Self {
        Self { byte_limit, ..self }
    }

    pub fn with_deadline(self, deadline: Option<Duration>) -> Self {
        Self { deadline, ..self }
    }
}
