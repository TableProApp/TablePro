use gtk4::prelude::*;
use tablepro_storage::{AppSettings, WindowGeometry};

pub(crate) fn restore(window: &libadwaita::ApplicationWindow, settings: &AppSettings) {
    let geometry = settings.window_geometry();
    window.set_default_size(geometry.width, geometry.height);
    if geometry.maximized {
        window.maximize();
    }
}

/// A maximized window reports the screen size, which would come back as
/// the restored size the next time it opens unmaximized. GTK keeps the
/// pre-maximize size in the default-width and default-height properties,
/// so read those instead. A window that was never allocated reports a
/// zero size, which the schema range refuses, so the default size stands
/// in for it.
pub(crate) fn persist(window: &libadwaita::ApplicationWindow, settings: &AppSettings) {
    let maximized = window.is_maximized();
    let allocated = (window.width(), window.height());
    let (width, height) = if maximized || allocated.0 <= 0 || allocated.1 <= 0 {
        (window.default_width(), window.default_height())
    } else {
        allocated
    };
    if let Err(error) = settings.set_window_geometry(WindowGeometry {
        width,
        height,
        maximized,
    }) {
        tracing::warn!(%error, "could not save the window geometry");
    }
}

#[cfg(test)]
mod tests {
    use tablepro_storage::WindowGeometry;

    use crate::test_support::MemorySettings;

    use super::*;

    #[gtk4::test]
    fn restore_applies_the_stored_size() {
        let settings = MemorySettings::new();
        settings
            .get()
            .set_window_geometry(WindowGeometry {
                width: 1024,
                height: 640,
                maximized: false,
            })
            .expect("store the geometry");
        let application = libadwaita::Application::builder()
            .application_id(crate::config::APP_ID)
            .build();
        let window = libadwaita::ApplicationWindow::new(&application);

        restore(&window, settings.get());

        assert_eq!(window.default_width(), 1024);
        assert_eq!(window.default_height(), 640);
        assert!(!window.is_maximized());
    }

    #[gtk4::test]
    fn persist_round_trips_through_settings() {
        let settings = MemorySettings::new();
        let application = libadwaita::Application::builder()
            .application_id(crate::config::APP_ID)
            .build();
        let window = libadwaita::ApplicationWindow::new(&application);
        window.set_default_size(1440, 900);

        persist(&window, settings.get());

        let stored = settings.get().window_geometry();
        assert_eq!(stored.width, 1440);
        assert_eq!(stored.height, 900);
        assert!(!stored.maximized);
    }
}
