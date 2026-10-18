use glib::prelude::*;
use tablepro_session::runtime::{HoldToken, ProcessHold};

/// Keeps the GApplication running while a token is alive, so closing
/// the last window does not end the process with a connection still
/// closing behind it.
///
/// It holds the application weakly: the application owns the services
/// this lives in, and a token taken once the application is gone has
/// nothing left to keep alive.
#[derive(Debug, Clone, Default)]
pub struct GioProcessHold {
    application: glib::WeakRef<gio::Application>,
}

impl GioProcessHold {
    pub fn new(application: &impl IsA<gio::Application>) -> Self {
        let hold = Self::default();
        hold.bind(application);
        hold
    }

    /// Point the hold at `application`. Tokens taken before this hold
    /// nothing.
    pub fn bind(&self, application: &impl IsA<gio::Application>) {
        self.application.set(Some(application.upcast_ref()));
    }
}

impl ProcessHold for GioProcessHold {
    fn acquire(&self) -> HoldToken {
        self.application.upgrade().map_or_else(HoldToken::inert, |application| {
            HoldToken::new(gio::prelude::ApplicationExtManual::hold(&application))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[gtk4::test]
    fn the_hold_lasts_as_long_as_its_token() {
        let application = gio::Application::new(None, gio::ApplicationFlags::NON_UNIQUE);
        let hold = GioProcessHold::new(&application);

        let token = hold.acquire();
        drop(token);
        let again = hold.acquire();
        drop(again);
    }

    #[gtk4::test]
    fn a_hold_without_an_application_gives_inert_tokens() {
        let unbound = GioProcessHold::default();
        drop(unbound.acquire());

        let application = gio::Application::new(None, gio::ApplicationFlags::NON_UNIQUE);
        let hold = GioProcessHold::new(&application);
        drop(application);

        assert!(
            hold.application.upgrade().is_none(),
            "the hold kept the application alive"
        );
        drop(hold.acquire());
    }
}
