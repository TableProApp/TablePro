use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, gdk, glib};
use libadwaita as adw;
use tablepro_linux_platform::settings::keys;

use super::DataGrid;
use crate::ui::handler_guard::HandlerGuard;
use crate::ui::style_scheme_resolver;

#[derive(Debug, Clone)]
struct SelectionColors {
    background: gdk::RGBA,
    foreground: gdk::RGBA,
}

impl SelectionColors {
    fn from_style(style: Option<sourceview5::Style>, background: gdk::RGBA, foreground: gdk::RGBA) -> Self {
        let (selected_background, selected_foreground) = colors(style);
        let Some(mut selected_background) = selected_background else {
            return Self {
                background: foreground,
                foreground: background,
            };
        };
        // GtkSourceView's fix_broken_selection keeps unchanged text readable
        // over a selection that supplies only an opaque background.
        if selected_foreground.is_none() && selected_background.alpha() >= 1.0 {
            selected_background.set_alpha(0.3);
        }
        Self {
            background: selected_background,
            foreground: selected_foreground.unwrap_or(foreground),
        }
    }
}

#[derive(Debug, Clone)]
struct Palette {
    background: gdk::RGBA,
    foreground: gdk::RGBA,
    selection: SelectionColors,
    unfocused_selection: SelectionColors,
}

impl Palette {
    fn from_scheme(scheme: &sourceview5::StyleScheme) -> Option<Self> {
        let (background, foreground) = colors(scheme.style("text"));
        // A partial pair could put scheme text on the opposite desktop color.
        let (background, foreground) = (background?, foreground?);
        let selection = scheme.style("selection");
        let unfocused = scheme.style("selection-unfocused").or_else(|| selection.clone());
        Some(Self {
            background,
            foreground,
            selection: SelectionColors::from_style(selection, background, foreground),
            unfocused_selection: SelectionColors::from_style(unfocused, background, foreground),
        })
    }

    fn css(&self, class: &str) -> String {
        let Self {
            background,
            foreground,
            selection,
            unfocused_selection,
        } = self;
        let (selected_background, selected_foreground) = (&selection.background, &selection.foreground);
        let (unfocused_background, unfocused_foreground) =
            (&unfocused_selection.background, &unfocused_selection.foreground);
        // Native high-contrast styling takes precedence over a saved palette.
        format!(
            "@media (prefers-contrast: no-preference) {{
                .{class} {{
                    --view-bg-color: {background};
                    --view-fg-color: {foreground};
                    --accent-color: currentColor;
                    color: var(--view-fg-color);
                }}
                columnview.{class} {{ background-color: var(--view-bg-color); }}
                columnview.{class} > listview > row:selected {{
                    background-color: {selected_background};
                    color: {selected_foreground};
                }}
                columnview.{class}:not(:focus-within) > listview > row:selected {{
                    background-color: {unfocused_background};
                    color: {unfocused_foreground};
                }}
                columnview.{class} tp-grid-cell > label.warning {{ color: inherit; }}
                columnview.{class} tp-grid-cell > text {{
                    background-color: var(--view-bg-color);
                    color: var(--view-fg-color);
                }}
                columnview.{class} tp-grid-cell > text selection {{
                    background-color: {selected_background};
                    color: {selected_foreground};
                }}
                columnview.{class} tp-grid-cell > text:not(:focus) selection {{
                    background-color: {unfocused_background};
                    color: {unfocused_foreground};
                }}
                columnview.{class} tp-grid-cell > text.error {{
                    background-color: var(--error-bg-color);
                    color: var(--error-fg-color);
                }}
                columnview.{class} tp-grid-cell > text.error selection {{
                    background-color: var(--error-fg-color);
                    color: var(--error-bg-color);
                }}
            }}"
        )
    }
}

fn colors(style: Option<sourceview5::Style>) -> (Option<gdk::RGBA>, Option<gdk::RGBA>) {
    let tag = gtk::TextTag::new(None);
    if let Some(style) = style {
        style.apply(&tag);
    }
    // Transparent selection foregrounds tell GtkSourceView to keep syntax
    // colors; CSS text needs an actual foreground instead.
    let visible = |color: &gdk::RGBA| color.alpha() > 0.0;
    (
        tag.background_rgba().filter(visible),
        tag.foreground_rgba().filter(visible),
    )
}

pub(super) struct SchemeStyle {
    display: gdk::Display,
    provider: gtk::CssProvider,
    class: String,
    _handlers: Vec<HandlerGuard>,
}

impl Drop for SchemeStyle {
    fn drop(&mut self) {
        gtk::style_context_remove_provider_for_display(&self.display, &self.provider);
    }
}

pub(super) fn follow(grid: &DataGrid) {
    let Some(settings) = grid.config().map(|config| config.settings.clone()) else {
        return;
    };
    let display = grid.display();
    let provider = gtk::CssProvider::new();
    let class = format!("tp-grid-scheme-{}", uuid::Uuid::new_v4().simple());
    grid.column_view().add_css_class(&class);
    grid.imp().empty_page.add_css_class(&class);
    gtk::style_context_add_provider_for_display(&display, &provider, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION + 1);

    // GSettings emits changes only after a read while a handler is connected.
    let setting_handler = settings.gio().connect_changed(
        Some(keys::STYLE_SCHEME),
        glib::clone!(
            #[weak]
            grid,
            move |_, _| refresh(&grid)
        ),
    );
    let style = adw::StyleManager::default();
    let dark_handler = style.connect_dark_notify(glib::clone!(
        #[weak]
        grid,
        move |_| refresh(&grid)
    ));
    let contrast_handler = style.connect_high_contrast_notify(glib::clone!(
        #[weak]
        grid,
        move |_| refresh(&grid)
    ));
    grid.imp().scheme_style.replace(Some(SchemeStyle {
        display,
        provider,
        class,
        _handlers: vec![
            HandlerGuard::new(settings.gio(), setting_handler),
            HandlerGuard::new(&style, dark_handler),
            HandlerGuard::new(&style, contrast_handler),
        ],
    }));
    refresh(grid);
}

fn refresh(grid: &DataGrid) {
    let binding = grid.imp().scheme_style.borrow();
    let (Some(binding), Some(config)) = (binding.as_ref(), grid.config()) else {
        return;
    };
    binding
        .provider
        .set_prefers_contrast(if adw::StyleManager::default().is_high_contrast() {
            gtk::InterfaceContrast::More
        } else {
            gtk::InterfaceContrast::NoPreference
        });
    let css = style_scheme_resolver::scheme(&config.settings.style_scheme())
        .as_ref()
        .and_then(Palette::from_scheme)
        .map(|palette| palette.css(&binding.class))
        .unwrap_or_default();
    binding.provider.load_from_string(&css);
}

#[cfg(test)]
mod tests;
