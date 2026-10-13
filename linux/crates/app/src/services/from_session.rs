use std::sync::{Arc, Weak};

use tablepro_session::Session;

use super::active_session::ActiveSession;

/// A message a session's watcher queued for the window, and the session
/// it came from.
///
/// The window's queue can hold one behind the switch to another
/// session, and by the time it is handled it describes a session the
/// window has let go of.
#[derive(Debug)]
pub struct FromSession<T> {
    origin: Weak<Session>,
    value: T,
}

impl<T> FromSession<T> {
    pub fn new(origin: Weak<Session>, value: T) -> Self {
        Self { origin, value }
    }

    /// The value, while the session it came from is still the window's.
    pub fn if_current(self, active: &ActiveSession) -> Option<T> {
        let current = active.get()?;
        Weak::ptr_eq(&Arc::downgrade(&current), &self.origin).then_some(self.value)
    }
}

#[cfg(test)]
mod tests {
    use tablepro_test_support::ConnectionScript;

    use super::*;
    use crate::test_support::FakeSession;

    #[test]
    fn only_the_current_session_is_heard() {
        let runtime = crate::test_support::test_runtime();
        let a = FakeSession::start(ConnectionScript::default(), [], runtime.tasks());
        let b = FakeSession::start(ConnectionScript::default(), [], runtime.tasks());
        let active = ActiveSession::new();
        let from_a = || FromSession::new(Arc::downgrade(&a.session), "a");

        assert_eq!(from_a().if_current(&active), None, "heard with no session open");
        active.replace(a.session.clone());
        assert_eq!(from_a().if_current(&active), Some("a"));
        active.replace(b.session.clone());
        assert_eq!(
            from_a().if_current(&active),
            None,
            "heard after the switch to another session"
        );
        assert_eq!(
            FromSession::new(Arc::downgrade(&b.session), "b").if_current(&active),
            Some("b")
        );
    }
}
