use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use super::scheduler::Wake;
use crate::api::control::PassReason;
use crate::api::ids::{EpochId, ScopeName};
use crate::api::key_flows::{KeyHooks, KeyNotice, KeyState, LockCause};
use crate::api::state::StoppedCause;

// What the app is told: it only schedules a read (core ADR 0002).
pub trait EngineEvents: Send + Sync {
    fn status_changed(&self);

    fn keys_changed(&self);

    // The values waiting for the person changed: a pull brought or cleared some, or the person decided.
    fn approvals_changed(&self);
}

// The engine's side of the key flows: a lock, and the scopes whose secrets wait, which every pass reads.
#[derive(Default)]
pub struct EngineHooks {
    state: Mutex<HookState>,
    wake: Wake,
    events: Option<Arc<dyn EngineEvents>>,
}

#[derive(Debug, Default)]
struct HookState {
    lock: Option<LockCause>,
    stopped: HashMap<ScopeName, StoppedCause>,
    ended: HashMap<ScopeName, Option<EpochId>>,
    notices: Vec<KeyNotice>,
    // What the key state read after the last pass.
    keys: Option<KeyState>,
}

impl std::fmt::Debug for EngineHooks {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EngineHooks")
            .field("state", &self.state())
            .finish_non_exhaustive()
    }
}

impl EngineHooks {
    pub fn new(wake: Wake, events: Option<Arc<dyn EngineEvents>>) -> Self {
        Self {
            state: Mutex::default(),
            wake,
            events,
        }
    }

    fn state(&self) -> MutexGuard<'_, HookState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn keys_changed(&self) {
        if let Some(events) = &self.events {
            events.keys_changed();
        }
    }

    pub fn locked(&self) -> Option<LockCause> {
        self.state().lock
    }

    // An approval or a recovery merged into the key tables.
    pub fn unlock(&self) {
        self.state().lock = None;
        self.keys_changed();
    }

    // What the key flows hold at the start of a pass, which outlives the process and a flow's own calls here: their
    // lock, and the scopes whose key version stopped or ended (0054, `key_versions`). A Sign Out or an approval that
    // cleared them clears them here too. `device_removed` is the server's answer, which only a new sign-in ends.
    pub fn refresh(
        &self,
        lock: Option<LockCause>,
        stopped: HashMap<ScopeName, StoppedCause>,
        ended: HashMap<ScopeName, Option<EpochId>>,
    ) {
        let mut state = self.state();
        let lock = match state.lock {
            Some(LockCause::DeviceRemoved) => Some(LockCause::DeviceRemoved),
            _ => lock,
        };
        let changed = state.lock != lock || state.stopped != stopped || state.ended != ended;
        state.lock = lock;
        state.stopped = stopped;
        state.ended = ended;
        drop(state);
        if changed {
            self.keys_changed();
        }
    }

    // A pull can move the key state with no flow, as the first one after a sign-in does from unknown to needing
    // approval, and the app hears that as a key change.
    pub fn read_keys(&self, keys: KeyState) {
        let mut state = self.state();
        let changed = state.keys.as_ref() != Some(&keys);
        state.keys = Some(keys);
        drop(state);
        if changed {
            self.keys_changed();
        }
    }

    // The scope writes no secret under its key: stopped until what it waits for is back, or ended for good.
    pub fn holds_secrets(&self, scope: ScopeName) -> bool {
        let state = self.state();
        state.stopped.contains_key(&scope) || state.ended.contains_key(&scope)
    }

    pub fn take_notices(&self) -> Vec<KeyNotice> {
        std::mem::take(&mut self.state().notices)
    }
}

impl KeyHooks for EngineHooks {
    fn lock(&self, cause: LockCause) {
        self.state().lock = Some(cause);
        self.keys_changed();
    }

    fn stop_scope(&self, scope: ScopeName, cause: StoppedCause) {
        self.state().stopped.insert(scope, cause);
        self.keys_changed();
    }

    // A full pass, since what a flow asks to carry is not in the journal.
    fn resume_scope(&self, scope: ScopeName) {
        self.state().stopped.remove(&scope);
        self.keys_changed();
        self.wake.pass_soon(PassReason::KeyFlow);
    }

    fn end_scope(&self, scope: ScopeName, epoch: Option<EpochId>) {
        let mut state = self.state();
        state.stopped.remove(&scope);
        state.ended.insert(scope, epoch);
        drop(state);
        self.keys_changed();
    }

    fn notice(&self, notice: KeyNotice) {
        self.state().notices.push(notice);
        self.keys_changed();
    }

    fn pass_soon(&self) {
        self.wake.pass_soon(PassReason::KeyFlow);
    }
}
