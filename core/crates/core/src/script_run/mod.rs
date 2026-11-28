//! Drive a whole script of batches on one editor session, with an error
//! policy and a run-wide row and byte budget, producing a structured log
//! that carries error codes, not worded sentences. An app reads the log
//! and words it.
//!
//! This sits next to [`crate::sql_syntax::script`], which splits the text
//! into the [`RunBatch`]es this loop sends. Rows go to a
//! [`ScriptResultStore`] the caller owns; the log points at each set by
//! the index the store handed back.

mod batch_loop;
mod budget;
mod collector;
mod entry;
mod store;
#[cfg(test)]
mod tests;

pub use batch_loop::{BatchReporter, ReportFlow, run_batches};
pub use budget::{RowRoom, RunBatch, ScriptRun, room_after};
pub use collector::{BatchCollector, BatchOutcome};
pub use entry::{AfterRun, ResultSetSummary, ScriptBatchReport, ScriptEntry, Verdict, continues};
pub use store::ScriptResultStore;

// The run keeps at most this many rows across all its results. A script
// of many SELECTs would otherwise hold every one until the next run.
pub const RUN_ROW_LIMIT: u64 = 100_000;

// BatchErrorPolicy lives with the planner that reads it off the script.
pub use crate::sql_syntax::script::BatchErrorPolicy;
