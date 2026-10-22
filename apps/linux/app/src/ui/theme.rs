use std::cell::{Cell, RefCell};

use relm4::adw;
use relm4::gtk;
use relm4::gtk::glib;
use sourceview5::prelude::*;

use crate::services::preferences::ThemePref;

struct Surface {
    window_bg: &'static str,
    window_fg: &'static str,
    view_bg: &'static str,
    chrome_bg: &'static str,
    card_bg: &'static str,
    accent_bg: &'static str,
    accent_fg: &'static str,
    accent_text: &'static str,
}

const LEDGER_DARK: Surface = Surface {
    window_bg: "#0e2421",
    window_fg: "#f3ead6",
    view_bg: "#0b1d1a",
    chrome_bg: "#163d38",
    card_bg: "#163d38",
    accent_bg: "#c9a24b",
    accent_fg: "#0e2421",
    accent_text: "#d9b866",
};

const LEDGER_LIGHT: Surface = Surface {
    window_bg: "#f3ead6",
    window_fg: "#163d38",
    view_bg: "#fbf7ec",
    chrome_bg: "#e9dfc6",
    card_bg: "#fbf7ec",
    accent_bg: "#1f4f48",
    accent_fg: "#fbf7ec",
    accent_text: "#1f4f48",
};

const CATPPUCCIN_DARK: Surface = Surface {
    window_bg: "#1e1e2e",
    window_fg: "#cdd6f4",
    view_bg: "#181825",
    chrome_bg: "#313244",
    card_bg: "#313244",
    accent_bg: "#cba6f7",
    accent_fg: "#1e1e2e",
    accent_text: "#cba6f7",
};

const CATPPUCCIN_LIGHT: Surface = Surface {
    window_bg: "#eff1f5",
    window_fg: "#4c4f69",
    view_bg: "#ffffff",
    chrome_bg: "#dce0e8",
    card_bg: "#ffffff",
    accent_bg: "#8839ef",
    accent_fg: "#eff1f5",
    accent_text: "#7028d6",
};

const TOKYO_DARK: Surface = Surface {
    window_bg: "#1a1b26",
    window_fg: "#c0caf5",
    view_bg: "#16161e",
    chrome_bg: "#292e42",
    card_bg: "#292e42",
    accent_bg: "#7aa2f7",
    accent_fg: "#16161e",
    accent_text: "#7aa2f7",
};

const TOKYO_LIGHT: Surface = Surface {
    window_bg: "#e1e2e7",
    window_fg: "#2c4a96",
    view_bg: "#f2f3f8",
    chrome_bg: "#d0d5e3",
    card_bg: "#f2f3f8",
    accent_bg: "#2e5cb8",
    accent_fg: "#ffffff",
    accent_text: "#244a96",
};

const GRUVBOX_DARK: Surface = Surface {
    window_bg: "#282828",
    window_fg: "#ebdbb2",
    view_bg: "#1d2021",
    chrome_bg: "#3c3836",
    card_bg: "#3c3836",
    accent_bg: "#d79921",
    accent_fg: "#1d2021",
    accent_text: "#fabd2f",
};

const GRUVBOX_LIGHT: Surface = Surface {
    window_bg: "#fbf1c7",
    window_fg: "#3c3836",
    view_bg: "#f9f5d7",
    chrome_bg: "#ebdbb2",
    card_bg: "#f9f5d7",
    accent_bg: "#85570a",
    accent_fg: "#fbf1c7",
    accent_text: "#85570a",
};

fn surface(theme: ThemePref, dark: bool) -> Option<&'static Surface> {
    Some(match (theme, dark) {
        (ThemePref::Default, _) => return None,
        (ThemePref::Ledger, true) => &LEDGER_DARK,
        (ThemePref::Ledger, false) => &LEDGER_LIGHT,
        (ThemePref::Catppuccin, true) => &CATPPUCCIN_DARK,
        (ThemePref::Catppuccin, false) => &CATPPUCCIN_LIGHT,
        (ThemePref::Tokyo, true) => &TOKYO_DARK,
        (ThemePref::Tokyo, false) => &TOKYO_LIGHT,
        (ThemePref::Gruvbox, true) => &GRUVBOX_DARK,
        (ThemePref::Gruvbox, false) => &GRUVBOX_LIGHT,
    })
}

