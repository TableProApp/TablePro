use tablepro_core::ResultSink;
use tablepro_session::runtime::Tasks;
use tokio::sync::mpsc;

use super::{DocumentSink, EncodingSink, ExportFormat, ExportMessage};

/// What a sink for one export is made from. The channel is bounded, so
/// a disk slower than the encoder holds the encoder back rather than
/// queueing the whole result in memory.
#[derive(Clone)]
pub(crate) struct ExportSinkParts {
    pub messages: mpsc::Sender<ExportMessage>,
    pub format: ExportFormat,
    /// Where a document is rendered once its last row is in.
    pub tasks: Tasks,
}

impl ExportSinkParts {
    /// A fresh sink, for one run of the read.
    pub(crate) fn sink(&self) -> Box<dyn ResultSink> {
        match &self.format {
            ExportFormat::Rows(format) => Box::new(EncodingSink::new(self.messages.clone(), format.clone())),
            ExportFormat::Document(format) => Box::new(DocumentSink::new(
                self.messages.clone(),
                format.clone(),
                self.tasks.clone(),
            )),
        }
    }
}
