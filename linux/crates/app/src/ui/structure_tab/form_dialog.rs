//! The frame the Add Index and Add Foreign Key forms share: an
//! `adw::Dialog` with Cancel and the suggested submit in its header bar
//! and the fields on a preferences page, as in GNOME Settings' Add
//! dialogs. The HIG keeps AlertDialog for confirmations.
//!
//! The form is checked on every change. Submit is on only while it is
//! valid, so Enter, which reaches it as the default widget, does
//! nothing until then; the first problem the user can act on shows
//! under the fields.

use std::rc::Rc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;

pub(super) struct FormDialog {
    /// Weak, since the dialog owns the state the form lives in
    /// (`give_state`), and a strong reference back would keep both.
    dialog: glib::WeakRef<adw::Dialog>,
    pub page: adw::PreferencesPage,
    pub submit: gtk::Button,
    caption: gtk::Label,
}

impl FormDialog {
    /// The form, and the dialog it is drawn in, which nothing else holds
    /// until it is presented.
    pub(super) fn new(title: &str, submit_label: &str) -> (Self, adw::Dialog) {
        let dialog = adw::Dialog::builder()
            .title(title)
            .content_width(420)
            .content_height(560)
            .build();
        let header = adw::HeaderBar::builder()
            .show_start_title_buttons(false)
            .show_end_title_buttons(false)
            .build();
        let cancel = gtk::Button::with_mnemonic(&crate::i18n::gettext("_Cancel"));
        let submit = gtk::Button::with_mnemonic(submit_label);
        submit.add_css_class("suggested-action");
        submit.set_sensitive(false);
        header.pack_start(&cancel);
        header.pack_end(&submit);

        let page = adw::PreferencesPage::new();
        let caption = gtk::Label::builder()
            .xalign(0.0)
            .wrap(true)
            .margin_top(6)
            .margin_bottom(12)
            .margin_start(12)
            .margin_end(12)
            .visible(false)
            .build();
        caption.add_css_class("caption");
        caption.add_css_class("error");

        let toolbar = adw::ToolbarView::new();
        toolbar.add_top_bar(&header);
        toolbar.set_content(Some(&page));
        toolbar.add_bottom_bar(&caption);
        dialog.set_child(Some(&toolbar));
        // A row reaches this only with activates-default set, which is
        // why every entry row of a form sets it.
        dialog.set_default_widget(Some(&submit));

        let dialog_for_cancel = dialog.downgrade();
        cancel.connect_clicked(move |_| {
            if let Some(dialog) = dialog_for_cancel.upgrade() {
                dialog.close();
            }
        });
        let form = Self {
            dialog: dialog.downgrade(),
            page,
            submit,
            caption,
        };
        (form, dialog)
    }

    /// An entry row that submits the form on Enter. A name typed into it
    /// is never markup.
    pub(super) fn entry_row(title: &str) -> adw::EntryRow {
        adw::EntryRow::builder()
            .title(title)
            .use_markup(false)
            .activates_default(true)
            .build()
    }

    /// Submit on only for a valid form, and `problem` under the fields.
    pub(super) fn show_state(&self, valid: bool, problem: Option<String>) {
        self.submit.set_sensitive(valid);
        match problem {
            Some(problem) => {
                self.caption.set_label(&problem);
                self.caption.set_visible(true);
            }
            None => self.caption.set_visible(false),
        }
    }

    #[cfg(test)]
    pub(super) fn caption(&self) -> Option<String> {
        self.caption.is_visible().then(|| self.caption.label().to_string())
    }

    pub(super) fn close(&self) {
        if let Some(dialog) = self.dialog.upgrade() {
            dialog.close();
        }
    }
}

/// The dialog keeps `state` until GTK lets the dialog go, once it closes
/// or with its window. The form's handlers hold the state weakly, and
/// the row that opens a form keeps nothing, so without this every
/// control would stop answering as soon as the form opened.
pub(super) fn give_state<T: 'static>(dialog: &adw::Dialog, state: Rc<T>) {
    // Never disconnected: it runs once, as the dialog is disposed.
    let _owner = dialog.add_weak_ref_notify_local(move || drop(state));
}

