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
pub use known_hosts::{ForgetHostKeyError, forget_changed_host_key, forget_host_key};
pub use prompt::AskpassPrompt;
pub use runtime::SshRuntime;
pub use runtime_cell::SshRuntimeCell;
pub use services::{ASKPASS_HELPER, SshServices};
pub use session::SshSession;
pub use sweep::sweep_stale_masters;

pub(crate) fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

// The panic hook has reported a panic, and a cancel comes only as the
// runtime shuts down, so the error is logged, not shown.
pub(crate) fn setup_task_failed(error: &tokio::task::JoinError) -> tablepro_core::SshFailure {
    tracing::warn!(%error, "an SSH setup task stopped");
    tablepro_core::SshFailure::Internal
}
