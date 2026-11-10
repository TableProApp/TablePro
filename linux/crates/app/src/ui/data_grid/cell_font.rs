use std::sync::atomic::{AtomicU64, Ordering};

use gtk4::glib::translate::IntoGlib;
use gtk4::prelude::*;
use gtk4::{self as gtk, gdk, pango};
use tablepro_linux_platform::EditorFont;

pub(super) struct CellFont {
    display: gdk::Display,
    provider: gtk::CssProvider,
    class: String,
    applied: Option<EditorFont>,
}

impl CellFont {
    pub(super) fn new(view: &gtk::ColumnView) -> Self {
        static NEXT_CLASS: AtomicU64 = AtomicU64::new(1);
        let class = format!("tp-grid-font-{}", NEXT_CLASS.fetch_add(1, Ordering::Relaxed));
        view.add_css_class(&class);
        let display = view.display();
        let provider = gtk::CssProvider::new();
        gtk::style_context_add_provider_for_display(&display, &provider, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
        Self {
            display,
            provider,
            class,
            applied: None,
        }
    }

    pub(super) fn apply(&mut self, font: &EditorFont) -> bool {
        if self.applied.as_ref() == Some(font) {
            return false;
        }
        let css = match font {
            EditorFont::System => String::new(),
            EditorFont::Custom(description) => font_css(&self.class, &custom_font(description)),
        };
        self.provider.load_from_string(&css);
        self.applied = Some(font.clone());
        true
    }
}

impl Drop for CellFont {
    fn drop(&mut self) {
        gtk::style_context_remove_provider_for_display(&self.display, &self.provider);
    }
}

pub(super) fn custom_font(description: &str) -> pango::FontDescription {
    let mut font = pango::FontDescription::from_string(description);
    // The same fields must reach CSS and width measurement.
    font.unset_fields(
        !(pango::FontMask::FAMILY
            | pango::FontMask::SIZE
            | pango::FontMask::WEIGHT
            | pango::FontMask::STYLE
            | pango::FontMask::STRETCH),
    );
    if font.family().is_none_or(|family| family.trim().is_empty()) {
        font.set_family("Monospace");
    }
    if font.size() <= 0 {
        font.set_size(10 * pango::SCALE);
    }
    font.set_variant(pango::Variant::Normal);
    font.set_weight(font.weight());
    font.set_style(font.style());
    font.set_stretch(font.stretch());
    font
}

fn font_css(class: &str, font: &pango::FontDescription) -> String {
    let mut declarations = Vec::new();
    if let Some(family) = font.family() {
        let escaped = crate::ui::editor_font_provider::escape_css_string(&family);
        declarations.push(format!("font-family: \"{escaped}\";"));
    }
    if font.size() > 0 {
        let size = f64::from(font.size()) / f64::from(pango::SCALE);
        let unit = if font.is_size_absolute() { "px" } else { "pt" };
        declarations.push(format!("font-size: {size}{unit};"));
    }
    declarations.push(format!("font-weight: {};", font.weight().into_glib()));
    let style = match font.style() {
        pango::Style::Italic => "italic",
        pango::Style::Oblique => "oblique",
        _ => "normal",
    };
    declarations.push(format!("font-style: {style}; font-variant: normal;"));
    let stretch = match font.stretch() {
        pango::Stretch::UltraCondensed => "ultra-condensed",
        pango::Stretch::ExtraCondensed => "extra-condensed",
        pango::Stretch::Condensed => "condensed",
        pango::Stretch::SemiCondensed => "semi-condensed",
        pango::Stretch::SemiExpanded => "semi-expanded",
        pango::Stretch::Expanded => "expanded",
        pango::Stretch::ExtraExpanded => "extra-expanded",
        pango::Stretch::UltraExpanded => "ultra-expanded",
        _ => "normal",
    };
    declarations.push(format!("font-stretch: {stretch};"));
    format!("columnview.{class} .monospace {{ {} }}", declarations.join(" "))
}

#[cfg(test)]
mod tests {
    use gtk4::subclass::prelude::*;
    use tablepro_core::Value;

    use super::*;
    use crate::test_support::{MemorySettings, descendants, drain_main_context, wait_until};
    use crate::ui::data_grid::test_grid::{Grid, GridSpec, WAIT, named, persisted, two_text_columns, two_text_values};

    fn grid(settings: &MemorySettings) -> Grid {
        Grid::build(
            GridSpec {
                settings: Some(settings.get().clone()),
                ..GridSpec::table(two_text_columns())
            },
            persisted(&two_text_values()),
        )
    }

    fn shown_font(grid: &Grid) -> pango::FontDescription {
        grid.cell_at(0, 1)
            .display()
            .expect("display")
            .pango_context()
            .font_description()
            .expect("font")
    }

