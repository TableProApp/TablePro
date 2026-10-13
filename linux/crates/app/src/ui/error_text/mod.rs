//! The sentence the user sees for each error, chosen by what kind of
//! problem it is rather than by which driver raised it.
//!
//! `DriverError::category` decides the branch, so an error a driver
//! adds later still lands in a branch that says what to do next; the
//! variant only adds detail.

mod ddl;
mod driver;
mod operation;
mod script;
mod secret;
mod ssh;
#[cfg(test)]
mod tests;
mod tls;
mod tls_remedy;

pub use ddl::{build_error_text, refusal_text, save_blocker_text};
pub use driver::{config_message, driver_message};
pub use operation::{connect_error_message, operation_error_message, task_failure_message};
pub use script::script_diagnostic_message;
pub use tls_remedy::{TlsRemedy, connect_remedy};
