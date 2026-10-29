use gtk4::prelude::*;
use gtk4::subclass::prelude::*;

use super::TableProApplication;
use super::about_dialog::release_notes_version;
use crate::config;
use crate::ui::SessionWindow;

/// Whether this launch is the first of `current` after another version
/// ran. A first install has seen no other version, so it says nothing.
fn updated_since(previous: &str, current: &str) -> bool {
    !previous.is_empty() && previous != current
}

impl TableProApplication {
    /// Records the version that runs, and says so when it is new. A build
    /// whose metainfo has no release of its own records nothing, so a
    /// development run never marks a release as seen.
    pub(super) fn note_launch_version(&self) {
        let Some(services) = self.services() else {
            return;
        };
        let Some(current) = release_notes_version(config::profile()) else {
            return;
        };
        let previous = services.settings.last_seen_version();
        if previous == current {
            return;
        }
        if let Err(error) = services.settings.set_last_seen_version(current) {
            tracing::warn!(%error, "could not record the version that runs");
        }
        if updated_since(&previous, current) {
            self.announce_update(current.to_owned());
        }
    }

    /// The window in front says it, or the first one to open.
    fn announce_update(&self, version: String) {
        match self.front_session_window() {
            Some(window) => window.announce_update(&version),
            None => {
                self.imp().updated_to.replace(Some(version));
            }
        }
    }

    pub(super) fn hand_over_update(&self, window: &SessionWindow) {
        if let Some(version) = self.imp().updated_to.take() {
            window.announce_update(&version);
        }
    }

    /// The window in front, or the first one to open when the windows of
    /// a restored session are still on their way.
    pub(super) fn front_session_window(&self) -> Option<SessionWindow> {
        self.active_window().and_downcast::<SessionWindow>().or_else(|| {
            self.windows()
                .into_iter()
                .find_map(|window| window.downcast::<SessionWindow>().ok())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::updated_since;

    #[test]
    fn only_a_launch_after_another_version_is_an_update() {
        assert!(updated_since("0.1.0", "0.2.0"));
        assert!(!updated_since("", "0.2.0"), "a first install");
        assert!(!updated_since("0.2.0", "0.2.0"), "the same version again");
    }
}
