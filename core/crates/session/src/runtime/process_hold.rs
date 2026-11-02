use std::any::Any;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

/// Keeps the process alive while background work that must finish is
/// still running, such as closing a connection after its window shut.
///
/// The app implements it over `gio::Application::hold`; tests count.
pub trait ProcessHold {
    fn acquire(&self) -> HoldToken;
}

/// The hold lasts as long as this value.
#[must_use = "the hold ends when the token drops"]
pub struct HoldToken {
    _guard: Box<dyn Any>,
}

impl HoldToken {
    pub fn new(guard: impl Any) -> Self {
        Self {
            _guard: Box::new(guard),
        }
    }

    /// A token that holds nothing, for when the application is already
    /// gone and there is nothing left to keep alive.
    pub fn inert() -> Self {
        Self::new(())
    }
}

impl std::fmt::Debug for HoldToken {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("HoldToken")
    }
}

/// Counts live tokens, for tests that check a hold spans the work.
#[derive(Debug, Clone, Default)]
pub struct CountingHold {
    live: Arc<AtomicUsize>,
}

struct Counted(Arc<AtomicUsize>);

impl Drop for Counted {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

impl CountingHold {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn live(&self) -> usize {
        self.live.load(Ordering::SeqCst)
    }
}

impl ProcessHold for CountingHold {
    fn acquire(&self) -> HoldToken {
        self.live.fetch_add(1, Ordering::SeqCst);
        HoldToken::new(Counted(self.live.clone()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_hold_lasts_as_long_as_its_token() {
        let hold = CountingHold::new();

        let first = hold.acquire();
        let second = hold.acquire();
        assert_eq!(hold.live(), 2);

        drop(first);
        assert_eq!(hold.live(), 1);
        drop(second);
        assert_eq!(hold.live(), 0);
        drop(HoldToken::inert());
    }
}
