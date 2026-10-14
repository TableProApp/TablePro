use gtk4::prelude::*;
use gtk4::{self as gtk, glib};
use sourceview5::prelude::*;

use super::edit_commit::{commit_edit, send_commit};
use super::{EditSnapshot, GridCell};

/// A popover with a source view, for text that spans lines or is too
/// long for a one-line field. Return adds a line, so Save is a button
/// and Ctrl+Return.
pub struct MultilineEditor;

impl MultilineEditor {
    pub(super) fn open(cell: &GridCell, snapshot: EditSnapshot, text: &str, language: Option<&'static str>) {
        cell.cancel_edit();
        let buffer = sourceview5::Buffer::new(None);
        if let Some(language) = language.and_then(|id| sourceview5::LanguageManager::default().language(id)) {
            buffer.set_language(Some(&language));
        }
        buffer.set_text(text);
        let view = sourceview5::View::with_buffer(&buffer);
        view.set_monospace(true);
        view.set_wrap_mode(gtk::WrapMode::WordChar);
        view.set_auto_indent(true);
        crate::ui::style_scheme_resolver::apply(&view, "Adwaita");

        let scrolled = gtk::ScrolledWindow::builder()
            .child(&view)
            .min_content_width(420)
            .min_content_height(280)
            .has_frame(true)
            .build();
        let save = gtk::Button::with_label(&crate::i18n::gettext("Save"));
        save.add_css_class("suggested-action");
        let cancel = gtk::Button::with_label(&crate::i18n::gettext("Cancel"));
        let buttons = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(8)
            .halign(gtk::Align::End)
            .build();
        buttons.append(&cancel);
        buttons.append(&save);
        let content = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(8)
            .margin_top(8)
            .margin_bottom(8)
            .margin_start(8)
            .margin_end(8)
            .build();
        content.append(&scrolled);
        content.append(&buttons);
        let popover = gtk::Popover::builder().child(&content).build();

        let weak_popover = popover.downgrade();
        cancel.connect_clicked(move |_| {
            if let Some(popover) = weak_popover.upgrade() {
                popover.popdown();
            }
        });
        let weak_cell = cell.downgrade();
        save.connect_clicked(move |_| {
            if let Some(cell) = weak_cell.upgrade() {
                save_text(&cell, &buffer);
            }
        });
        let save_shortcut = gtk::ShortcutController::new();
        let weak_save = save.downgrade();
        save_shortcut.add_shortcut(gtk::Shortcut::new(
            Some(gtk::KeyvalTrigger::new(
                gtk::gdk::Key::Return,
                gtk::gdk::ModifierType::CONTROL_MASK,
            )),
            Some(gtk::CallbackAction::new(move |_, _| {
                if let Some(save) = weak_save.upgrade() {
                    save.emit_clicked();
                }
                glib::Propagation::Stop
            })),
        ));
        view.add_controller(save_shortcut);

        cell.begin_edit(snapshot);
        cell.present_popover(&popover);
        view.grab_focus();
    }
}

/// The popover closes before the tab hears of the value, so an edit the
/// tab redraws the row for never meets an open popover.
fn save_text(cell: &GridCell, buffer: &sourceview5::Buffer) {
    let Some(snapshot) = cell.take_edit() else {
        return;
    };
    let text = buffer.text(&buffer.start_iter(), &buffer.end_iter(), true).to_string();
    if let Some(popover) = cell.take_popover() {
        popover.popdown();
    }
    let Some(drawing) = cell.drawing() else {
        return;
    };
    let Some(column) = drawing.catalog.as_ref() else {
        return;
    };
    let result = commit_edit(column, &snapshot, &text);
    send_commit(cell, snapshot, result);
}
