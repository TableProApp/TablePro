use std::sync::{Mutex, MutexGuard, PoisonError};

mod argv;
mod askpass_bridge;
mod config;
mod destination;
mod forward;
mod hop_config;
mod host_key_checking;
mod known_hosts;
mod password_owner;
mod prompt;
mod route;
mod runtime;
mod runtime_cell;
mod services;
mod session;
mod stderr_classify;
mod supervisor;
mod sweep;

pub use config::{SshAuth, SshConfig};
pub use destination::SshDestination;
pub use forward::SshForwardTransport;
pub use known_hosts::forget_host_key;
pub use prompt::AskpassPrompt;
pub use runtime::SshRuntime;
pub use runtime_cell::SshRuntimeCell;
pub use services::{ASKPASS_HELPER, SshServices};
pub use session::SshSession;
pub use sweep::sweep_stale_masters;

pub(crate) fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}
