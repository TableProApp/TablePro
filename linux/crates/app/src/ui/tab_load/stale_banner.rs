use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;

use super::LoadFailure;

/// The banner over content a tab could not read again. Its title is the
/// tab's own, from its template; the failure goes in the tooltip, so the
/// banner stays one line.
pub(crate) struct StaleBanner {
    banner: adw::Banner,
}

impl StaleBanner {
    pub(crate) fn new(banner: adw::Banner, retry: impl Fn() + 'static) -> Self {
        banner.set_use_markup(false);
        banner.set_button_label(Some(&crate::i18n::gettext("Retry")));
        banner.connect_button_clicked(move |_| retry());
        Self { banner }
    }

    pub(crate) fn show(&self, stale: Option<&LoadFailure>) {
        let message = stale.map(LoadFailure::message);
        self.banner.set_tooltip_text(message.as_deref());
        self.banner
            .upcast_ref::<gtk::Widget>()
            .update_property(&[gtk::accessible::Property::Description(message.as_deref().unwrap_or(""))]);
        self.banner.set_revealed(stale.is_some());
    }
}
