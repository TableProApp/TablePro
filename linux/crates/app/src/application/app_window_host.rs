use gtk4::glib;
use gtk4::prelude::*;
use tablepro_session::SessionKey;

use super::{TableProApplication, WindowHost};

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
    fn present_session(&self, window_id: u32, key: &SessionKey) -> bool {
        self.app
            .upgrade()
            .is_some_and(|app| app.present_session(window_id, key))
    }
}
