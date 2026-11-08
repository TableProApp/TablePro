use std::cell::RefCell;
use std::rc::Rc;

use gtk4::gsk::prelude::*;
use tablepro_core::Value;

use super::*;
use crate::test_support::{OwnedWindow, after_next_frame, drain_main_context, drop_focus, wait_until};
use crate::ui::data_grid::GridRequest;
use crate::ui::data_grid::test_grid::{Grid, GridSpec, WAIT, named, results, two_text_columns, two_text_values};

struct Desktop(adw::StyleManager, adw::ColorScheme);

impl Desktop {
    fn new() -> Self {
        adw::init().expect("libadwaita");
        let style = adw::StyleManager::default();
        let previous = style.color_scheme();
        Self(style, previous)
    }
}

impl Drop for Desktop {
    fn drop(&mut self) {
        self.0.set_color_scheme(self.1);
    }
}

fn choose(grid: &Grid, id: &str) {
    grid.grid
        .config()
        .expect("grid settings")
        .settings
        .set_style_scheme(id)
        .expect("scheme saved");
    after_next_frame(&grid.grid);
}

fn text_style(id: &str) -> (gdk::RGBA, gdk::RGBA) {
    let scheme = sourceview5::StyleSchemeManager::default()
        .scheme(id)
        .expect("installed scheme");
    let tag = gtk::TextTag::new(None);
    scheme.style("text").expect("text style").apply(&tag);
    (
        tag.background_rgba().expect("background"),
        tag.foreground_rgba().expect("foreground"),
    )
}

fn pixel(widget: &impl IsA<gtk::Widget>, x: i32, y: i32) -> [u8; 4] {
    let widget = widget.as_ref();
    after_next_frame(widget);
    let snapshot = gtk::Snapshot::new();
    gtk::WidgetPaintable::new(Some(widget)).snapshot(&snapshot, f64::from(widget.width()), f64::from(widget.height()));
    let node = snapshot.to_node().expect("painted widget");
    let renderer = gtk::gsk::CairoRenderer::new();
    renderer.realize(None::<&gdk::Surface>).expect("Cairo renderer");
    let texture = renderer.render_texture(&node, None);
    let mut download = gdk::TextureDownloader::new(&texture);
    download.set_format(gdk::MemoryFormat::R8g8b8a8);
    let (bytes, stride) = download.download_bytes();
    let offset = y as usize * stride + x as usize * 4;
    let result = bytes[offset..offset + 4].try_into().expect("a pixel");
    renderer.unrealize();
    result
}

fn assert_pixel(actual: [u8; 4], expected: gdk::RGBA) {
    let channels = [expected.red(), expected.green(), expected.blue(), expected.alpha()];
    for (actual, expected) in actual.into_iter().zip(channels) {
        assert!(
            (f32::from(actual) - expected * 255.0).abs() <= 2.0,
            "{actual} != {expected}"
        );
    }
}

fn base_pixel(grid: &Grid) -> [u8; 4] {
    let view = grid.grid.column_view();
    pixel(&view, view.width() - 10, view.height() - 10)
}

fn row_pixel(grid: &Grid, position: u32) -> [u8; 4] {
    let view = grid.grid.column_view();
    let bounds = grid.cell_at(position, 1).compute_bounds(&view).expect("cell bounds");
    pixel(&view, view.width() - 10, bounds.y() as i32 + 4)
}

