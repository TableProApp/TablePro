use std::path::PathBuf;

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;

use super::TableProApplication;
use crate::ui::SessionWindow;

impl TableProApplication {
    /// Looks off the GTK thread for a report the last run left when it
    /// crashed, and has a window say so.
    pub(super) fn look_for_crash_report(&self) {
        let Some(services) = self.services() else {
            return;
        };
        let dir = services.storage.paths().crashes_dir();
        let looking = services
            .tasks
            .spawn_blocking_task(move || crate::crash_report::take_unannounced(&dir));
        let app = self.downgrade();
        glib::spawn_future_local(async move {
            let report = match looking.await {
                Ok(Ok(Some(report))) => report,
                Ok(Ok(None)) => return,
                Ok(Err(error)) => {
                    tracing::warn!(%error, "could not look for a crash report");
                    return;
                }
                Err(failure) => {
                    tracing::warn!(%failure, "the crash report lookup failed");
                    return;
                }
            };
            if let Some(app) = app.upgrade() {
                app.announce_crash(report);
            }
        });
    }

    /// The window in front says it, or the first one to open when the
    /// windows of a restored session are still on their way.
    fn announce_crash(&self, report: PathBuf) {
        match self.front_session_window() {
            Some(window) => window.announce_crash(report),
            None => {
                self.imp().crash_report.replace(Some(report));
            }
        }
    }

    pub(super) fn hand_over_crash_report(&self, window: &SessionWindow) {
        if let Some(report) = self.imp().crash_report.take() {
            window.announce_crash(report);
        }
    }
}
