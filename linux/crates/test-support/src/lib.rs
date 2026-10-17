//! Test doubles for the driver contract, shared by every crate's tests.
//!
//! The fakes keep the contract's own rules (deadlines, cancels, a lost
//! link, one run at a time) so code under test sees what a real driver
//! would do, and `conformance` holds the suites every driver runs.

use std::sync::{Mutex, MutexGuard, PoisonError};

mod call_counters;
mod close_behaviour;
#[cfg(test)]
mod close_race;
pub mod conformance;
mod connection_script;
mod csv_import;
mod executable;
mod fake_connection;
mod fake_dialect;
mod fake_driver;
mod fake_editor_session;
mod fake_prompter;
mod fake_reply;
mod fake_run;
mod fake_secret_vault;
mod fault;
pub mod history_cases;
mod replies;
mod stream_end;

pub use call_counters::CallCounters;
pub use close_behaviour::CloseBehaviour;
pub use connection_script::ConnectionScript;
pub use csv_import::{CsvImportFailure, import_csv};
pub use executable::write_executable;
pub use fake_connection::FakeConnection;
pub use fake_dialect::FakeDialect;
pub use fake_driver::FakeDriver;
pub use fake_editor_session::FakeEditorSession;
pub use fake_prompter::FakePrompter;
pub use fake_reply::FakeReply;
pub use fake_run::{FakeRun, RunWait};
pub use fake_secret_vault::{Call, FakeSecretVault};
pub use fault::FaultTransport;
pub use replies::Replies;
pub use stream_end::StreamEnd;

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}
