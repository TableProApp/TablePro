use std::sync::{Mutex, MutexGuard, PoisonError};

mod argv;
mod askpass_bridge;
mod config;
mod destination;
mod error;
mod forward;
mod prompt;
mod runtime;
mod session;
mod stderr_classify;
mod supervisor;
mod sweep;

pub use config::{OpenSshAuth, OpenSshConfig, OpenSshTimeouts};
pub use destination::{ForwardTarget, LocalEndpoint, SshDestination};
pub use error::{OpenSshError, TimeoutPhase};
pub use forward::{ForwardRoute, OpenSshForward};
pub use prompt::{AskpassPrompt, PromptAnswer, Prompter, UnattendedPrompter};
pub use runtime::OpenSshRuntime;
pub use session::{OpenSshContext, OpenSshSession};
pub use sweep::sweep_stale_masters;

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}
