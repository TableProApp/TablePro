//! One editor run: the sink that keeps its result sets, the events the
//! app drains, and the handle that stops it.

mod query_run;
mod run_event;
mod run_sink;
mod run_state;

pub use query_run::{QueryRun, RunListener};
pub use run_event::{RunEvent, RunOutcome, TransactionStateTag, TruncationTag};
pub(crate) use run_sink::RunSink;
pub(crate) use run_state::RunState;