fn css(surface: &Surface, variables: bool) -> String {
    let colors = [
        ("window_bg_color", surface.window_bg),
        ("window_fg_color", surface.window_fg),
        ("view_bg_color", surface.view_bg),
        ("view_fg_color", surface.window_fg),
        ("headerbar_bg_color", surface.chrome_bg),
        ("headerbar_fg_color", surface.window_fg),
        ("sidebar_bg_color", surface.chrome_bg),
        ("sidebar_fg_color", surface.window_fg),
        ("sidebar_backdrop_color", surface.chrome_bg),
        ("secondary_sidebar_bg_color", surface.chrome_bg),
        ("secondary_sidebar_fg_color", surface.window_fg),
        ("secondary_sidebar_backdrop_color", surface.chrome_bg),
        ("headerbar_backdrop_color", surface.chrome_bg),
        ("card_bg_color", surface.card_bg),
        ("card_fg_color", surface.window_fg),
        ("popover_bg_color", surface.card_bg),
        ("popover_fg_color", surface.window_fg),
        ("dialog_bg_color", surface.card_bg),
        ("dialog_fg_color", surface.window_fg),
        ("accent_bg_color", surface.accent_bg),
        ("accent_fg_color", surface.accent_fg),
        ("accent_color", surface.accent_text),
    ];
    let named: String = colors
        .iter()
        .map(|(name, value)| format!("@define-color {name} {value};\n"))
        .collect();
    if !variables {
        return named;
    }
    let variables: String = colors
        .iter()
        .map(|(name, value)| format!("  --{}: {value};\n", name.replace('_', "-")))
        .collect();
    format!("{named}:root {{\n{variables}}}\n")
}

fn scheme_id(theme: ThemePref, dark: bool) -> String {
    format!("bookie-{}-{}", theme.key(), if dark { "dark" } else { "light" })
}

fn scheme_xml(id: &str, dark: bool, s: &Surface) -> String {
    let parent = if dark { "Adwaita-dark" } else { "Adwaita" };
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<style-scheme id="{id}" name="{id}" version="1.0" parent-scheme="{parent}">
  <style name="text" foreground="{fg}" background="{view}"/>
  <style name="line-numbers" foreground="{fg}" background="{view}"/>
  <style name="current-line" background="{chrome}"/>
  <style name="current-line-number" background="{chrome}"/>
  <style name="selection" foreground="{accent_fg}" background="{accent_bg}"/>
  <style name="cursor" foreground="{accent}"/>
  <style name="def:keyword" foreground="{accent}" bold="true"/>
</style-scheme>
"#,
        fg = s.window_fg,
        view = s.view_bg,
        chrome = s.chrome_bg,
        accent_fg = s.accent_fg,
        accent_bg = s.accent_bg,
        accent = s.accent_text,
    )
}

fn install_editor_schemes() -> bool {
    let directory = glib::user_cache_dir()
        .join(crate::config::storage_dir_name())
        .join("styles");
    if let Err(error) = std::fs::create_dir_all(&directory) {
        tracing::warn!(%error, "editor colour schemes could not be installed");
        return false;
    }
    for theme in ThemePref::ALL {
        for dark in [true, false] {
            let Some(surface) = surface(theme, dark) else { continue };
            let id = scheme_id(theme, dark);
            if let Err(error) = std::fs::write(directory.join(format!("{id}.xml")), scheme_xml(&id, dark, surface)) {
                tracing::warn!(%error, "editor colour scheme could not be written");
                return false;
            }
        }
    }
    let manager = sourceview5::StyleSchemeManager::default();
    manager.append_search_path(&directory.to_string_lossy());
    manager.force_rescan();
    true
}

fn editor_scheme() -> Option<sourceview5::StyleScheme> {
    let dark = adw::StyleManager::default().is_dark();
    let manager = sourceview5::StyleSchemeManager::default();
    let themed = surface(CURRENT.get(), dark).and_then(|_| {
        SCHEMES_INSTALLED
            .with(|installed| *installed.get_or_init(install_editor_schemes))
            .then(|| manager.scheme(&scheme_id(CURRENT.get(), dark)))
            .flatten()
    });
    themed.or_else(|| manager.scheme(if dark { "Adwaita-dark" } else { "Adwaita" }))
}

pub fn style_editor(view: &sourceview5::View) {
    EDITORS.with(|editors| {
        let mut editors = editors.borrow_mut();
        editors.retain(|weak| weak.upgrade().is_some());
        if !editors.iter().any(|weak| weak.upgrade().as_ref() == Some(view)) {
            editors.push(view.downgrade());
        }
    });
    set_scheme(view, editor_scheme().as_ref());
}

fn set_scheme(view: &sourceview5::View, scheme: Option<&sourceview5::StyleScheme>) {
    if let (Some(scheme), Ok(buffer)) = (scheme, view.buffer().downcast::<sourceview5::Buffer>()) {
        buffer.set_style_scheme(Some(scheme));
    }
}

fn restyle_editors() {
    let scheme = editor_scheme();
    EDITORS.with(|editors| {
        for view in editors.borrow().iter().filter_map(|weak| weak.upgrade()) {
            set_scheme(&view, scheme.as_ref());
        }
    });
}

