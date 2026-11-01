use std::cell::RefCell;
use std::rc::{Rc, Weak};

use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use sourceview5::prelude::*;
use tablepro_storage::AppSettings;

use crate::ui::clipboard::ClipboardPayload;
use crate::ui::format::{format_thousands, plural_count};
use crate::ui::handler_guard::HandlerGuard;

const FALLBACK_SCHEME: &str = "Adwaita";

/// Read-only text in a source view, with Copy. What it shows may be cut
/// short, since the view lays out every character it holds; Copy always
/// takes `copied`.
pub(crate) struct SourceText {
    pub(crate) title: String,
    /// A GtkSourceView language id, such as `sql`.
    pub(crate) language: &'static str,
    /// What a screen reader calls the text.
    pub(crate) label: String,
    pub(crate) shown: String,
    pub(crate) copied: ClipboardPayload,
    /// Each said in a banner over the text, such as that `shown` is cut
    /// short.
    pub(crate) notes: Vec<String>,
    pub(crate) size: (i32, i32),
}

/// The dialog, and its header for a caller's own buttons.
pub(crate) struct SourceDialog {
    pub(crate) dialog: adw::Dialog,
    pub(crate) header: adw::HeaderBar,
}

/// With `settings`, the text takes the SQL editor's scheme, following a
/// change of it or of the light or dark style while the dialog is open.
pub(crate) fn source_dialog(text: SourceText, settings: Option<&Rc<AppSettings>>) -> SourceDialog {
    let buffer = sourceview5::Buffer::new(None);
    if let Some(language) = sourceview5::LanguageManager::default().language(text.language) {
        buffer.set_language(Some(&language));
    }
    buffer.set_text(&text.shown);
    let guards = follow_scheme(&buffer, settings);
    let view = sourceview5::View::with_buffer(&buffer);
    view.set_editable(false);
    view.set_monospace(true);
    view.set_show_line_numbers(true);
    view.set_top_margin(8);
    view.set_left_margin(8);
    view.upcast_ref::<gtk::Widget>()
        .update_property(&[gtk::accessible::Property::Label(&text.label)]);
    let scrolled = gtk::ScrolledWindow::builder().child(&view).vexpand(true).build();
    let toasts = adw::ToastOverlay::new();
    toasts.set_child(Some(&scrolled));

    let copy_button = gtk::Button::from_icon_name(crate::ui::icons::EDIT_COPY);
    crate::ui::a11y::describe_icon_button(&copy_button, &crate::i18n::gettext("Copy"), None);
    let payload = text.copied;
    let shown_on = toasts.downgrade();
    copy_button.connect_clicked(move |button| {
        let shown_on = shown_on.clone();
        crate::ui::clipboard::copy_payload(button, payload.clone(), move |message| {
            if let Some(toasts) = shown_on.upgrade() {
                toasts.add_toast(crate::ui::plain_toast(message));
            }
        });
    });
    let header = adw::HeaderBar::new();
    header.pack_end(&copy_button);
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&header);
    for note in &text.notes {
        let banner = adw::Banner::new(note);
        banner.set_revealed(true);
        toolbar.add_top_bar(&banner);
    }
    toolbar.set_content(Some(&toasts));

    let dialog = adw::Dialog::builder()
        .title(text.title)
        .content_width(text.size.0)
        .content_height(text.size.1)
        .child(&toolbar)
        .build();
    let guards = RefCell::new(guards);
    let shown_in = view.downgrade();
    dialog.connect_closed(move |_| {
        guards.borrow_mut().clear();
        // GtkSourceView before 5.21 never frees a view that has drawn its
        // line numbers, so the closed dialog takes the text back.
        if let Some(view) = shown_in.upgrade() {
            view.set_buffer(Some(&sourceview5::Buffer::new(None)));
        }
    });
    SourceDialog { dialog, header }
}

