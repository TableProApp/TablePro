use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;

use super::{TableProApplication, WindowHost, WindowLaunch};

/// The application keeps every window's controller, so a window that
/// held it strongly would keep it alive past its own shutdown.
#[derive(Debug)]
pub struct AppWindowHost {
    app: glib::WeakRef<TableProApplication>,
}

impl AppWindowHost {
    pub fn new(app: &TableProApplication) -> Self {
        Self { app: app.downgrade() }
    }
}

impl WindowHost for AppWindowHost {
    fn present_window(&self, window_id: u32) -> bool {
        self.app.upgrade().is_some_and(|app| app.present_window(window_id))
    }

    fn open_window(&self, launch: WindowLaunch) {
        if let Some(app) = self.app.upgrade() {
            app.open_window(launch);
        }
    }

    fn application(&self) -> Option<gtk::Application> {
        self.app.upgrade().map(|app| app.upcast())
    }
}
