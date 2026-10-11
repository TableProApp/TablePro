//! Contains the events and functionality for monitoring internal `Client` behavior.

pub mod cmap;
pub mod command;
pub mod sdam;

use std::sync::Arc;

use futures_core::future::BoxFuture;

use crate::event::command::CommandEvent;

use self::{cmap::CmapEvent, sdam::SdamEvent};

/// A destination for events.  Allows implicit conversion via [`From`] for concrete types for
/// convenience with [`crate::options::ClientOptions`] construction:
///
/// ```rust
/// # use mongodb::options::ClientOptions;
/// # fn example() {
/// let (tx, mut rx) = tokio::sync::mpsc::channel(100);
/// tokio::spawn(async move {
///     while let Some(ev) = rx.recv().await {
///         println!("{:?}", ev);
///     }
/// });
/// let options = ClientOptions::builder()
///                 .command_event_handler(tx)
///                 .build();
/// # }
/// ```
///
/// or explicit construction for `Fn` traits:
///
/// ```rust
/// # use mongodb::options::ClientOptions;
/// # use mongodb::event::EventHandler;
/// # fn example() {
/// let options = ClientOptions::builder()
///                 .command_event_handler(EventHandler::callback(|ev| println!("{:?}", ev)))
///                 .build();
/// # }
/// ```
#[derive(Clone)]
#[non_exhaustive]
pub enum EventHandler<T> {
    /// A callback.
    Callback(Arc<dyn Fn(T) + Sync + Send>),
    /// An async callback.
    AsyncCallback(Arc<dyn Fn(T) -> BoxFuture<'static, ()> + Sync + Send>),
    /// A `tokio` channel sender.
    TokioMpsc(tokio::sync::mpsc::Sender<T>),
}

impl<T> std::fmt::Debug for EventHandler<T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("EventHandler").finish()
    }
}

impl<T> From<tokio::sync::mpsc::Sender<T>> for EventHandler<T> {
    fn from(value: tokio::sync::mpsc::Sender<T>) -> Self {
        Self::TokioMpsc(value)
    }
}

#[allow(deprecated)]
impl<T: crate::event::command::CommandEventHandler + 'static> From<Arc<T>>
    for EventHandler<CommandEvent>
{
    fn from(value: Arc<T>) -> Self {
        Self::callback(move |ev| match ev {
            CommandEvent::Started(e) => value.handle_command_started_event(e),
            CommandEvent::Succeeded(e) => value.handle_command_succeeded_event(e),
            CommandEvent::Failed(e) => value.handle_command_failed_event(e),
        })
    }
}

#[allow(deprecated)]
impl<T: crate::event::cmap::CmapEventHandler + 'static> From<Arc<T>> for EventHandler<CmapEvent> {
    fn from(value: Arc<T>) -> Self {
        use CmapEvent::*;
        Self::callback(move |ev| match ev {
            PoolCreated(ev) => value.handle_pool_created_event(ev),
            PoolReady(ev) => value.handle_pool_ready_event(ev),
            PoolCleared(ev) => value.handle_pool_cleared_event(ev),
            PoolClosed(ev) => value.handle_pool_closed_event(ev),
            ConnectionCreated(ev) => value.handle_connection_created_event(ev),
            ConnectionReady(ev) => value.handle_connection_ready_event(ev),
            ConnectionClosed(ev) => value.handle_connection_closed_event(ev),
            ConnectionCheckoutStarted(ev) => value.handle_connection_checkout_started_event(ev),
            ConnectionCheckoutFailed(ev) => value.handle_connection_checkout_failed_event(ev),
            ConnectionCheckedOut(ev) => value.handle_connection_checked_out_event(ev),
            ConnectionCheckedIn(ev) => value.handle_connection_checked_in_event(ev),
        })
    }
}

#[allow(deprecated)]
impl<T: crate::event::sdam::SdamEventHandler + 'static> From<Arc<T>> for EventHandler<SdamEvent> {
    fn from(value: Arc<T>) -> Self {
        use SdamEvent::*;
        Self::callback(move |ev| match ev {
            ServerDescriptionChanged(ev) => value.handle_server_description_changed_event(*ev),
            ServerOpening(ev) => value.handle_server_opening_event(ev),
            ServerClosed(ev) => value.handle_server_closed_event(ev),
            TopologyDescriptionChanged(ev) => value.handle_topology_description_changed_event(*ev),
            TopologyOpening(ev) => value.handle_topology_opening_event(ev),
            TopologyClosed(ev) => value.handle_topology_closed_event(ev),
            ServerHeartbeatStarted(ev) => value.handle_server_heartbeat_started_event(ev),
            ServerHeartbeatSucceeded(ev) => value.handle_server_heartbeat_succeeded_event(ev),
            ServerHeartbeatFailed(ev) => value.handle_server_heartbeat_failed_event(ev),
        })
    }
}

impl<T: Send + Sync + 'static> EventHandler<T> {
    /// Construct a new event handler with a callback.
    pub fn callback(f: impl Fn(T) + Send + Sync + 'static) -> Self {
        Self::Callback(Arc::new(f))
    }

    /// Construct a new event handler with an async callback.
    pub fn async_callback(f: impl Fn(T) -> BoxFuture<'static, ()> + Send + Sync + 'static) -> Self {
        Self::AsyncCallback(Arc::new(f))
    }

    pub(crate) fn handle(&self, event: T) {
        match self {
            // TODO RUST-1731 Use tokio's spawn_blocking
            Self::Callback(cb) => (cb)(event),
            Self::AsyncCallback(cb) => {
                crate::runtime::spawn((cb)(event));
            }
            Self::TokioMpsc(sender) => {
                let sender = sender.clone();
                crate::runtime::spawn(async move {
                    let _ = sender.send(event).await;
                });
            }
        }
    }
}
