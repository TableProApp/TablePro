// The configuration, destination and prompt types are portable. The
// transport drives the system OpenSSH client over Unix sockets and an
// askpass helper, so it builds on Unix alone.

mod config;
mod destination;
mod prompt;

#[cfg(unix)]
mod argv;
#[cfg(unix)]
mod askpass_bridge;
#[cfg(unix)]
mod forward;
#[cfg(unix)]
mod hop_config;
#[cfg(unix)]
mod host_key_checking;
#[cfg(unix)]
mod identity_pin;
#[cfg(unix)]
mod known_hosts;
#[cfg(unix)]
mod password_owner;
#[cfg(unix)]
mod route;
#[cfg(unix)]
mod runtime;
#[cfg(unix)]
mod runtime_cell;
#[cfg(unix)]
mod services;
#[cfg(unix)]
mod session;
#[cfg(unix)]
mod stderr_classify;
#[cfg(unix)]
mod supervisor;
#[cfg(unix)]
mod sweep;

pub use config::{SshAuth, SshConfig};
pub use destination::SshDestination;
pub use prompt::AskpassPrompt;

#[cfg(unix)]
pub use forward::SshForwardTransport;
#[cfg(unix)]
pub use known_hosts::{ForgetHostKeyError, forget_changed_host_key, forget_host_key};
#[cfg(unix)]
pub use runtime::SshRuntime;
#[cfg(unix)]
pub use runtime_cell::SshRuntimeCell;
#[cfg(unix)]
pub use services::{ASKPASS_HELPER, SshServices};
#[cfg(unix)]
pub use session::SshSession;
#[cfg(unix)]
pub use sweep::sweep_stale_masters;

#[cfg(unix)]
pub(crate) fn lock<T>(mutex: &std::sync::Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

// The panic hook has reported a panic, and a cancel comes only as the
// runtime shuts down, so the error is logged, not shown.
#[cfg(unix)]
pub(crate) fn setup_task_failed(error: &tokio::task::JoinError) -> tablepro_core::SshFailure {
    tracing::warn!(%error, "an SSH setup task stopped");
    tablepro_core::SshFailure::Internal
}