/// The `error` style on a field the problem shown is about.
pub(super) fn mark_invalid(widget: &impl IsA<gtk::Widget>, invalid: bool) {
    match invalid {
        true => widget.add_css_class("error"),
        false => widget.remove_css_class("error"),
    }
}

/// A GtkPopoverMenu reads an underscore in a label as a mnemonic, so a
/// column name keeps its underscores by doubling them.
pub(super) fn menu_label(text: &str) -> String {
    text.replace('_', "__")
}

#[cfg(test)]
pub(super) mod tests {
    use std::time::Duration;

    use super::*;

    pub(crate) const WAIT: Duration = Duration::from_secs(5);

    /// The GtkText inside an AdwEntryRow. Enter reaches the row through
    /// this delegate, so that is where a test presses it.
    pub(crate) fn press_enter(row: &adw::EntryRow) {
        let text = gtk::prelude::EditableExt::delegate(row)
            .and_then(|delegate| delegate.downcast::<gtk::Text>().ok())
            .expect("an AdwEntryRow delegates to a GtkText");
        text.emit_activate();
    }

    /// A mapped window: GtkButton refuses to activate an unrealized
    /// button, so a form that is not on screen would pass an Enter test
    /// for the wrong reason.
    pub(crate) fn window() -> adw::Window {
        adw::init().expect("libadwaita initialises under the test backend");
        let window = adw::Window::new();
        window.present();
        window
    }

    #[test]
    fn a_column_name_keeps_its_underscores_in_a_menu() {
        assert_eq!(menu_label("account_id"), "account__id");
    }

    /// A form handed to its dialog as the add dialogs hand theirs: the
    /// state holds the form, and the form its dialog.
    fn open_form(window: &adw::Window) -> (glib::WeakRef<adw::Dialog>, std::rc::Weak<FormDialog>) {
        let (form, dialog) = FormDialog::new("Add Index", "_Add");
        let state = Rc::new(form);
        let held = Rc::downgrade(&state);
        give_state(&dialog, state);
        dialog.present(Some(window.upcast_ref::<gtk::Widget>()));
        crate::test_support::drain_main_context();
        (dialog.downgrade(), held)
    }

    #[gtk4::test]
    fn an_open_form_keeps_its_state_until_it_closes() {
        let window = window();
        let (dialog, held) = open_form(&window);

        assert!(held.upgrade().is_some(), "the state went while the form was open");
        dialog.upgrade().expect("the open form").force_close();

        crate::test_support::wait_until(WAIT, || held.upgrade().is_none()).expect("a closed form kept its state");
        assert!(dialog.upgrade().is_none(), "a closed form stayed alive");
    }

    #[gtk4::test]
    fn a_form_lets_go_of_its_state_with_its_window() {
        let window = window();
        let (dialog, held) = open_form(&window);

        // AdwWindow lets its dialogs go as it is finalized, not as it is
        // destroyed, so the test's own reference has to go too.
        window.destroy();
        drop(window);

        crate::test_support::wait_until(WAIT, || held.upgrade().is_none())
            .expect("a form torn down with its window kept its state");
        assert!(
            dialog.upgrade().is_none(),
            "a form torn down with its window stayed alive"
        );
    }

    #[gtk4::test]
    fn a_form_dialog_starts_with_submit_off_and_as_its_default() {
        adw::init().expect("libadwaita initialises under the test backend");
        let (form, dialog) = FormDialog::new("Add Index", "_Add");

        assert_eq!(dialog.default_widget().as_ref(), Some(form.submit.upcast_ref()));
        assert!(!form.submit.is_sensitive());
        assert_eq!(form.caption(), None);
        form.show_state(false, Some("Index name is required.".to_owned()));
        assert_eq!(form.caption().as_deref(), Some("Index name is required."));
        form.show_state(true, None);
        assert!(form.submit.is_sensitive());
        assert_eq!(form.caption(), None);
    }
}
