use tablepro_core::Value;
use tablepro_core::grid::clipboard::ClipboardPayload;
use tablepro_core::grid::copy::{CopyError, CopyRow, render};
use tablepro_session::runtime::{TaskResult, Tasks};

use super::CopyRequest;
use crate::services::grid::RowSnapshot;

impl CopyRow for RowSnapshot {
    fn width(&self) -> usize {
        self.len()
    }

    fn value(&self, column: usize) -> &Value {
        RowSnapshot::value(self, column)
    }
}

/// Render `request` on the blocking pool: a copy of every row can take long
/// enough to stall the window.
pub(crate) fn render_copy(tasks: &Tasks, request: CopyRequest) -> TaskResult<Result<ClipboardPayload, CopyError>> {
    tasks.spawn_blocking_task(move || render(request))
}
