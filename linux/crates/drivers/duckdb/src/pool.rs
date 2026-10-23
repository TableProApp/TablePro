use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Weak};
use std::time::Duration;

use deadpool::Runtime;
use deadpool::managed::{Manager, Metrics, Object, Pool, PoolError, RecycleResult, Timeouts};
use tablepro_core::{BusyReason, CallResource, DriverError, LivenessPolicy, LossPhase, StopRequest};

use crate::instance::{Instance, Link, StopHandle};

/// The workspace pool's size. DuckDB runs the queries of one database
/// side by side, so a slow page read does not hold up the sidebar.
pub const WORKSPACE_POOL_MAX_SIZE: usize = 4;

pub(crate) type LinkPool = Pool<LinkManager>;

/// deadpool's manager for workspace connections, which are new
/// connections to the one open database. It does not keep the database
/// open: a workspace that closed lets the file go.
pub(crate) struct LinkManager {
    instance: Weak<Instance>,
}

impl Manager for LinkManager {
    type Type = Link;
    type Error = DriverError;

    async fn create(&self) -> Result<Link, DriverError> {
        match self.instance.upgrade() {
            Some(instance) => instance.link(),
            None => Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            }),
        }
    }

    /// Every call ends its own transaction, and one that did not end
    /// cleanly never gets here: the call takes it out of the pool.
    async fn recycle(&self, _link: &mut Link, _metrics: &Metrics) -> RecycleResult<DriverError> {
        Ok(())
    }
}

pub(crate) fn build_pool(instance: &Arc<Instance>, liveness: &LivenessPolicy) -> Result<LinkPool, DriverError> {
    Pool::builder(LinkManager {
        instance: Arc::downgrade(instance),
    })
    .max_size(WORKSPACE_POOL_MAX_SIZE)
    .wait_timeout(Some(liveness.pool_wait))
    .create_timeout(Some(liveness.connect_timeout))
    .runtime(Runtime::Tokio1)
    .build()
    .map_err(|error| DriverError::Protocol(error.to_string()))
}

/// The probe never waits for a slot: a busy pool is not a dead database.
pub(crate) fn probe_timeouts(liveness: &LivenessPolicy) -> Timeouts {
    Timeouts {
        wait: Some(Duration::ZERO),
        create: Some(liveness.connect_timeout),
        recycle: None,
    }
}

fn map_pool_error(error: PoolError<DriverError>) -> DriverError {
    match error {
        PoolError::Backend(error) => error,
        PoolError::Timeout(_) => DriverError::Busy(BusyReason::NoFreeConnection),
        PoolError::Closed => DriverError::ConnectionLost {
            during: LossPhase::Idle,
        },
        other => DriverError::Protocol(other.to_string()),
    }
}

/// Where a call's connection lives while the call holds it.
enum Held {
    Empty,
    Pooled(Object<LinkManager>),
    Own(Link),
}

/// The connection one call runs on: a pool slot, or a connection of the
/// call's own for a probe that finds every slot busy and for a streamed
/// read. It starts empty and is filled inside the call, so the call's
/// deadline and cancel cover the wait for a slot too.
pub(crate) struct DuckCall {
    held: Held,
    abandon: Arc<AtomicBool>,
}

impl DuckCall {
    pub(crate) fn new() -> Self {
        Self {
            held: Held::Empty,
            abandon: Arc::new(AtomicBool::new(false)),
        }
    }

    pub(crate) fn pooled(object: Object<LinkManager>) -> Self {
        Self {
            held: Held::Pooled(object),
            abandon: Arc::new(AtomicBool::new(false)),
        }
    }

    /// The connection may still hold a transaction, so it must not go
    /// back to the pool.
    pub(crate) fn taint(&self) {
        self.abandon.store(true, Ordering::SeqCst);
    }

