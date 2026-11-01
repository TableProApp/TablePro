use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::meta::{ObjectInfo, ObjectKind};
use tablepro_storage::AppSettings;

use crate::ui::clipboard::{ClipboardFormat, ClipboardPayload};
use crate::ui::source_dialog::{SourceText, cut, source_dialog};

/// Two million characters of SQL paint their first frame in about 50 ms
/// in a debug build; a longer body is cut in the view only, as Copy and
/// Open in Editor take all of it.
const SHOWN_CHARS: usize = 2_000_000;

/// Open in Editor hands the whole text to `open_in_editor`, for when the
/// user does want to change the object. Without one, the text cannot run
/// as it is, and a banner says why.
pub(crate) fn definition_dialog(
    object: &ObjectInfo,
    sql: &str,
    settings: &Rc<AppSettings>,
    open_in_editor: Option<Box<dyn Fn()>>,
) -> adw::Dialog {
    let cut_text = cut(sql, SHOWN_CHARS);
    let mut notes = Vec::new();
    if cut_text.is_some() {
        notes.push(crate::i18n::gettext(
            "This definition is too long to show in full. Copy and Open in Editor take all of it.",
        ));
    }
    if open_in_editor.is_none() {
        notes.push(crate::i18n::gettext(
            "A line in this definition would end a batch in the editor, so it cannot open there. Copy takes it as the server keeps it.",
        ));
    }
    let text = SourceText {
        title: title(object),
        language: "sql",
        label: crate::i18n::gettext("Definition"),
        notes,
        shown: cut_text.unwrap_or_else(|| sql.to_owned()),
        copied: ClipboardPayload {
            text: sql.to_owned(),
            format: ClipboardFormat::Sql,
            rows: 1,
            skipped: 0,
            cells: None,
        },
        size: (640, 520),
    };
    let shown = source_dialog(text, Some(settings));
    let Some(open_in_editor) = open_in_editor else {
        return shown.dialog;
    };
    let editor_button = gtk::Button::with_mnemonic(&crate::i18n::gettext("_Open in Editor"));
    shown.header.pack_start(&editor_button);
    let closing = shown.dialog.downgrade();
    editor_button.connect_clicked(move |_| {
        open_in_editor();
        if let Some(dialog) = closing.upgrade() {
            dialog.close();
        }
    });
    shown.dialog
}

/// A trigger is named with its table, which two triggers of one name tell
/// apart by.
fn title(object: &ObjectInfo) -> String {
    let name = &object.name;
    match (object.kind, object.parent_table.as_deref()) {
        (ObjectKind::Trigger, Some(table)) => {
            crate::i18n::gettext_f("Trigger “{name}” on “{table}”", &[("name", name), ("table", table)])
        }
        (ObjectKind::Trigger, None) => crate::i18n::gettext_f("Trigger “{name}”", &[("name", name)]),
        (ObjectKind::Function, _) => crate::i18n::gettext_f("Function “{name}”", &[("name", name)]),
        (ObjectKind::Procedure, _) => crate::i18n::gettext_f("Procedure “{name}”", &[("name", name)]),
        (ObjectKind::Sequence, _) => crate::i18n::gettext_f("Sequence “{name}”", &[("name", name)]),
        _ => crate::i18n::gettext_f("Definition of “{name}”", &[("name", name)]),
    }
}

