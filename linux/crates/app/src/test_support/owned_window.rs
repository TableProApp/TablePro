use std::ops::Deref;

use gtk4 as gtk;
use gtk4::prelude::*;

use super::drain_main_context;

// GTK keeps every window, and what its widgets hold, until it is destroyed.
pub(crate) struct OwnedWindow<W: IsA<gtk::Window>>(W);

impl<W: IsA<gtk::Window>> OwnedWindow<W> {
    pub(crate) fn new(window: W) -> Self {
        Self(window)
    }

    pub(crate) fn presented(window: W) -> Self {
        window.present();
        Self(window)
    }
}

impl<W: IsA<gtk::Window>> Deref for OwnedWindow<W> {
    type Target = W;

    fn deref(&self) -> &W {
        &self.0
    }
}

impl<W: IsA<gtk::Window>> AsRef<gtk::Widget> for OwnedWindow<W> {
    fn as_ref(&self) -> &gtk::Widget {
        self.0.upcast_ref::<gtk::Window>().upcast_ref()
    }
}

impl<W: IsA<gtk::Window>> Drop for OwnedWindow<W> {
    fn drop(&mut self) {
        drop_focus(&self.0);
        self.0.destroy();
        drain_main_context();
    }
}

// GTK 4.22 leaks a focused widget that is hidden and then unparented,
// as tearing a window down does (fixed in GTK 4.24).
pub(crate) fn drop_focus(window: &impl IsA<gtk::Window>) {
    window.set_focus(None::<&gtk::Widget>);
}
