use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};

use mongodb::error::Error;
use mongodb::event::EventHandler;
use mongodb::event::sdam::SdamEvent;
use tokio::sync::Notify;

/// What the client's monitors found while it connects. The library waits
/// out its whole selection timeout for a server it cannot reach; the
/// monitors know at once, and say why in the error they met.
#[derive(Clone)]
pub(crate) struct ConnectWatch {
    state: Arc<Mutex<State>>,
    changed: Arc<Notify>,
}

#[derive(Default)]
struct State {
    /// Each server the client opened, and whether a heartbeat reached it.
    servers: HashMap<String, Option<bool>>,
    first_failure: Option<Error>,
}

impl State {
    /// Every server the client knows was tried, and none answered.
    fn unreachable(&self) -> Option<Error> {
        let all_failed = !self.servers.is_empty() && self.servers.values().all(|seen| *seen == Some(false));
        all_failed.then(|| self.first_failure.clone()).flatten()
    }
}

impl ConnectWatch {
    pub(crate) fn new() -> Self {
        Self {
            state: Arc::new(Mutex::new(State::default())),
            changed: Arc::new(Notify::new()),
        }
    }

    pub(crate) fn handler(&self) -> EventHandler<SdamEvent> {
        let (state, changed) = (self.state.clone(), self.changed.clone());
        EventHandler::callback(move |event: SdamEvent| {
            let mut state = state.lock().unwrap_or_else(PoisonError::into_inner);
            match event {
                SdamEvent::ServerOpening(opening) => {
                    state.servers.entry(opening.address.to_string()).or_insert(None);
                }
                SdamEvent::ServerClosed(closed) => {
                    state.servers.remove(&closed.address.to_string());
                }
                SdamEvent::ServerHeartbeatSucceeded(succeeded) => {
                    state.servers.insert(succeeded.server_address.to_string(), Some(true));
                }
                SdamEvent::ServerHeartbeatFailed(failed) => {
                    let seen = state.servers.entry(failed.server_address.to_string()).or_insert(None);
                    if *seen != Some(true) {
                        *seen = Some(false);
                    }
                    state.first_failure.get_or_insert(failed.failure);
                }
                _ => return,
            }
            drop(state);
            changed.notify_waiters();
        })
    }

    /// Resolves with the first failure once every server has failed.
    pub(crate) async fn unreachable(&self) -> Error {
        loop {
            let notified = self.changed.notified();
            if let Some(failure) = self.state.lock().unwrap_or_else(PoisonError::into_inner).unreachable() {
                return failure;
            }
            notified.await;
        }
    }
}
