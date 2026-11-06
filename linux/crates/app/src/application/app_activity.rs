use std::time::{Duration, Instant};

use gtk4 as gtk;
use gtk4::gio;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;

use super::TableProApplication;

// Focus moving between TablePro's own windows leaves none active for a moment; a trip to the portal takes longer.
const RETURN_AFTER: Duration = Duration::from_secs(1);

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub(super) struct Activity {
    away_since: Option<Instant>,
}

impl Activity {
    // True when the app comes back from elsewhere.
    fn changed(&mut self, any_window_active: bool, now: Instant) -> bool {
        match (any_window_active, self.away_since) {
            (false, None) => {
                self.away_since = Some(now);
                false
            }
            (true, Some(since)) => {
                self.away_since = None;
                now.duration_since(since) >= RETURN_AFTER
            }
            (false, Some(_)) | (true, None) => false,
        }
    }
}

impl TableProApplication {
    // Every toplevel, since a window GTK does not add to the application, like the file chooser's fallback, holds the focus too.
    pub(super) fn follow_activity(&self) {
        let toplevels = gtk::Window::toplevels();
        self.follow_windows(&toplevels, 0, toplevels.n_items());
        let app = self.downgrade();
        toplevels.connect_items_changed(move |toplevels, position, _, added| {
            if let Some(app) = app.upgrade() {
                app.follow_windows(toplevels, position, added);
            }
        });
    }

    fn follow_windows(&self, toplevels: &gio::ListModel, position: u32, count: u32) {
        let windows =
            (position..position + count).filter_map(|index| toplevels.item(index).and_downcast::<gtk::Window>());
        for window in windows {
            let app = self.downgrade();
            window.connect_is_active_notify(move |_| {
                if let Some(app) = app.upgrade() {
                    app.activity_changed();
                }
            });
        }
    }

    fn activity_changed(&self) {
        let any_window_active = gtk::Window::list_toplevels()
            .iter()
            .filter_map(|widget| widget.downcast_ref::<gtk::Window>())
            .any(GtkWindowExt::is_active);
        let imp = self.imp();
        let mut activity = imp.activity.get();
        let back = activity.changed(any_window_active, Instant::now());
        imp.activity.set(activity);
        if back && let Some(services) = imp.services.get() {
            services.app_became_active();
        }
        if any_window_active {
            self.window_activated();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn moved(activity: &mut Activity, steps: &[(bool, Duration)], start: Instant) -> Vec<bool> {
        steps
            .iter()
            .map(|&(active, at)| activity.changed(active, start + at))
            .collect()
    }

    #[test]
    fn coming_back_from_elsewhere_counts_once() {
        let start = Instant::now();
        let mut activity = Activity::default();

        let returns = moved(
            &mut activity,
            &[
                (true, Duration::ZERO),
                (false, Duration::from_secs(1)),
                (false, Duration::from_secs(2)),
                (true, Duration::from_secs(30)),
                (true, Duration::from_secs(31)),
            ],
            start,
        );

        assert_eq!(returns, [false, false, false, true, false]);
    }

    #[test]
    fn the_first_window_at_launch_is_no_return() {
        let mut activity = Activity::default();

        assert!(!activity.changed(true, Instant::now()));
    }

    #[test]
    fn focus_moving_between_the_apps_windows_is_no_return() {
        let start = Instant::now();
        let mut activity = Activity::default();

        let returns = moved(
            &mut activity,
            &[
                (false, Duration::ZERO),
                (true, Duration::from_millis(40)),
                (false, Duration::from_secs(5)),
                (true, Duration::from_secs(5) + RETURN_AFTER - Duration::from_millis(1)),
            ],
            start,
        );

        assert_eq!(returns, [false, false, false, false]);
    }
}