    #[gtk4::test]
    fn grid_fonts_follow_shared_settings_without_affecting_other_grids_or_editors() {
        let settings = MemorySettings::new();
        let isolated = MemorySettings::new();
        settings
            .get()
            .set_editor_font(&EditorFont::Custom("Monospace 13".into()))
            .expect("editor font");
        crate::ui::editor_font_provider::apply(settings.get());
        let editor_css = crate::ui::editor_font_provider::installed_css();
        let first = grid(&settings);
        let second = grid(&settings);
        let third = grid(&isolated);
        let original = shown_font(&third);

        settings
            .get()
            .set_grid_font(&EditorFont::Custom("Sans Bold Italic 20".into()))
            .expect("cell font");

        wait_until(WAIT, || {
            [&first, &second].iter().all(|grid| {
                let font = shown_font(grid);
                font.weight() == pango::Weight::Bold && font.style() == pango::Style::Italic
            })
        })
        .expect("both grids use the chosen font");
        assert_eq!(shown_font(&third), original);
        assert_eq!(crate::ui::editor_font_provider::installed_css(), editor_css);

        settings.get().set_grid_font(&EditorFont::System).expect("system font");
        wait_until(WAIT, || {
            shown_font(&first) == original && shown_font(&second) == original
        })
        .expect("both grids return to the desktop font");
    }

    #[gtk4::test]
    fn a_styled_cell_font_sizes_numeric_columns_for_the_rendered_glyphs() {
        let settings = MemorySettings::new();
        settings
            .get()
            .set_grid_font(&EditorFont::Custom("Sans Bold Italic 18".into()))
            .expect("cell font");
        let shown = Grid::build(
            GridSpec {
                settings: Some(settings.get().clone()),
                ..GridSpec::table(vec![named("id", "integer", true), named("value", "bigint", false)])
            },
            persisted(&[vec![Value::Int(1), Value::Int(8_888_888_888_888)]]),
        );
        let display = shown.cell_at(0, 1).display().expect("display").clone();
        wait_until(WAIT, || {
            let layout = display.create_pango_layout(display.text().as_deref());
            let attrs = pango::AttrList::new();
            attrs.insert(pango::AttrFontFeatures::new("tnum"));
            layout.set_attributes(Some(&attrs));
            display.width() > 0 && layout.pixel_size().0 <= display.width()
        })
        .expect("the chosen styled font fits");
        let font = shown_font(&shown);
        assert_eq!(font.weight(), pango::Weight::Bold);
        assert_eq!(font.style(), pango::Style::Italic);
    }

    #[gtk4::test]
    fn an_inline_edit_keeps_its_draft_and_follows_the_cell_font() {
        let settings = MemorySettings::new();
        let shown = grid(&settings);
        let cell = shown.focus(0, 1);
        assert!(shown.grid.edit().edit_cell(&cell));
        let editor = descendants(&cell)
            .into_iter()
            .find_map(|widget| widget.downcast::<gtk::Text>().ok())
            .expect("inline editor");
        editor.set_text("a draft");

        settings
            .get()
            .set_grid_font(&EditorFont::Custom("Sans Bold Italic 20".into()))
            .expect("cell font");

        wait_until(WAIT, || {
            editor
                .pango_context()
                .font_description()
                .is_some_and(|font| font.weight() == pango::Weight::Bold && font.style() == pango::Style::Italic)
        })
        .expect("the open editor follows the font");
        assert_eq!(editor.text(), "a draft");
        assert!(shown.grid.is_editing());
    }

    #[gtk4::test]
    fn a_custom_font_change_preserves_the_width_the_user_chose() {
        let settings = MemorySettings::new();
        let shown = grid(&settings);
        let column = shown
            .grid
            .imp()
            .columns
            .borrow()
            .view_column(1)
            .expect("column")
            .clone();
        column.set_fixed_width(400);

        settings
            .get()
            .set_grid_font(&EditorFont::Custom("Sans Bold Italic 20".into()))
            .expect("cell font");
        wait_until(WAIT, || shown_font(&shown).weight() == pango::Weight::Bold).expect("font applied");

        assert_eq!(column.fixed_width(), 400);
    }

    #[gtk4::test]
    fn closing_a_grid_releases_its_font_provider() {
        let settings = MemorySettings::new();
        let shown = grid(&settings);
        let provider = shown
            .grid
            .imp()
            .cell_font
            .borrow()
            .as_ref()
            .expect("font owner")
            .provider
            .downgrade();

        drop(shown);
        drain_main_context();

        assert!(provider.upgrade().is_none());
    }

    #[test]
    fn regular_custom_fonts_reset_style_and_weight() {
        let css = font_css("scope", &custom_font("Monospace 10"));
        assert!(css.contains("font-weight: 400;"));
        assert!(css.contains("font-style: normal;"));
        assert!(css.contains("font-stretch: normal;"));
        assert!(css.contains("font-variant: normal;"));
    }

    #[test]
    fn custom_font_css_escapes_family_controls_and_keeps_absolute_sizes() {
        let mut font = custom_font("Monospace Bold Italic 10");
        font.set_family("A\"B\\C\nD");
        font.set_absolute_size(15.5 * f64::from(pango::SCALE));
        let css = font_css("scope", &font);
        assert!(css.contains("A\\\"B\\\\C\\a D"), "{css}");
        assert!(css.contains("font-size: 15.5px;"));
        assert!(!css.contains('\n'));
    }
}
