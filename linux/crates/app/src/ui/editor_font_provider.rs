use std::cell::RefCell;

use gtk4::glib::translate::IntoGlib;
use gtk4::pango;
use tablepro_linux_platform::{AppSettings, EditorFont};

thread_local! {
    static PROVIDER: RefCell<Option<(gtk4::CssProvider, String)>> = const { RefCell::new(None) };
    static GRID_PROVIDER: RefCell<Option<(gtk4::CssProvider, String)>> = const { RefCell::new(None) };
}

/// The data grid's cells take the font the user picked for them. Libadwaita's
/// `monospace` class sets their family, so the rule names that class.
pub(crate) fn apply_grid(settings: &AppSettings) {
    let font = match settings.grid_font() {
        EditorFont::Custom(description) => Some(pango::FontDescription::from_string(&description)),
        EditorFont::System => None,
    };
    install(
        &GRID_PROVIDER,
        font.map(|font| font_css("columnview.data-table .monospace", &font)),
    );
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
    let css = match settings.editor_font() {
        EditorFont::Custom(description) => Some(font_css(
            EDITOR_SELECTOR,
            &pango::FontDescription::from_string(&description),
        )),
        EditorFont::System => None,
    };
    install(&PROVIDER, css);
}

fn install(slot: &'static std::thread::LocalKey<RefCell<Option<(gtk4::CssProvider, String)>>>, css: Option<String>) {
    let Some(display) = gtk4::gdk::Display::default() else {
        return;
    };
    slot.with(|cell| {
        if let Some((previous, _)) = cell.borrow_mut().take() {
            gtk4::style_context_remove_provider_for_display(&display, &previous);
        }
        let Some(css) = css else {
            return;
        };
        let provider = gtk4::CssProvider::new();
        provider.load_from_string(&css);
        gtk4::style_context_add_provider_for_display(&display, &provider, gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION);
        *cell.borrow_mut() = Some((provider, css));
    });
}

const EDITOR_SELECTOR: &str = "textview.sql-editor, textview.sql-editor text";

#[cfg(test)]
fn editor_font_css(font: &pango::FontDescription) -> String {
    font_css(EDITOR_SELECTOR, font)
}

fn font_css(selector: &str, font: &pango::FontDescription) -> String {
    let mut declarations = Vec::new();
    if let Some(family) = font.family() {
        declarations.push(format!("font-family: \"{}\";", escape_css_string(&family)));
    }
    let size = font.size();
    if size > 0 {
        let unit = if font.is_size_absolute() { "px" } else { "pt" };
        declarations.push(format!(
            "font-size: {}{unit};",
            f64::from(size) / f64::from(pango::SCALE)
        ));
    }
    if font.weight() != pango::Weight::Normal {
        declarations.push(format!("font-weight: {};", font.weight().into_glib()));
    }
    match font.style() {
        pango::Style::Italic => declarations.push("font-style: italic;".to_owned()),
        pango::Style::Oblique => declarations.push("font-style: oblique;".to_owned()),
        _ => {}
    }
    format!("{selector} {{ {} }}", declarations.join(" "))
}

/// A family name reaches CSS inside double quotes, so a quote or a
/// backslash in it would end the string early.
fn escape_css_string(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

#[cfg(test)]
mod tests {
    use tablepro_linux_platform::EditorFont;

    use crate::test_support::MemorySettings;

    use super::*;

    #[gtk4::test]
    fn system_font_installs_no_provider() {
        let settings = MemorySettings::new();

        apply(settings.get());

        assert_eq!(installed_css(), None);
    }

    #[gtk4::test]
    fn grid_font_styles_cells_only_when_custom() {
        let settings = MemorySettings::new();
        let installed = || GRID_PROVIDER.with(|cell| cell.borrow().as_ref().map(|(_, css)| css.clone()));

        apply_grid(settings.get());
        assert_eq!(installed(), None);

        settings
            .get()
            .set_grid_font(&EditorFont::Custom("Fira Code 11".to_owned()))
            .expect("store the custom font");
        apply_grid(settings.get());
        let css = installed().expect("a rule for the cells");
        assert!(css.starts_with("columnview.data-table .monospace"), "{css}");
        assert!(css.contains("Fira Code"), "{css}");
        assert_eq!(installed_css(), None, "the editor keeps its own font");

        settings
            .get()
            .set_grid_font(&EditorFont::System)
            .expect("back to the system font");
        apply_grid(settings.get());
        assert_eq!(installed(), None);
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
    fn editor_font_css_keeps_a_fractional_size() {
        let css = editor_font_css(&pango::FontDescription::from_string("Monospace 10.5"));

        assert!(css.contains("font-size: 10.5pt;"), "{css}");
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
