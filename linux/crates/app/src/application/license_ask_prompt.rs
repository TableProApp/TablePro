use std::time::Instant;

use chrono::Local;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita::prelude::*;

use super::TableProApplication;
use crate::services::license_ask::{LAUNCH_QUIET_PERIOD, LicenseAsk, day_stamp, is_quiet_moment};
use crate::ui::{LaunchNotice, SessionWindow};

// The query goes before the fragment, where the site reads it; app-ask is the referrer macOS's ask sends.
pub(super) const PRICING: &str = "https://tablepro.app/?ref=app-ask#pricing";

impl TableProApplication {
    // From the primary instance's startup: the day counts, and the ask waits out the launch.
    pub(super) fn start_license_ask(&self) {
        let imp = self.imp();
        if imp.launched_at.get().is_some() {
            return;
        }
        imp.launched_at.set(Some(Instant::now()));
        self.record_usage_day();
        let app = self.downgrade();
        glib::timeout_add_local_once(LAUNCH_QUIET_PERIOD, move || {
            if let Some(app) = app.upgrade() {
                app.ask_for_license_if_due();
            }
        });
    }

    // Each time one of the windows takes the focus, which happens soon after any moment the ask could use.
    pub(super) fn window_activated(&self) {
        if self.imp().launched_at.get().is_none() {
            return;
        }
        self.record_usage_day();
        self.ask_for_license_if_due();
    }

    fn record_usage_day(&self) {
        let Some(services) = self.imp().services.get() else {
            return;
        };
        if let Err(error) = services
            .settings
            .record_usage_day(&day_stamp(Local::now().date_naive()))
        {
            tracing::warn!(%error, "the day of use was not counted");
        }
    }

    // A toast, not a dialog: GNOME's guidelines never let a dialog open unless the user asked for one.
    fn ask_for_license_if_due(&self) {
        let imp = self.imp();
        let (Some(services), Some(launched)) = (imp.services.get(), imp.launched_at.get()) else {
            return;
        };
        let today = Local::now().date_naive();
        let ask = LicenseAsk::read(&services.settings, services.account().has_license());
        if !ask.is_due(today) {
            return;
        }
        // Only a window someone works in, with nothing presented over it.
        let Some(window) = self.active_window().and_downcast::<SessionWindow>() else {
            return;
        };
        if !window.is_active() || window.visible_dialog().is_some() {
            return;
        }
        if !is_quiet_moment(launched.elapsed(), any_tab_loading(window.upcast_ref())) {
            return;
        }
        // Recorded as it shows, so quitting while it shows still counts as an ask.
        if let Err(error) = services.settings.set_license_asked(&day_stamp(today)) {
            tracing::warn!(%error, "the license ask was not recorded, so it is not shown");
            return;
        }
        tracing::info!(days = ask.usage_days, "asking about a license");
        services.telemetry().support_ask_shown();
        window.announce(LaunchNotice::LicenseAsk(ask.usage_days));
    }
}

// A running query or a page still loading shows as its tab's spinner; the ask never lands on one.
fn any_tab_loading(root: &gtk4::Widget) -> bool {
    let mut pending = vec![root.clone()];
    while let Some(widget) = pending.pop() {
        if let Some(view) = widget.downcast_ref::<libadwaita::TabView>() {
            let pages = view.pages();
            let loading = (0..pages.n_items())
                .filter_map(|index| pages.item(index).and_downcast::<libadwaita::TabPage>())
                .any(|page| page.is_loading());
            if loading {
                return true;
            }
        }
        let mut child = widget.first_child();
        while let Some(next) = child {
            child = next.next_sibling();
            pending.push(next);
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[gtk4::test]
    fn a_loading_tab_anywhere_in_the_window_counts() {
        let view = libadwaita::TabView::new();
        let page = view.append(&gtk4::Label::new(Some("tab")));
        let outer = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
        let inner = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
        inner.append(&view);
        outer.append(&inner);

        let idle = any_tab_loading(outer.upcast_ref());
        page.set_loading(true);

        assert!(!idle);
        assert!(any_tab_loading(outer.upcast_ref()));
    }
}
