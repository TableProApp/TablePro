use std::cell::RefCell;

use gtk4::glib::translate::IntoGlib;
use gtk4::pango;
use tablepro_storage::{AppSettings, EditorFont};

thread_local! {
    static PROVIDER: RefCell<Option<(gtk4::CssProvider, String)>> = const { RefCell::new(None) };
}

/// The CSS the display currently carries for the editor, or `None` when
/// the system font is selected and no rule is installed.
#[cfg(test)]
pub(crate) fn installed_css() -> Option<String> {
    PROVIDER.with(|cell| cell.borrow().as_ref().map(|(_, css)| css.clone()))
}

/// GTK 4.10 removed the per-widget CSS provider, so the editor font is a
/// display-scoped rule on `textview.sql-editor`. With the system font
/// selected there is no rule at all: `style.css` already points the class
/// at libadwaita's monospace variables.
pub(crate) fn apply(settings: &AppSettings) {
    let Some(display) = gtk4::gdk::Display::default() else {
        return;
    };
    PROVIDER.with(|cell| {
        if let Some((previous, _)) = cell.borrow_mut().take() {
            gtk4::style_context_remove_provider_for_display(&display, &previous);
        }
        let EditorFont::Custom(description) = settings.editor_font() else {
            return;
        };
        let css = editor_font_css(&pango::FontDescription::from_string(&description));
        let provider = gtk4::CssProvider::new();
        provider.load_from_string(&css);
        gtk4::style_context_add_provider_for_display(&display, &provider, gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION);
        *cell.borrow_mut() = Some((provider, css));
    });
}

fn editor_font_css(font: &pango::FontDescription) -> String {
    let mut declarations = Vec::new();
    if let Some(family) = font.family() {
        declarations.push(format!("font-family: \"{}\";", escape_css_string(&family)));
    }
    let size = font.size();
    if size > 0 {
        let unit = if font.is_size_absolute() { "px" } else { "pt" };
        declarations.push(format!("font-size: {}{unit};", size / pango::SCALE));
    }
    if font.weight() != pango::Weight::Normal {
        declarations.push(format!("font-weight: {};", font.weight().into_glib()));
    }
    match font.style() {
        pango::Style::Italic => declarations.push("font-style: italic;".to_owned()),
        pango::Style::Oblique => declarations.push("font-style: oblique;".to_owned()),
        _ => {}
    }
    format!(
        "textview.sql-editor, textview.sql-editor text {{ {} }}",
        declarations.join(" ")
    )
}

/// A family name reaches CSS inside double quotes, so a quote or a
/// backslash in it would end the string early.
fn escape_css_string(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

#[cfg(test)]
mod tests {
    use tablepro_storage::EditorFont;

    use crate::test_support::MemorySettings;

    use super::*;

    #[gtk4::test]
    fn system_font_installs_no_provider() {
        let settings = MemorySettings::new();

        apply(settings.get());

        assert_eq!(installed_css(), None);
    }

    #[gtk4::test]
    fn custom_font_change_updates_css() {
        let settings = MemorySettings::new();
        settings
            .get()
            .set_editor_font(&EditorFont::Custom("Fira Code 13".to_owned()))
            .expect("store the custom font");

        apply(settings.get());
        let first = installed_css().expect("a provider for the custom font");

        settings
            .get()
            .set_editor_font(&EditorFont::Custom("Monospace 9".to_owned()))
            .expect("store the second font");
        apply(settings.get());
        let second = installed_css().expect("a provider for the second font");

        assert!(first.contains("Fira Code") && first.contains("13pt"), "{first}");
        assert!(second.contains("Monospace") && second.contains("9pt"), "{second}");
    }

    #[test]
    fn editor_font_css_quotes_and_escapes_the_family() {
        let css = editor_font_css(&pango::FontDescription::from_string("Fira Code 13"));

        assert!(css.contains("font-family: \"Fira Code\";"), "{css}");
        assert!(css.contains("font-size: 13pt;"), "{css}");
        assert!(css.starts_with("textview.sql-editor, textview.sql-editor text {"));
    }

    #[test]
    fn editor_font_css_escapes_quotes_and_backslashes() {
        let mut font = pango::FontDescription::new();
        font.set_family("Ev\"il\\Font");

        let css = editor_font_css(&font);

        assert!(css.contains("font-family: \"Ev\\\"il\\\\Font\";"), "{css}");
    }

    #[test]
    fn editor_font_css_uses_px_for_an_absolute_size() {
        let mut font = pango::FontDescription::from_string("Monospace");
        font.set_absolute_size(f64::from(16 * pango::SCALE));

        let css = editor_font_css(&font);

        assert!(css.contains("font-size: 16px;"), "{css}");
    }

    #[test]
    fn editor_font_css_carries_weight_and_style() {
        let css = editor_font_css(&pango::FontDescription::from_string("Monospace Bold Italic 11"));

        assert!(css.contains("font-weight: 700;"), "{css}");
        assert!(css.contains("font-style: italic;"), "{css}");
    }
}
