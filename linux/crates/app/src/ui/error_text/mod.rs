//! The sentence the user sees for each error, chosen by what kind of
//! problem it is rather than by which driver raised it.
//!
//! `DriverError::category` decides the branch, so an error a driver
//! adds later still lands in a branch that says what to do next; the
//! variant only adds detail.

mod driver;
mod operation;
mod secret;
mod ssh;
#[cfg(test)]
mod tests;
mod tls;

pub use driver::driver_message;
pub use operation::{connect_error_message, operation_error_message, task_failure_message};
pub use ssh::ssh_failure_message;
