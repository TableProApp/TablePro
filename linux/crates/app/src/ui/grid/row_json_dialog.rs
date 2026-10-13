use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use sourceview5::prelude::*;

pub(super) fn show_row_json_dialog(parent: &impl IsA<gtk::Widget>, json: String) {
    let buffer = sourceview5::Buffer::new(None);
    if let Some(lang) = sourceview5::LanguageManager::default().language("json") {
        buffer.set_language(Some(&lang));
    }
    let scheme_name = if adw::StyleManager::default().is_dark() {
        "Adwaita-dark"
    } else {
        "Adwaita"
    };
    buffer.set_style_scheme(sourceview5::StyleSchemeManager::default().scheme(scheme_name).as_ref());
    buffer.set_text(&json);
    let view = sourceview5::View::with_buffer(&buffer);
    view.set_editable(false);
    view.set_monospace(true);
    view.set_show_line_numbers(true);
    view.set_top_margin(8);
    view.set_left_margin(8);
    let scrolled = gtk::ScrolledWindow::builder().child(&view).vexpand(true).build();

    let copy_button = gtk::Button::from_icon_name(crate::ui::icons::EDIT_COPY);
    copy_button.set_tooltip_text(Some(&crate::i18n::gettext("Copy")));
    copy_button.connect_clicked(move |b| b.clipboard().set_text(&json));
    let header = adw::HeaderBar::new();
    header.pack_end(&copy_button);
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&header);
    toolbar.set_content(Some(&scrolled));

    adw::Dialog::builder()
        .title(crate::i18n::gettext("Row as JSON"))
        .content_width(560)
        .content_height(480)
        .child(&toolbar)
        .build()
        .present(Some(parent));
}
