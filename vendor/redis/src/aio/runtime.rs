use std::{io, sync::Arc, time::Duration};

use futures_util::Future;

#[cfg(all(feature = "tokio-comp", feature = "smol-comp"))]
use std::sync::OnceLock;

use super::RedisRuntime;
#[cfg(feature = "smol-comp")]
use super::smol as crate_smol;
#[cfg(feature = "tokio-comp")]
use super::tokio as crate_tokio;
use crate::errors::RedisError;
#[cfg(feature = "smol-comp")]
use smol_timeout::TimeoutExt;

#[derive(Clone, Copy, Debug)]
pub(crate) enum Runtime {
    #[cfg(feature = "tokio-comp")]
    Tokio,
    #[cfg(feature = "smol-comp")]
    Smol,
}

pub(crate) enum TaskHandle {
    #[cfg(feature = "tokio-comp")]
    Tokio(tokio::task::JoinHandle<()>),
    #[cfg(feature = "smol-comp")]
    Smol(smol::Task<()>),
}

impl TaskHandle {
    #[cfg(feature = "connection-manager")]
    pub(crate) fn detach(self) {
        match self {
            #[cfg(feature = "smol-comp")]
            Self::Smol(task) => task.detach(),
            #[cfg(feature = "tokio-comp")]
            _ => {}
        }
    }
}

pub(crate) struct HandleContainer(Option<TaskHandle>);

impl HandleContainer {
    pub(crate) fn new(handle: TaskHandle) -> Self {
        Self(Some(handle))
    }
}

impl Drop for HandleContainer {
    fn drop(&mut self) {
        match self.0.take() {
            None => {}
            #[cfg(feature = "tokio-comp")]
            Some(TaskHandle::Tokio(handle)) => handle.abort(),
            #[cfg(feature = "smol-comp")]
            Some(TaskHandle::Smol(task)) => drop(task),
        }
    }
}

#[derive(Clone)]
// we allow dead code here because the container isn't used directly, only in the derived drop.
#[allow(dead_code)]
pub(crate) struct SharedHandleContainer(Arc<HandleContainer>);

impl SharedHandleContainer {
    pub(crate) fn new(handle: TaskHandle) -> Self {
        Self(Arc::new(HandleContainer::new(handle)))
    }
}

#[cfg(all(feature = "tokio-comp", feature = "smol-comp"))]
static CHOSEN_RUNTIME: OnceLock<Runtime> = OnceLock::new();

#[cfg(all(feature = "tokio-comp", feature = "smol-comp"))]
fn set_runtime(runtime: Runtime) -> Result<(), RedisError> {
    const PREFER_RUNTIME_ERROR: &str = "Another runtime preference was already set. Please call this function before any other runtime preference is set.";

    CHOSEN_RUNTIME
        .set(runtime)
        .map_err(|_| RedisError::from((crate::ErrorKind::Client, PREFER_RUNTIME_ERROR)))
}

/// Mark Smol as the preferred runtime.
///
/// If the function returns `Err`, another runtime preference was already set, and won't be changed.
/// Call this function if the application doesn't use multiple runtimes,
/// but the crate is compiled with multiple runtimes enabled, which is a bad pattern that should be avoided.
#[cfg(all(feature = "smol-comp", feature = "tokio-comp"))]
pub fn prefer_smol() -> Result<(), RedisError> {
    set_runtime(Runtime::Smol)
}

/// Mark Tokio as the preferred runtime.
///
/// If the function returns `Err`, another runtime preference was already set, and won't be changed.
/// Call this function if the application doesn't use multiple runtimes,
/// but the crate is compiled with multiple runtimes enabled, which is a bad pattern that should be avoided.
#[cfg(all(feature = "smol-comp", feature = "tokio-comp"))]
pub fn prefer_tokio() -> Result<(), RedisError> {
    set_runtime(Runtime::Tokio)
}

impl Runtime {
    pub(crate) fn locate() -> Self {
        #[cfg(all(feature = "smol-comp", feature = "tokio-comp"))]
        if let Some(runtime) = CHOSEN_RUNTIME.get() {
            return *runtime;
        }

        #[cfg(all(feature = "tokio-comp", not(feature = "smol-comp")))]
        {
            Runtime::Tokio
        }

        #[cfg(all(not(feature = "tokio-comp"), feature = "smol-comp",))]
        {
            Runtime::Smol
        }

        cfg_if::cfg_if! {
            if #[cfg(all(feature = "tokio-comp", feature = "smol-comp"))] {
                if ::tokio::runtime::Handle::try_current().is_ok() {
                    Self::Tokio
                } else {
                    Self::Smol
                }
            }
        }

        #[cfg(all(not(feature = "tokio-comp"), not(feature = "smol-comp")))]
        {
            compile_error!("tokio-comp or smol-comp features required for aio feature")
        }
    }

    #[must_use]
    pub(crate) fn spawn(self, f: impl Future<Output = ()> + Send + 'static) -> TaskHandle {
        match self {
            #[cfg(feature = "tokio-comp")]
            Self::Tokio => crate_tokio::Tokio::spawn(f),
            #[cfg(feature = "smol-comp")]
            Self::Smol => crate_smol::Smol::spawn(f),
        }
    }

    pub(crate) async fn timeout<F: Future>(
        &self,
        duration: Duration,
        future: F,
    ) -> Result<F::Output, Elapsed> {
        match self {
            #[cfg(feature = "tokio-comp")]
            Self::Tokio => tokio::time::timeout(duration, future)
                .await
                .map_err(|_| Elapsed(())),
            #[cfg(feature = "smol-comp")]
            Self::Smol => future.timeout(duration).await.ok_or(Elapsed(())),
        }
    }

    #[cfg(any(feature = "connection-manager", feature = "cluster-async"))]
    pub(crate) async fn sleep(&self, duration: Duration) {
        match self {
            #[cfg(feature = "tokio-comp")]
            Self::Tokio => {
                tokio::time::sleep(duration).await;
            }

            #[cfg(feature = "smol-comp")]
            Self::Smol => {
                smol::Timer::after(duration).await;
            }
        }
    }

    #[cfg(feature = "cluster-async")]
    pub(crate) async fn locate_and_sleep(duration: Duration) {
        Self::locate().sleep(duration).await;
    }
}

#[derive(Debug)]
pub(crate) struct Elapsed(());

impl From<Elapsed> for RedisError {
    fn from(_: Elapsed) -> Self {
        io::Error::from(io::ErrorKind::TimedOut).into()
    }
}
