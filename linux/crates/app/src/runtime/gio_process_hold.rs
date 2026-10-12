use tablepro_session::runtime::{HoldToken, ProcessHold};

/// Keeps the GApplication running while a token is alive, so closing
/// the last window does not end the process with a connection still
/// closing behind it.
#[derive(Debug, Clone)]
pub struct GioProcessHold {
    application: gio::Application,
}

impl GioProcessHold {
    pub fn new(application: &impl glib::prelude::IsA<gio::Application>) -> Self {
        Self {
            application: application.as_ref().clone(),
        }
    }

    /// The hold for whichever application is running, or none in a test
    /// that never started one.
    pub fn for_default_application() -> Option<Self> {
        gio::Application::default().map(|application| Self { application })
    }
}

impl ProcessHold for GioProcessHold {
    fn acquire(&self) -> HoldToken {
        HoldToken::new(gio::prelude::ApplicationExtManual::hold(&self.application))
    }
}

/// A hold on the running application when there is one, and an inert
/// token otherwise. GTK-thread only, like the application itself.
pub fn hold_default_application() -> HoldToken {
    GioProcessHold::for_default_application().map_or_else(HoldToken::inert, |hold| hold.acquire())
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
}
