//! Exports that write their file off the GTK thread: rows are encoded
//! on the runtime and handed over in chunks, GIO writes them, and an
//! export that stops or fails leaves the file as close to how it was as
//! GIO allows. The workspace's ledger tracks the running ones for the
//! header bar, for logout and for the close prompts.

mod encoding_sink;
mod export_failure_text;
mod export_format;
mod export_job;
mod export_job_item;
mod export_ledger;
mod export_message;
mod export_operations_button;
mod export_outcome;
mod export_producer;
mod export_sink_parts;
mod export_source;
mod replace_file_writer;

pub(crate) use encoding_sink::EncodingSink;
pub(crate) use export_failure_text::{ExportReporter, failure_text};
pub(crate) use export_format::{DocumentFormat, ExportFormat, InsertTarget, RowFormat};
pub(crate) use export_job::{ExpectedRows, ExportJob, ExportJobId};
pub(crate) use export_job_item::ExportJobItem;
pub(crate) use export_ledger::{ExportLedger, ExportLedgerInit};
pub(crate) use export_message::{ExportMessage, ExportStreamFailure};
pub(crate) use export_operations_button::ExportOperationsButton;
pub(crate) use export_outcome::{ExportFailure, ExportOutcome};
pub(crate) use export_sink_parts::ExportSinkParts;
pub(crate) use export_source::ExportSource;
pub(crate) use replace_file_writer::{AbortOutcome, FinishError, ReplaceFileWriter};
