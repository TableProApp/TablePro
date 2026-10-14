use std::time::Duration;

use gtk4 as gtk;
use gtk4::prelude::*;

use super::{WaitTimedOut, wait_until};

const WAIT: Duration = Duration::from_secs(5);

/// A window of its own that takes the focus from a test's window, as
/// another application does, so handing it back is a real focus-in.
/// GDK focuses a presented window itself when no window manager runs,
/// as under Xvfb.
pub(crate) struct FocusThief {
    window: gtk::Window,
}

impl FocusThief {
    pub(crate) fn take_from(window: &impl IsA<gtk::Window>) -> Result<Self, WaitTimedOut> {
        let thief = gtk::Window::new();
        thief.present();
        let window = window.as_ref();
        wait_until(WAIT, || !window.is_active())?;
        Ok(Self { window: thief })
    }

    /// Give the focus back to `window` without running the main loop.
    /// The display round trip queues the focus-in, and GDK dispatches
    /// events ahead of painting, so the window sees it before the next
    /// frame.
    pub(crate) fn give_back(&self, window: &impl IsA<gtk::Window>) {
        let window = window.as_ref();
        window.present();
        WidgetExt::display(window).sync();
    }
}

impl Drop for FocusThief {
    fn drop(&mut self) {
        self.window.destroy();
    }
}