/// The server does not tell a dropped object from one whose text this
/// login may not read.
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
    use std::cell::Cell;

    use super::*;
    use crate::test_support::{MemorySettings, OwnedWindow, descendants, first_descendant_of_type};

    fn editor_button(dialog: &adw::Dialog) -> gtk::Button {
        descendants(dialog)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
            .find(|button| button.label().as_deref() == Some("_Open in Editor"))
            .expect("an Open in Editor button")
    }

    #[gtk4::test]
    fn the_definition_is_read_only_and_open_in_editor_closes_it() {
        adw::init().expect("libadwaita initialises under the test backend");
        let window = OwnedWindow::presented(adw::Window::new());
        let opened = Rc::new(Cell::new(0));
        let sink = opened.clone();
        let object = ObjectInfo::trigger(Some("public".to_owned()), "audit", "orders");
        let sql = "CREATE TRIGGER audit AFTER INSERT ON public.orders FOR EACH ROW EXECUTE FUNCTION log();";

        let settings = MemorySettings::new();
        let dialog = definition_dialog(
            &object,
            sql,
            settings.get(),
            Some(Box::new(move || sink.set(sink.get() + 1))),
        );
        dialog.present(Some(&*window));

        assert_eq!(dialog.title(), "Trigger “audit” on “orders”");
        let view = first_descendant_of_type::<sourceview5::View>(&dialog).expect("the definition");
        assert!(!view.is_editable());
        let buffer = view.buffer();
        assert_eq!(buffer.text(&buffer.start_iter(), &buffer.end_iter(), false), sql);
        assert!(first_descendant_of_type::<adw::Banner>(&dialog).is_none());
        editor_button(&dialog).emit_clicked();
        assert_eq!(opened.get(), 1);
        dialog.force_close();
    }

    #[gtk4::test]
    fn a_long_definition_is_cut_in_the_view_only() {
        adw::init().expect("libadwaita initialises under the test backend");
        let window = OwnedWindow::presented(adw::Window::new());
        let object = ObjectInfo::new(Some("public".to_owned()), "big", ObjectKind::Function);
        let line = "    PERFORM pg_sleep(0);\n";
        let sql = line.repeat(SHOWN_CHARS / line.len() + 1);
        let more = sql.len() - SHOWN_CHARS;
        let settings = MemorySettings::new();

        let dialog = definition_dialog(&object, &sql, settings.get(), Some(Box::new(|| {})));
        dialog.present(Some(&*window));

        let view = first_descendant_of_type::<sourceview5::View>(&dialog).expect("the definition");
        let buffer = view.buffer();
        let shown = buffer.text(&buffer.start_iter(), &buffer.end_iter(), false);
        assert_eq!(
            shown.chars().count() - format!("… ({more} more bytes)").chars().count(),
            SHOWN_CHARS
        );
        assert!(sql.starts_with(&shown[..SHOWN_CHARS]));
        let banner = first_descendant_of_type::<adw::Banner>(&dialog).expect("the banner");
        assert!(banner.is_revealed());
        dialog.force_close();
    }

    #[gtk4::test]
    fn text_that_cannot_run_as_it_is_offers_no_editor() {
        adw::init().expect("libadwaita initialises under the test backend");
        let window = OwnedWindow::presented(adw::Window::new());
        let object = ObjectInfo::new(Some("dbo".to_owned()), "p", ObjectKind::Procedure);
        let settings = MemorySettings::new();

        let dialog = definition_dialog(&object, "CREATE PROCEDURE p AS SELECT 1", settings.get(), None);
        dialog.present(Some(&*window));

        let buttons: Vec<gtk::Button> = descendants(&dialog)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
            .collect();
        assert!(
            buttons
                .iter()
                .all(|button| button.label().as_deref() != Some("_Open in Editor"))
        );
        let banner = first_descendant_of_type::<adw::Banner>(&dialog).expect("the reason");
        assert!(banner.title().contains("end a batch"), "{}", banner.title());
        dialog.force_close();
    }

    #[gtk4::test]
    fn each_kind_names_itself_in_the_title() {
        let titled = |kind| title(&ObjectInfo::new(None, "ids", kind));

        assert_eq!(titled(ObjectKind::Function), "Function “ids”");
        assert_eq!(titled(ObjectKind::Procedure), "Procedure “ids”");
        assert_eq!(titled(ObjectKind::Sequence), "Sequence “ids”");
        assert_eq!(titled(ObjectKind::Trigger), "Trigger “ids”");
        assert_eq!(titled(ObjectKind::Table), "Definition of “ids”");
    }
}