fn custom_scheme(styles: &str) -> sourceview5::StyleScheme {
    let dir = tempfile::tempdir().expect("scheme directory");
    std::fs::write(
        dir.path().join("grid.xml"),
        format!(r#"<?xml version="1.0"?><style-scheme id="grid-test" name="Grid Test" version="1.0">{styles}</style-scheme>"#),
    ).expect("scheme written");
    let manager = sourceview5::StyleSchemeManager::new();
    manager.set_search_path(&[dir.path().to_str().expect("path")]);
    manager.scheme("grid-test").expect("custom scheme")
}

fn install_palette(grid: &Grid, palette: &Palette) {
    let binding = grid.grid.imp().scheme_style.borrow();
    let binding = binding.as_ref().expect("grid style");
    binding.provider.load_from_string(&palette.css(&binding.class));
}

#[gtk4::test]
fn picked_schemes_paint_the_same_grid_colors_on_both_desktops_and_reset_live() {
    let desktop = Desktop::new();
    let grid = Grid::open(two_text_columns(), two_text_values());
    for id in ["Adwaita", "Adwaita-dark", "solarized-light"] {
        choose(&grid, id);
        let (background, foreground) = text_style(id);
        for appearance in [adw::ColorScheme::ForceLight, adw::ColorScheme::ForceDark] {
            desktop.0.set_color_scheme(appearance);
            assert_pixel(base_pixel(&grid), background);
            assert_eq!(grid.cell_at(0, 1).display().expect("text").color(), foreground);
            assert_eq!(
                grid.grid.column_view().first_child().expect("header").color(),
                foreground
            );
        }
    }
    choose(&grid, "");
    for (appearance, id) in [
        (adw::ColorScheme::ForceLight, "Adwaita"),
        (adw::ColorScheme::ForceDark, "Adwaita-dark"),
    ] {
        desktop.0.set_color_scheme(appearance);
        let (background, foreground) = text_style(id);
        assert_pixel(base_pixel(&grid), background);
        assert_eq!(grid.cell_at(0, 1).display().expect("text").color(), foreground);
    }
}

#[gtk4::test]
fn installed_schemes_with_transparent_selection_text_keep_selected_values_visible() {
    let grid = Grid::open(two_text_columns(), two_text_values());
    for id in ["cobalt", "oblivion", "kate", "solarized-light", "solarized-dark"] {
        let scheme = sourceview5::StyleSchemeManager::default()
            .scheme(id)
            .expect("installed scheme");
        let tag = gtk::TextTag::new(None);
        scheme.style("selection").expect("selection").apply(&tag);
        assert!(
            tag.foreground_rgba().is_none_or(|color| color.alpha() == 0.0),
            "{id} fixture changed"
        );
        choose(&grid, id);
        grid.focus(0, 1);
        grid.grid.selection().select_item(0, true);
        after_next_frame(&grid.grid);
        let foreground = text_style(id).1;
        assert_eq!(grid.cell_at(0, 1).display().expect("text").color(), foreground, "{id}");
        assert_ne!(
            row_pixel(&grid, 0),
            base_pixel(&grid),
            "{id} lost its selection background"
        );
    }
}

#[gtk4::test]
fn independent_grids_follow_their_settings_and_release_their_styles() {
    let first = Grid::open(two_text_columns(), two_text_values());
    let second = Grid::open(two_text_columns(), two_text_values());
    choose(&first, "Adwaita-dark");
    choose(&second, "Adwaita");
    assert_pixel(base_pixel(&first), text_style("Adwaita-dark").0);
    assert_pixel(base_pixel(&second), text_style("Adwaita").0);
    choose(&first, "solarized-light");
    assert_pixel(base_pixel(&first), text_style("solarized-light").0);
    assert_pixel(base_pixel(&second), text_style("Adwaita").0);
    let settings = first.grid.config().expect("settings").settings.clone();
    let grid = first.grid.downgrade();
    let provider = first
        .grid
        .imp()
        .scheme_style
        .borrow()
        .as_ref()
        .expect("style")
        .provider
        .downgrade();
    drop_focus(&first.window);
    drop(first);
    drain_main_context();
    assert!(grid.upgrade().is_none(), "settings retained the grid");
    assert!(provider.upgrade().is_none(), "display retained the scoped provider");
    settings
        .set_style_scheme("Adwaita-dark")
        .expect("old settings remain usable");
    assert_pixel(base_pixel(&second), text_style("Adwaita").0);
}

#[gtk4::test]
fn empty_grid_text_and_stripes_follow_the_grid_foreground() {
    let grid = Grid::open(two_text_columns(), two_text_values());
    choose(&grid, "Adwaita-dark");
    let settings = &grid.grid.config().expect("settings").settings;
    settings.set_show_alternate_rows(false).expect("stripes off");
    let plain = row_pixel(&grid, 1);
    settings.set_show_alternate_rows(true).expect("stripes on");
    let striped = row_pixel(&grid, 1);
    assert!(
        striped[0] > plain[0] && striped[1] > plain[1] && striped[2] > plain[2],
        "dark rows need a light stripe"
    );
    grid.grid.clear_rows();
    after_next_frame(&grid.grid);
    assert!(grid.grid.imp().empty_page.is_visible());
    assert_eq!(grid.grid.imp().empty_page.color(), text_style("Adwaita-dark").1);
}

#[gtk4::test]
fn an_opaque_selection_without_text_keeps_the_native_translucent_fallback() {
    let scheme = custom_scheme(
        r##"<style name="text" foreground="#ffffff" background="#000000"/><style name="selection" background="#ffffff"/>"##,
    );
    let palette = Palette::from_scheme(&scheme).expect("complete pair");
    assert_eq!(palette.selection.foreground, gdk::RGBA::WHITE);
    assert!((palette.selection.background.alpha() - 0.3).abs() < f32::EPSILON);
    let grid = Grid::open(two_text_columns(), two_text_values());
    install_palette(&grid, &palette);
    grid.focus(0, 1);
    grid.grid.selection().select_item(0, true);
    wait_until(WAIT, || {
        let actual = row_pixel(&grid, 0);
        actual[..3].iter().all(|channel| (i32::from(*channel) - 77).abs() <= 2)
    })
    .expect("selection reaches its final translucent color");
    assert_pixel(row_pixel(&grid, 0), gdk::RGBA::new(0.3, 0.3, 0.3, 1.0));
    assert_eq!(grid.cell_at(0, 1).display().expect("text").color(), gdk::RGBA::WHITE);
}

#[gtk4::test]
fn incomplete_base_colors_never_mix_with_the_desktop_palette() {
    for styles in [
        "",
        r##"<style name="text" foreground="#ffffff"/>"##,
        r##"<style name="text" background="#000000"/>"##,
    ] {
        assert!(Palette::from_scheme(&custom_scheme(styles)).is_none());
    }
}

#[gtk4::test]
fn every_installed_palette_parses_without_css_errors() {
    let provider = gtk::CssProvider::new();
    let errors = Rc::new(RefCell::new(Vec::new()));
    let seen = errors.clone();
    provider.connect_parsing_error(move |_, _, error| seen.borrow_mut().push(error.to_string()));
    let manager = sourceview5::StyleSchemeManager::default();
    let mut checked = 0;
    for id in manager.scheme_ids() {
        if let Some(palette) = manager.scheme(&id).as_ref().and_then(Palette::from_scheme) {
            provider.load_from_string(&palette.css("tp-grid-test"));
            assert!(errors.borrow().is_empty(), "{id}: {:?}", errors.borrow());
            checked += 1;
        }
    }
    assert!(checked >= 5, "installed palettes were not tested");
}

#[gtk4::test]
fn high_contrast_restores_native_colors_and_leaving_it_restores_the_scheme() {
    let grid = Grid::open(two_text_columns(), two_text_values());
    choose(&grid, "cobalt");
    let binding = grid.grid.imp().scheme_style.borrow();
    let binding = binding.as_ref().expect("style");
    binding.provider.load_from_string("");
    let native = base_pixel(&grid);
    let palette = Palette::from_scheme(
        &sourceview5::StyleSchemeManager::default()
            .scheme("cobalt")
            .expect("scheme"),
    )
    .expect("pair");
    binding.provider.load_from_string(&palette.css(&binding.class));
    binding.provider.set_prefers_contrast(gtk::InterfaceContrast::More);
    assert_eq!(base_pixel(&grid), native);
    binding
        .provider
        .set_prefers_contrast(gtk::InterfaceContrast::NoPreference);
    assert_pixel(base_pixel(&grid), palette.background);
}

#[gtk4::test]
fn modified_values_keep_their_text_and_bold_mark_in_selected_rows() {
    let grid = Grid::open(two_text_columns(), two_text_values());
    choose(&grid, "Adwaita-dark");
    let cell = grid.focus(0, 1);
    assert!(grid.grid.edit().edit_cell(&cell));
    let editor = grid.grid.edit().open_text().expect("inline editor");
    editor.set_text("changed");
    editor.emit_activate();
    grid.grid.selection().select_item(0, true);
    after_next_frame(&grid.grid);
    let display = cell.display().expect("text");
    assert_eq!(display.text().as_deref(), Some("changed"));
    assert!(
        display
            .attributes()
            .expect("edit mark")
            .attributes()
            .iter()
            .any(|attr| attr.type_() == gtk::pango::AttrType::Weight)
    );
    let row = cell.parent().and_then(|parent| parent.parent()).expect("row");
    assert_eq!(display.color(), row.color());
}

#[gtk4::test]
fn rejected_inline_values_keep_a_readable_error_pair_on_both_desktops() {
    let desktop = Desktop::new();
    let grid = Grid::open(
        vec![named("id", "integer", true), named("n", "integer", false)],
        vec![vec![Value::Int(1), Value::Int(5)]],
    );
    grid.grid
        .column_view()
        .columns()
        .item(2)
        .and_downcast::<gtk::ColumnViewColumn>()
        .expect("numeric column")
        .set_fixed_width(180);
    for appearance in [adw::ColorScheme::ForceLight, adw::ColorScheme::ForceDark] {
        desktop.0.set_color_scheme(appearance);
        let probe = gtk::Label::builder().label("error").css_classes(["error"]).build();
        let probe_window = OwnedWindow::presented(gtk::Window::builder().child(&probe).build());
        after_next_frame(&probe);
        let desktop_error = probe.color();
        drop(probe_window);
        let scheme = custom_scheme(&format!(
            r##"<style name="text" foreground="#ffffff" background="#{desktop_error}"/>"##
        ));
        let palette = Palette::from_scheme(&scheme).expect("custom pair");
        install_palette(&grid, &palette);
        for selected in [false, true] {
            let cell = grid.focus(0, 1);
            if selected {
                grid.grid.selection().select_item(0, true);
            } else {
                grid.grid.selection().unselect_all();
            }
            assert!(grid.grid.edit().edit_cell(&cell));
            let editor = grid.grid.edit().open_text().expect("inline editor");
            editor.set_text("12,5");
            editor.emit_activate();
            editor.select_region(0, 0);
            after_next_frame(&editor);
            assert!(editor.has_css_class("error"));
            assert_eq!(editor.text(), "12,5");
            assert_ne!(editor.color(), desktop_error, "error text blends into the custom base");
            let background = pixel(&editor, 8, editor.height() / 2);
            let text = editor.color();
            assert_ne!(
                background[..3],
                [
                    (text.red() * 255.0) as u8,
                    (text.green() * 255.0) as u8,
                    (text.blue() * 255.0) as u8
                ]
            );
            editor.select_region(0, -1);
            assert_eq!(pixel(&editor, 8, editor.height() / 2), background);
            assert!(
                grid.take_requests()
                    .iter()
                    .any(|request| matches!(request, GridRequest::Toast(_)))
            );
            grid.grid.edit().cancel_open_edit();
        }
    }
}

#[gtk4::test]
fn a_selection_follows_the_scheme_when_focus_moves_out_of_the_grid() {
    let scheme = custom_scheme(
        r##"<style name="text" foreground="#ffffff" background="#000000"/>
        <style name="selection" foreground="#ffffff" background="#0000ff"/>
        <style name="selection-unfocused" foreground="#000000" background="#00ff00"/>"##,
    );
    let grid = Grid::build(GridSpec::results(two_text_columns()), results(&two_text_values()));
    install_palette(&grid, &Palette::from_scheme(&scheme).expect("complete pair"));
    grid.focus(0, 1);
    grid.grid.selection().select_item(0, true);
    after_next_frame(&grid.grid);
    assert_eq!(grid.cell_at(0, 1).display().expect("text").color(), gdk::RGBA::WHITE);
    grid.activate("find");
    after_next_frame(&grid.grid);
    assert_eq!(grid.cell_at(0, 1).display().expect("text").color(), gdk::RGBA::BLACK);
    wait_until(WAIT, || row_pixel(&grid, 0) == [0, 255, 0, 255]).expect("unfocused selection uses its own background");
}
