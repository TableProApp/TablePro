use gtk4::gdk;
use gtk4::glib::translate::IntoGlib;
use gtk4::prelude::*;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{ConnectionExt as _, KEY_PRESS_EVENT, KEY_RELEASE_EVENT};
use x11rb::protocol::xtest::ConnectionExt as _;
use x11rb::rust_connection::RustConnection;

use super::KeyInjectionError;

const X11_DISPLAY: &str = "GdkX11Display";

/// Presses keys through XTEST, which the X server delivers as it does a
/// keyboard's, so the press meets every capture, class and bubble
/// handler in the order GTK runs them. GDK focuses a presented window
/// itself when no window manager runs, as under Xvfb.
pub(crate) struct KeyInjector {
    connection: RustConnection,
}

impl KeyInjector {
    pub(crate) fn connect() -> Result<Self, KeyInjectionError> {
        let display = gdk::Display::default().map(|display| display.type_().name().to_owned());
        require_x11(display.as_deref().unwrap_or("no display"))?;
        let (connection, _screen) = x11rb::connect(None)?;
        Ok(Self { connection })
    }

    /// Take the keyboard for `window`. A window an earlier test left open
    /// in this process can hold a popup's keyboard grab, which takes
    /// every key, so every other window goes first.
    pub(crate) fn focus_only(window: &impl IsA<gtk4::Window>) {
        let window = window.as_ref();
        for other in gtk4::Window::list_toplevels() {
            if let Ok(other) = other.downcast::<gtk4::Window>()
                && &other != window
            {
                other.destroy();
            }
        }
        window.present();
    }

    /// The modifiers go down first and come up last, as a hand does it.
    pub(crate) fn press(&self, keyval: gdk::Key, modifiers: gdk::ModifierType) -> Result<(), KeyInjectionError> {
        let mut held = Vec::new();
        for (mask, keysym) in [
            (gdk::ModifierType::CONTROL_MASK, gdk::Key::Control_L),
            (gdk::ModifierType::SHIFT_MASK, gdk::Key::Shift_L),
            (gdk::ModifierType::ALT_MASK, gdk::Key::Alt_L),
        ] {
            if modifiers.contains(mask) {
                held.push(self.keycode(keysym)?);
            }
        }
        let key = self.keycode(keyval)?;
        for code in &held {
            self.fake(KEY_PRESS_EVENT, *code)?;
        }
        self.fake(KEY_PRESS_EVENT, key)?;
        self.fake(KEY_RELEASE_EVENT, key)?;
        for code in held.iter().rev() {
            self.fake(KEY_RELEASE_EVENT, *code)?;
        }
        self.connection.flush()?;
        // A round trip, so the server has taken every event before the
        // test waits for what they do.
        self.connection.get_input_focus()?.reply()?;
        Ok(())
    }

    /// The keycode whose unshifted keysym is `keyval`, or failing that
    /// one that carries it at another level.
    fn keycode(&self, keyval: gdk::Key) -> Result<u8, KeyInjectionError> {
        let keysym = keyval.into_glib();
        let setup = self.connection.setup();
        let (first, last) = (setup.min_keycode, setup.max_keycode);
        let mapping = self
            .connection
            .get_keyboard_mapping(first, last.saturating_sub(first).saturating_add(1))?
            .reply()?;
        let per_keycode = usize::from(mapping.keysyms_per_keycode).max(1);
        let keycodes: Vec<&[u32]> = mapping.keysyms.chunks(per_keycode).collect();
        keycodes
            .iter()
            .position(|syms| syms.first() == Some(&keysym))
            .or_else(|| keycodes.iter().position(|syms| syms.contains(&keysym)))
            .and_then(|index| u8::try_from(usize::from(first) + index).ok())
            .ok_or(KeyInjectionError::KeysymNotMapped(keysym))
    }

    fn fake(&self, kind: u8, keycode: u8) -> Result<(), KeyInjectionError> {
        self.connection
            .xtest_fake_input(kind, keycode, x11rb::CURRENT_TIME, x11rb::NONE, 0, 0, 0)?;
        Ok(())
    }
}

fn require_x11(display_type: &str) -> Result<(), KeyInjectionError> {
    if display_type == X11_DISPLAY {
        Ok(())
    } else {
        Err(KeyInjectionError::NotX11(display_type.to_owned()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_injector_reports_not_x11() {
        assert!(matches!(
            require_x11("GdkWaylandDisplay"),
            Err(KeyInjectionError::NotX11(name)) if name == "GdkWaylandDisplay"
        ));
        assert!(require_x11(X11_DISPLAY).is_ok());
    }
}
