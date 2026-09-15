use std::sync::{Mutex, MutexGuard, PoisonError};

mod call_counters;
mod close_behaviour;
mod connection_script;
mod fake_connection;
mod fake_driver;
mod fake_prompter;
mod fake_secret_vault;

pub use call_counters::CallCounters;
pub use close_behaviour::CloseBehaviour;
pub use connection_script::ConnectionScript;
pub use fake_connection::FakeConnection;
pub use fake_driver::FakeDriver;
pub use fake_prompter::FakePrompter;
pub use fake_secret_vault::{Call, FakeSecretVault};

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}
