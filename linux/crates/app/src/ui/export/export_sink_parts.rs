use tokio::sync::mpsc;

use super::{EncodingSink, ExportMessage, RowFormat};

/// What a sink for one export is made from. The channel is bounded, so
/// a disk slower than the encoder holds the encoder back rather than
/// queueing the whole result in memory.
#[derive(Clone)]
pub(crate) struct ExportSinkParts {
    pub messages: mpsc::Sender<ExportMessage>,
    pub format: RowFormat,
}

impl ExportSinkParts {
    pub(crate) fn sink(&self) -> EncodingSink {
        EncodingSink::new(self.clone())
    }
}
