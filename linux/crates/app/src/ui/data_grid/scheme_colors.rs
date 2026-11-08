//! The data grid draws in the colours of the editor's style scheme, as the
//! macOS grid takes its theme's colours: the scheme's background and text,
//! and its selection. The default scheme, Adwaita, leaves the grid in the
//! window's own colours, which it already matches.

use std::cell::RefCell;
use std::rc::Rc;

use gtk4::gdk;
use gtk4::prelude::*;
use tablepro_linux_platform::AppSettings;
use tablepro_linux_platform::settings::keys;

/// The colours a scheme gives the grid. Each is a CSS colour the scheme
/// names, or none where it says nothing.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub(super) struct SchemeColors {
    pub background: Option<String>,
    pub text: Option<String>,
    pub selection_background: Option<String>,
    pub selection_text: Option<String>,
}

/// The rules for `colors`, empty when the scheme says nothing.
pub(super) fn css(colors: &SchemeColors) -> String {
    let mut rules = String::new();
    if colors.background.is_some() || colors.text.is_some() {
        rules.push_str("columnview.data-table, columnview.data-table > listview {\n");
        if let Some(background) = &colors.background {
            rules.push_str(&format!("  background-color: {background};\n"));
        }
        if let Some(text) = &colors.text {
            rules.push_str(&format!("  color: {text};\n"));
        }
        rules.push_str("}\n");
    }
    if colors.selection_background.is_some() || colors.selection_text.is_some() {
        rules.push_str("columnview.data-table > listview > row:selected {\n");
        if let Some(background) = &colors.selection_background {
            rules.push_str(&format!("  background-color: {background};\n"));
        }
        if let Some(text) = &colors.selection_text {
            rules.push_str(&format!("  color: {text};\n"));
        }
        rules.push_str("}\n");
    }
    rules
}

fn colors_of(scheme: &sourceview5::StyleScheme) -> SchemeColors {
    let style = |name: &str| scheme.style(name);
    let background = |name: &str| {
        style(name)
            .filter(|style| style.is_background_set())
            .and_then(|style| style.background())
            .map(|color| color.to_string())
    };
    let foreground = |name: &str| {
        style(name)
            .filter(|style| style.is_foreground_set())
            .and_then(|style| style.foreground())
            .map(|color| color.to_string())
    };
    SchemeColors {
        background: background("text"),
        text: foreground("text"),
        selection_background: background("selection"),
        selection_text: foreground("selection"),
    }
}

/// The CSS for the scheme `preferred` names in the desktop's style.
fn css_for(preferred: &str) -> String {
    if preferred == "Adwaita" {
        return String::new();
    }
    crate::ui::style_scheme_resolver::scheme(preferred)
        .map(|scheme| css(&colors_of(&scheme)))
        .unwrap_or_default()
}

thread_local! {
    static PROVIDER: RefCell<Option<gtk4::CssProvider>> = const { RefCell::new(None) };
}

/// Make the grids follow the scheme `settings` names, now and when it or
/// the desktop's light or dark style changes. Once per process.
pub(super) fn follow(settings: &Rc<AppSettings>) {
    if PROVIDER.with(|provider| provider.borrow().is_some()) {
        return;
    }
    let Some(display) = gdk::Display::default() else {
        return;
    };
    let provider = gtk4::CssProvider::new();
    // Above the app's own sheet, which sets the same selectors' colours.
    gtk4::style_context_add_provider_for_display(&display, &provider, gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
    PROVIDER.with(|slot| slot.replace(Some(provider.clone())));
    let refresh = {
        let (settings, provider) = (settings.clone(), provider.clone());
        move || provider.load_from_string(&css_for(&settings.style_scheme()))
    };
    refresh();
    // Connected before any read, so GSettings reports the key's changes.
    let again = refresh.clone();
    settings
        .gio()
        .connect_changed(Some(keys::STYLE_SCHEME), move |_, _| again());
    let style = libadwaita::StyleManager::default();
    let again = refresh;
    style.connect_dark_notify(move |_| again());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_scheme_gives_the_grid_its_background_text_and_selection() {
        let colors = SchemeColors {
            background: Some("#1e1e1e".to_owned()),
            text: Some("#d4d4d4".to_owned()),
            selection_background: Some("#264f78".to_owned()),
            selection_text: None,
        };

        let rules = css(&colors);

        assert!(rules.contains("background-color: #1e1e1e;"));
        assert!(rules.contains("color: #d4d4d4;"));
        assert!(rules.contains("row:selected {\n  background-color: #264f78;"));
        assert!(!rules.contains("row:selected {\n  background-color: #264f78;\n  color"));
    }

    #[test]
    fn a_scheme_that_says_nothing_leaves_the_grid_as_it_is() {
        assert_eq!(css(&SchemeColors::default()), "");
    }

    #[gtk4::test]
    fn the_default_scheme_changes_nothing_and_another_takes_the_grid() {
        libadwaita::init().expect("libadwaita initialises under the test backend");
        assert_eq!(css_for("Adwaita"), "");

        let rules = css_for("Adwaita-dark");

        assert!(
            rules.contains("columnview.data-table"),
            "no rules for a dark scheme: {rules:?}"
        );
    }
}