fn follow_scheme(buffer: &sourceview5::Buffer, settings: Option<&Rc<AppSettings>>) -> Vec<HandlerGuard> {
    let paint = {
        let buffer = buffer.downgrade();
        let settings = settings.map(Rc::downgrade);
        Rc::new(move || {
            let Some(buffer) = buffer.upgrade() else {
                return;
            };
            let preferred = settings
                .as_ref()
                .and_then(Weak::upgrade)
                .map_or_else(|| FALLBACK_SCHEME.to_owned(), |settings| settings.style_scheme());
            buffer.set_style_scheme(crate::ui::style_scheme_resolver::scheme(&preferred).as_ref());
        })
    };
    paint();
    let style_manager = adw::StyleManager::default();
    let on_dark = {
        let paint = paint.clone();
        style_manager.connect_dark_notify(move |_| paint())
    };
    let mut guards = vec![HandlerGuard::new(&style_manager, on_dark)];
    if let Some(settings) = settings {
        let on_scheme = settings
            .gio()
            .connect_changed(Some(tablepro_storage::settings::keys::STYLE_SCHEME), move |_, _| {
                paint()
            });
        guards.push(HandlerGuard::new(settings.gio(), on_scheme));
    }
    guards
}

/// `text` cut at a character boundary after `chars` characters, saying
/// how much is left out, or `None` when it fits.
pub(crate) fn cut(text: &str, chars: usize) -> Option<String> {
    let (end, _) = text.char_indices().nth(chars)?;
    Some(format!("{}{}", &text[..end], more_bytes((text.len() - end) as u64)))
}

pub(crate) fn more_bytes(more: u64) -> String {
    crate::i18n::ngettext_f(
        "… ({count} more byte)",
        "… ({count} more bytes)",
        plural_count(more),
        &[("count", &format_thousands(more))],
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{MemorySettings, OwnedWindow, first_descendant_of_type};
    use crate::ui::clipboard::ClipboardFormat;

    fn text(shown: &str) -> SourceText {
        SourceText {
            title: "Definition".to_owned(),
            language: "sql",
            label: "Definition".to_owned(),
            shown: shown.to_owned(),
            copied: ClipboardPayload {
                text: shown.to_owned(),
                format: ClipboardFormat::Sql,
                rows: 1,
                skipped: 0,
                cells: None,
            },
            notes: Vec::new(),
            size: (640, 520),
        }
    }

    fn scheme_of(dialog: &adw::Dialog) -> Option<String> {
        let view = first_descendant_of_type::<sourceview5::View>(dialog)?;
        let buffer = view.buffer().downcast::<sourceview5::Buffer>().ok()?;
        buffer.style_scheme().map(|scheme| scheme.id().to_string())
    }

    #[gtk4::test]
    fn the_text_follows_the_light_or_dark_style_until_closed() {
        adw::init().expect("libadwaita initialises under the test backend");
        let window = OwnedWindow::presented(adw::Window::new());
        let style = adw::StyleManager::default();
        style.set_color_scheme(adw::ColorScheme::ForceLight);
        let shown = source_dialog(text("SELECT 1"), None);
        shown.dialog.present(Some(&*window));
        assert_eq!(scheme_of(&shown.dialog).as_deref(), Some("Adwaita"));

        style.set_color_scheme(adw::ColorScheme::ForceDark);
        assert_eq!(scheme_of(&shown.dialog).as_deref(), Some("Adwaita-dark"));

        shown.dialog.force_close();
        style.set_color_scheme(adw::ColorScheme::Default);
    }

    #[gtk4::test]
    fn the_text_takes_the_editor_scheme_and_follows_a_change_of_it() {
        adw::init().expect("libadwaita initialises under the test backend");
        let window = OwnedWindow::presented(adw::Window::new());
        adw::StyleManager::default().set_color_scheme(adw::ColorScheme::ForceLight);
        let settings = MemorySettings::new();
        let key = tablepro_storage::settings::keys::STYLE_SCHEME;
        settings.get().gio().set_string(key, "classic").expect("a writable key");
        let shown = source_dialog(text("SELECT 1"), Some(settings.get()));
        shown.dialog.present(Some(&*window));
        assert_eq!(scheme_of(&shown.dialog).as_deref(), Some("classic"));

        settings.get().gio().set_string(key, "Adwaita").expect("a writable key");
        assert_eq!(scheme_of(&shown.dialog).as_deref(), Some("Adwaita"));

        shown.dialog.force_close();
        adw::StyleManager::default().set_color_scheme(adw::ColorScheme::Default);
    }

    #[test]
    fn a_long_text_is_cut_saying_how_much_is_left() {
        assert_eq!(cut("short", 10), None);
        assert_eq!(cut("abcdef", 4).as_deref(), Some("abcd… (2 more bytes)"));
        assert_eq!(cut("ééé", 1).as_deref(), Some("é… (4 more bytes)"));
    }
}
