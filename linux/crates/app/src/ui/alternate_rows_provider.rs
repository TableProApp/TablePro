use std::cell::RefCell;

use tablepro_storage::AppSettings;

/// Shades the cells `data_grid::stripes` marks. Not on the row: GTK draws
/// a selected or hovered row beneath its cells, so the shade stays off a
/// selected row and lets the hover show through.
const CSS: &str = "columnview.data-table > listview > row:not(:selected) > cell.tp-stripe { \
background-color: color-mix(in srgb, currentColor 4%, transparent); }";

thread_local! {
    static PROVIDER: RefCell<Option<gtk4::CssProvider>> = const { RefCell::new(None) };
}

#[cfg(test)]
pub(crate) fn installed() -> bool {
    PROVIDER.with(|cell| cell.borrow().is_some())
}

/// A display-scoped rule, as with the editor font, so one setting reaches
/// every grid of every window without each grid watching it.
pub(crate) fn apply(settings: &AppSettings) {
    let Some(display) = gtk4::gdk::Display::default() else {
        return;
    };
    PROVIDER.with(|cell| {
        if let Some(previous) = cell.borrow_mut().take() {
            gtk4::style_context_remove_provider_for_display(&display, &previous);
        }
        if !settings.show_alternate_rows() {
            return;
        }
        let provider = gtk4::CssProvider::new();
        provider.load_from_string(CSS);
        gtk4::style_context_add_provider_for_display(&display, &provider, gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION);
        *cell.borrow_mut() = Some(provider);
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::MemorySettings;

    #[gtk4::test]
    fn the_stripes_follow_the_setting() {
        let settings = MemorySettings::new();

        apply(settings.get());
        assert!(installed(), "stripes are on by default, as on macOS");

        settings.get().set_show_alternate_rows(false).expect("store the flag");
        apply(settings.get());
        assert!(!installed());
    }
}
