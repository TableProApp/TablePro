use std::cmp::Ordering;

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use semver::Version;

use super::TableProApplication;
use super::about_dialog::{has_release_notes, release_notes_version};
use crate::config;
use crate::ui::{LaunchNotice, SessionWindow};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Launch {
    First,
    Again,
    Update,
    Downgrade,
}

// No release writes a version semver cannot read, so one counts as none.
fn launch_after(previous: &str, current: &Version) -> Launch {
    match Version::parse(previous).map(|previous| previous.cmp(current)) {
        Err(_) => Launch::First,
        Ok(Ordering::Less) => Launch::Update,
        Ok(Ordering::Equal) => Launch::Again,
        Ok(Ordering::Greater) => Launch::Downgrade,
    }
}

impl TableProApplication {
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
                app.announce(LaunchNotice::Crash(report));
            }
        });
    }

    // A development build has no release of its own, so it never marks one as seen.
    pub(super) fn note_launch_version(&self) {
        if let Some(version) = release_notes_version(config::profile()) {
            self.note_launch_of(version);
        }
    }

    pub(super) fn note_launch_of(&self, version: &str) {
        let Some(services) = self.services() else {
            return;
        };
        let current = match Version::parse(version) {
            Ok(current) => current,
            Err(error) => {
                tracing::warn!(%error, version, "the running version is not a release version");
                return;
            }
        };
        let launch = launch_after(&services.settings.last_seen_version(), &current);
        // An older build never writes over what a newer one stored (docs/releasing.md, Downgrades).
        if matches!(launch, Launch::Again | Launch::Downgrade) {
            return;
        }
        // Unrecorded, the toast would come back at every launch.
        if let Err(error) = services.settings.set_last_seen_version(version) {
            tracing::warn!(%error, "could not record the running version");
            return;
        }
        if launch == Launch::Update && has_release_notes(version) {
            self.announce(LaunchNotice::Update(version.to_owned()));
        }
    }

    // The windows of a restored session may still be on their way, so the first one to open says it.
    fn announce(&self, notice: LaunchNotice) {
        match self.front_session_window() {
            Some(window) => window.announce(notice),
            None => self.imp().launch_notices.borrow_mut().push(notice),
        }
    }

    pub(super) fn hand_over_launch_notices(&self, window: &SessionWindow) {
        for notice in self.imp().launch_notices.take() {
            window.announce(notice);
        }
    }

    fn front_session_window(&self) -> Option<SessionWindow> {
        self.active_window().and_downcast::<SessionWindow>().or_else(|| {
            self.windows()
                .into_iter()
                .find_map(|window| window.downcast::<SessionWindow>().ok())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn launch(previous: &str, current: &str) -> Launch {
        launch_after(previous, &Version::parse(current).expect("a release version"))
    }

    #[test]
    fn only_a_launch_after_an_older_release_is_an_update() {
        assert_eq!(launch("0.1.0", "0.2.0"), Launch::Update);
        assert_eq!(launch("0.9.0", "0.10.0"), Launch::Update, "not compared as text");
        assert_eq!(launch("0.2.0-rc.1", "0.2.0"), Launch::Update);
        assert_eq!(launch("0.2.0", "0.2.0"), Launch::Again);
        assert_eq!(launch("0.3.0", "0.2.0"), Launch::Downgrade);
        assert_eq!(launch("0.2.0", "0.2.0-rc.1"), Launch::Downgrade);
        assert_eq!(launch("", "0.2.0"), Launch::First);
        assert_eq!(launch("not a version", "0.2.0"), Launch::First);
    }
}
