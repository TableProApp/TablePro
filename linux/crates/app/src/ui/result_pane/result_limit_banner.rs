use libadwaita as adw;

use super::ResultSummary;
use crate::i18n::gettext;

/// The banner over a result the run's row limit cut short, saying how
/// much of it the grid holds and offering every row as a file.
#[derive(Debug, Clone)]
pub(crate) struct ResultLimitBanner {
    banner: adw::Banner,
}

impl ResultLimitBanner {
    pub(crate) fn new(summary: &ResultSummary) -> Self {
        let banner = adw::Banner::new("");
        // The title holds the locale's digit grouping, which is not
        // markup.
        banner.set_use_markup(false);
        banner.set_button_label(Some(&gettext("Export All…")));
        match summary.limit_title() {
            Some(title) => {
                banner.set_title(&title);
                banner.set_revealed(true);
            }
            None => banner.set_revealed(false),
        }
        Self { banner }
    }

    pub(crate) fn connect_export_all(&self, export_all: impl Fn() + 'static) {
        self.banner.connect_button_clicked(move |_| export_all());
    }

    pub(crate) fn widget(&self) -> &adw::Banner {
        &self.banner
    }
}
