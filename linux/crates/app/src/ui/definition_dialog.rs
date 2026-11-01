use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use sourceview5::prelude::*;
use tablepro_core::meta::{ObjectInfo, ObjectKind};

use crate::ui::clipboard::{ClipboardFormat, ClipboardPayload};

/// The SQL that defines a routine, a sequence or a trigger, read-only.
/// Open in Editor hands the text to `open_in_editor`, for when the user
/// does want to change the object.
pub(crate) fn definition_dialog(
    object: &ObjectInfo,
    sql: &str,
    open_in_editor: impl Fn(String) + 'static,
) -> adw::Dialog {
    let buffer = sourceview5::Buffer::new(None);
    if let Some(lang) = sourceview5::LanguageManager::default().language("sql") {
        buffer.set_language(Some(&lang));
    }
    buffer.set_style_scheme(crate::ui::style_scheme_resolver::scheme("Adwaita").as_ref());
    buffer.set_text(sql);
    let view = sourceview5::View::with_buffer(&buffer);
    view.set_editable(false);
    view.set_monospace(true);
    view.set_show_line_numbers(true);
    view.set_top_margin(8);
    view.set_left_margin(8);
    view.upcast_ref::<gtk::Widget>()
        .update_property(&[gtk::accessible::Property::Label(&crate::i18n::gettext("Definition"))]);
    let scrolled = gtk::ScrolledWindow::builder().child(&view).vexpand(true).build();
    let toasts = adw::ToastOverlay::new();
    toasts.set_child(Some(&scrolled));

    let copy_button = gtk::Button::from_icon_name(crate::ui::icons::EDIT_COPY);
    crate::ui::a11y::describe_icon_button(&copy_button, &crate::i18n::gettext("Copy"), None);
    let payload = ClipboardPayload {
        text: sql.to_owned(),
        format: ClipboardFormat::Sql,
        rows: 1,
        skipped: 0,
        cells: None,
    };
    let shown_on = toasts.downgrade();
    copy_button.connect_clicked(move |button| {
        let shown_on = shown_on.clone();
        crate::ui::clipboard::copy_payload(button, payload.clone(), move |message| {
            if let Some(toasts) = shown_on.upgrade() {
                toasts.add_toast(crate::ui::plain_toast(message));
            }
        });
    });
    let editor_button = gtk::Button::with_mnemonic(&crate::i18n::gettext("_Open in Editor"));

    let header = adw::HeaderBar::new();
    header.pack_start(&editor_button);
    header.pack_end(&copy_button);
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&header);
    toolbar.set_content(Some(&toasts));

    let dialog = adw::Dialog::builder()
        .title(title(object))
        .content_width(640)
        .content_height(520)
        .child(&toolbar)
        .build();
    let text = sql.to_owned();
    let closing = dialog.downgrade();
    editor_button.connect_clicked(move |_| {
        open_in_editor(text.clone());
        if let Some(dialog) = closing.upgrade() {
            dialog.close();
        }
    });
    // GtkSourceView before 5.21 never frees a view that has drawn its line
    // numbers, so the closed dialog takes the text back.
    let shown_in = view.downgrade();
    dialog.connect_closed(move |_| {
        if let Some(view) = shown_in.upgrade() {
            view.set_buffer(Some(&sourceview5::Buffer::new(None)));
        }
    });
    dialog
}

/// The dialog's title: the kind, then the object's name, and a trigger's
/// table, which two triggers of one name tell apart by.
fn title(object: &ObjectInfo) -> String {
    let name = &object.name;
    match (object.kind, object.table.as_deref()) {
        (ObjectKind::Trigger, Some(table)) => {
            crate::i18n::gettext_f("Trigger “{name}” on “{table}”", &[("name", name), ("table", table)])
        }
        (ObjectKind::Procedure, _) => crate::i18n::gettext_f("Procedure “{name}”", &[("name", name)]),
        (ObjectKind::Sequence, _) => crate::i18n::gettext_f("Sequence “{name}”", &[("name", name)]),
        _ => crate::i18n::gettext_f("Function “{name}”", &[("name", name)]),
    }
}

/// Why an object has no definition to show: it was dropped since the
/// list was read, or the server keeps its text from this login.
pub(crate) fn no_definition_alert(object: &ObjectInfo) -> adw::AlertDialog {
    let alert = adw::AlertDialog::new(
        Some(&crate::i18n::gettext("No Definition")),
        Some(&crate::i18n::gettext_f(
            "The server returned no definition for “{name}”. It may have been dropped, or this login may not be allowed to read it.",
            &[("name", &object.name)],
        )),
    );
    alert.add_response("close", &crate::i18n::gettext("_Close"));
    alert.set_close_response("close");
    alert
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;

    use super::*;
    use crate::test_support::{OwnedWindow, descendants, first_descendant_of_type};

    #[gtk4::test]
    fn the_definition_is_read_only_and_open_in_editor_hands_it_over() {
        adw::init().expect("libadwaita initialises under the test backend");
        let window = OwnedWindow::presented(adw::Window::new());
        let opened = Rc::new(RefCell::new(None));
        let sink = opened.clone();
        let object = ObjectInfo::trigger(Some("public".to_owned()), "audit", "orders");
        let sql = "CREATE TRIGGER audit AFTER INSERT ON orders FOR EACH ROW EXECUTE FUNCTION log()";

        let dialog = definition_dialog(&object, sql, move |text| {
            sink.replace(Some(text));
        });
        dialog.present(Some(&*window));

        assert_eq!(dialog.title(), "Trigger “audit” on “orders”");
        let view = first_descendant_of_type::<sourceview5::View>(&dialog).expect("the definition");
        assert!(!view.is_editable());
        let buffer = view.buffer();
        assert_eq!(buffer.text(&buffer.start_iter(), &buffer.end_iter(), false), sql);
        let editor = descendants(&dialog)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
            .find(|button| button.label().as_deref() == Some("_Open in Editor"))
            .expect("an Open in Editor button");
        editor.emit_clicked();
        assert_eq!(opened.borrow().as_deref(), Some(sql));
        dialog.force_close();
    }

    #[gtk4::test]
    fn each_kind_names_itself_in_the_title() {
        let titled = |kind| title(&ObjectInfo::new(None, "ids", kind));

        assert_eq!(titled(ObjectKind::Function), "Function “ids”");
        assert_eq!(titled(ObjectKind::Procedure), "Procedure “ids”");
        assert_eq!(titled(ObjectKind::Sequence), "Sequence “ids”");
    }
}
