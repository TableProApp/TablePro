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

    /// A new failure is said, with its reason: the focus stays in the
    /// content, and the banner's reason shows only on hover.
    pub(crate) fn show(&self, stale: Option<&LoadFailure>) {
        let message = stale.map(LoadFailure::message);
        let news = message.is_some()
            && (!self.banner.is_revealed() || self.banner.tooltip_text().as_deref() != message.as_deref());
        self.banner.set_tooltip_text(message.as_deref());
        self.banner
            .upcast_ref::<gtk::Widget>()
            .update_property(&[gtk::accessible::Property::Description(message.as_deref().unwrap_or(""))]);
        self.banner.set_revealed(stale.is_some());
        if let Some(message) = message.filter(|_| news) {
            crate::ui::a11y::announce(
                &self.banner,
                &format!("{} {message}", self.banner.title()),
                gtk::AccessibleAnnouncementPriority::High,
            );
        }
    }
}