thread_local! {
    static EDITORS: RefCell<Vec<glib::WeakRef<sourceview5::View>>> = const { RefCell::new(Vec::new()) };
    static SCHEMES_INSTALLED: std::cell::OnceCell<bool> = const { std::cell::OnceCell::new() };
    static PROVIDER: gtk::CssProvider = gtk::CssProvider::new();
    static ATTACHED: Cell<bool> = const { Cell::new(false) };
    static CURRENT: Cell<ThemePref> = const { Cell::new(ThemePref::Default) };
}

pub fn apply(theme: ThemePref) {
    CURRENT.set(theme);
    let Some(display) = gtk::gdk::Display::default() else {
        return;
    };
    PROVIDER.with(|provider| {
        if !ATTACHED.replace(true) {
            gtk::style_context_add_provider_for_display(&display, provider, gtk::STYLE_PROVIDER_PRIORITY_USER);
            adw::StyleManager::default().connect_dark_notify(|_| apply(CURRENT.get()));
        }
        let dark = adw::StyleManager::default().is_dark();
        provider.load_from_string(
            &surface(theme, dark)
                .map(|surface| css(surface, adw::minor_version() >= 6))
                .unwrap_or_default(),
        );
    });
    restyle_editors();
}

pub fn labels() -> Vec<String> {
    ThemePref::ALL.into_iter().map(label).collect()
}

fn label(theme: ThemePref) -> String {
    match theme {
        ThemePref::Default => crate::tr!("Default"),
        ThemePref::Ledger => crate::tr!("Ledger"),
        ThemePref::Catppuccin => crate::tr!("Catppuccin"),
        ThemePref::Tokyo => crate::tr!("Tokyo Night"),
        ThemePref::Gruvbox => crate::tr!("Gruvbox"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn luminance(hex: &str) -> f64 {
        let channel = |index: usize| {
            let value = u8::from_str_radix(&hex[1 + index * 2..3 + index * 2], 16).unwrap() as f64 / 255.0;
            if value <= 0.03928 {
                value / 12.92
            } else {
                ((value + 0.055) / 1.055).powf(2.4)
            }
        };
        0.2126 * channel(0) + 0.7152 * channel(1) + 0.0722 * channel(2)
    }

    fn contrast(a: &str, b: &str) -> f64 {
        let (a, b) = (luminance(a), luminance(b));
        (a.max(b) + 0.05) / (a.min(b) + 0.05)
    }

    #[test]
    fn every_theme_keeps_text_and_accents_readable_in_light_and_dark() {
        for theme in ThemePref::ALL {
            for dark in [true, false] {
                let Some(s) = surface(theme, dark) else { continue };
                let name = format!("{theme:?} dark={dark}");
                for (fg, bg, floor) in [
                    (s.window_fg, s.window_bg, 4.5),
                    (s.window_fg, s.view_bg, 4.5),
                    (s.window_fg, s.chrome_bg, 4.5),
                    (s.window_fg, s.card_bg, 4.5),
                    (s.accent_fg, s.accent_bg, 4.5),
                    (s.accent_text, s.window_bg, 4.5),
                    (s.accent_text, s.view_bg, 4.5),
                    (s.accent_text, s.chrome_bg, 4.5),
                ] {
                    let ratio = contrast(fg, bg);
                    assert!(ratio >= floor, "{name}: {fg} on {bg} is {ratio:.2}, needs {floor}");
                }
            }
        }
    }

    #[test]
    fn the_default_theme_adds_no_overrides_and_others_define_every_surface() {
        assert!(surface(ThemePref::Default, true).is_none() && surface(ThemePref::Default, false).is_none());
        let sheet = css(surface(ThemePref::Ledger, true).unwrap(), true);
        for name in [
            "window_bg_color",
            "view_bg_color",
            "headerbar_bg_color",
            "accent_bg_color",
            "accent_color",
        ] {
            assert!(sheet.contains(&format!("@define-color {name} #")), "{name}");
        }
    }

    #[test]
    fn every_themed_editor_scheme_names_itself_and_inherits_adwaita() {
        for theme in ThemePref::ALL {
            for dark in [true, false] {
                let Some(surface) = surface(theme, dark) else { continue };
                let id = scheme_id(theme, dark);
                let xml = scheme_xml(&id, dark, surface);
                assert!(xml.contains(&format!("id=\"{id}\"")), "{id}");
                let parent = if dark { "Adwaita-dark" } else { "Adwaita" };
                assert!(xml.contains(&format!("parent-scheme=\"{parent}\"")), "{id}");
                assert!(xml.contains(&format!("background=\"{}\"", surface.view_bg)), "{id}");
            }
        }
    }

    #[test]
    fn labels_match_the_theme_list() {
        assert_eq!(labels().len(), ThemePref::ALL.len());
    }
}