    pub(crate) fn own(link: Link) -> Self {
        Self {
            held: Held::Own(link),
            abandon: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Take a slot, giving up as soon as the call is stopped.
    pub(crate) async fn acquire(
        &mut self,
        pool: &LinkPool,
        timeouts: &Timeouts,
        request: &StopRequest,
    ) -> Result<(), DriverError> {
        let object = tokio::select! {
            biased;
            () = request.requested() => return Err(crate::errors::interrupted()),
            object = pool.timeout_get(timeouts) => object.map_err(map_pool_error)?,
        };
        self.held = Held::Pooled(object);
        Ok(())
    }

    /// Whether the call still has its connection. A `run` given up while
    /// its work ran leaves the connection with that work.
    pub(crate) fn holds_connection(&self) -> bool {
        !matches!(self.held, Held::Empty)
    }

    /// The handle that stops the statement this call runs.
    pub(crate) fn stop_handle(&self) -> Option<StopHandle> {
        match &self.held {
            Held::Pooled(object) => Some(object.stop_handle()),
            Held::Own(link) => Some(link.stop_handle()),
            Held::Empty => None,
        }
    }

    /// Run `work` on the held connection, on a thread where blocking is
    /// allowed, unless `request` asks for a stop by the time it would
    /// start. A stop interrupts it until it returns or holds stops off
    /// itself. A call abandoned while the work runs never returns its
    /// connection to the pool.
    pub(crate) async fn run<T, W>(&mut self, request: Option<&StopRequest>, work: W) -> Result<T, DriverError>
    where
        T: Send + 'static,
        W: FnOnce(&mut Link) -> Result<T, DriverError> + Send + 'static,
    {
        let held = std::mem::replace(&mut self.held, Held::Empty);
        let Some(stop) = (match &held {
            Held::Pooled(object) => Some(object.stop_handle()),
            Held::Own(link) => Some(link.stop_handle()),
            Held::Empty => None,
        }) else {
            return Err(DriverError::Protocol("the call holds no connection".to_owned()));
        };
        let abandon = self.abandon.clone();
        let request = request.cloned();
        stop.set_stoppable(true);
        let joined = tokio::task::spawn_blocking(move || {
            let mut held = held;
            let stopped = request.as_ref().is_some_and(StopRequest::is_requested);
            let outcome = match (&mut held, stopped) {
                (_, true) => Ok(Err(crate::errors::interrupted())),
                (Held::Pooled(object), false) => catch_unwind(AssertUnwindSafe(|| work(object))),
                (Held::Own(link), false) => catch_unwind(AssertUnwindSafe(|| work(link))),
                (Held::Empty, false) => Ok(Err(DriverError::Protocol("the call holds no connection".to_owned()))),
            };
            stop.set_stoppable(false);
            match outcome {
                Ok(result) if !abandon.load(Ordering::SeqCst) => (held, result),
                // A connection whose work broke off, or whose caller gave
                // it up, holds a state nothing knows.
                Ok(result) => (detach(held), result),
                Err(_) => (
                    detach(held),
                    Err(DriverError::Protocol("DuckDB failed inside a call".to_owned())),
                ),
            }
        })
        .await;
        match joined {
            Ok((held, result)) => {
                self.held = held;
                result
            }
            Err(_) => Err(DriverError::ConnectionLost {
                during: LossPhase::Statement,
            }),
        }
    }
}

fn detach(held: Held) -> Held {
    if let Held::Pooled(object) = held {
        drop(Object::take(object));
    }
    Held::Empty
}

impl CallResource for DuckCall {
    fn abandon_flag(&self) -> Arc<AtomicBool> {
        self.abandon.clone()
    }

    fn discard(mut self) {
        self.held = detach(std::mem::replace(&mut self.held, Held::Empty));
    }
}

impl Drop for DuckCall {
    fn drop(&mut self) {
        if self.abandon.load(Ordering::SeqCst) {
            self.held = detach(std::mem::replace(&mut self.held, Held::Empty));
        }
    }
}
