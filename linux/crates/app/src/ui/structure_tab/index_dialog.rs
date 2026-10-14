//! Add Index: a name, Unique, and the key columns in order, each with
//! its own menu to sort it descending, move it or remove it.

use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::IndexInfo;

use super::form_dialog::{FormDialog, give_state, mark_invalid, menu_label};
use super::index_draft::{DraftKey, IndexDraft, IndexDraftError};

/// The dialog, which owns the form's state (`give_state`).
pub(super) struct IndexDialog {
    dialog: adw::Dialog,
    #[cfg(test)]
    inner: Rc<Inner>,
}

struct Inner {
    form: FormDialog,
    name_row: adw::EntryRow,
    keys_group: adw::PreferencesGroup,
    add_key_button: gtk::MenuButton,
    add_key_menu: gio::Menu,
    key_rows: RefCell<Vec<adw::ActionRow>>,
    /// The keys the rows show, so a change that leaves them alone does
    /// not build them again.
    shown_keys: RefCell<Option<Vec<DraftKey>>>,
    /// The draft's columns, in table order.
    columns: Vec<String>,
    /// The names the table's indexes already take.
    existing: Vec<String>,
    draft: RefCell<IndexDraft>,
    /// An empty name is a problem to point out only once the user has
    /// typed one.
    name_edited: Cell<bool>,
    refresh_queued: Cell<bool>,
    on_add: Box<dyn Fn(IndexInfo)>,
}

impl IndexDialog {
    pub(super) fn new(columns: Vec<String>, existing: Vec<String>, on_add: impl Fn(IndexInfo) + 'static) -> Self {
        let (form, dialog) = FormDialog::new(&crate::i18n::gettext("Add Index"), &crate::i18n::gettext("_Add"));
        let details = adw::PreferencesGroup::new();
        let name_row = FormDialog::entry_row(&crate::i18n::gettext("Name"));
        let unique_row = adw::SwitchRow::builder()
            .title(crate::i18n::gettext("Unique"))
            .subtitle(crate::i18n::gettext("Refuse rows that repeat the key columns' values"))
            .build();
        details.add(&name_row);
        details.add(&unique_row);

        let add_key_menu = gio::Menu::new();
        let add_key_button = gtk::MenuButton::builder()
            .icon_name(crate::ui::icons::LIST_ADD)
            .menu_model(&add_key_menu)
            .tooltip_text(crate::i18n::gettext("Add Key Column"))
            .valign(gtk::Align::Center)
            .build();
        add_key_button.add_css_class("flat");
        add_key_button.update_property(&[gtk::accessible::Property::Label(&crate::i18n::gettext(
            "Add Key Column",
        ))]);
        let keys_group = adw::PreferencesGroup::builder()
            .title(crate::i18n::gettext("Key Columns"))
            .header_suffix(&add_key_button)
            .build();
        form.page.add(&details);
        form.page.add(&keys_group);

        let inner = Rc::new(Inner {
            form,
            name_row: name_row.clone(),
            keys_group,
            add_key_button,
            add_key_menu,
            key_rows: RefCell::default(),
            shown_keys: RefCell::default(),
            columns,
            existing,
            draft: RefCell::default(),
            name_edited: Cell::new(false),
            refresh_queued: Cell::new(false),
            on_add: Box::new(on_add),
        });

        let actions = gio::SimpleActionGroup::new();
        let add_key = gio::SimpleAction::new("add-key", Some(glib::VariantTy::STRING));
        let weak = Rc::downgrade(&inner);
        add_key.connect_activate(move |_, parameter| {
            if let (Some(inner), Some(column)) = (weak.upgrade(), parameter.and_then(|value| value.str())) {
                inner.draft.borrow_mut().add_key(column);
                inner.refresh();
            }
        });
        actions.add_action(&add_key);
        dialog.insert_action_group("index", Some(&actions));

        let weak = Rc::downgrade(&inner);
        name_row.connect_changed(move |row| {
            if let Some(inner) = weak.upgrade() {
                inner.name_edited.set(true);
                inner.draft.borrow_mut().name = row.text().to_string();
                inner.refresh();
            }
        });
        let weak = Rc::downgrade(&inner);
        unique_row.connect_active_notify(move |row| {
            if let Some(inner) = weak.upgrade() {
                inner.draft.borrow_mut().unique = row.is_active();
            }
        });
        let weak = Rc::downgrade(&inner);
        inner.form.submit.connect_clicked(move |_| {
            if let Some(inner) = weak.upgrade() {
                inner.submit();
            }
        });
        inner.refresh();
        give_state(&dialog, inner.clone());
        Self {
            dialog,
            #[cfg(test)]
            inner,
        }
    }

    pub(super) fn present(&self, parent: &gtk::Widget) {
        self.dialog.present(Some(parent));
    }
}

impl Inner {
    fn submit(&self) {
        let valid = self.draft.borrow().validate(&self.existing);
        if let Ok(index) = valid {
            (self.on_add)(index);
            self.form.close();
        }
    }

    fn refresh(self: &Rc<Self>) {
        let errors = match self.draft.borrow().validate(&self.existing) {
            Ok(_) => Vec::new(),
            Err(errors) => errors,
        };
        let name_error = errors
            .iter()
            .copied()
            .find(|error| matches!(error, IndexDraftError::NameMissing | IndexDraftError::NameTaken))
            .filter(|_| self.name_edited.get());
        mark_invalid(&self.name_row, name_error.is_some());
        // An empty key list says so in the group's description.
        self.form
            .show_state(errors.is_empty(), name_error.map(IndexDraftError::message));
        self.show_keys();
    }

    /// The menu header and the rows of the keys, built again only when
    /// the keys changed.
    fn show_keys(self: &Rc<Self>) {
        let keys = self.draft.borrow().keys.clone();
        if self.shown_keys.borrow().as_ref() == Some(&keys) {
            return;
        }
        for row in self.key_rows.borrow_mut().drain(..) {
            self.keys_group.remove(&row);
        }
        let rows: Vec<adw::ActionRow> = keys
            .iter()
            .enumerate()
            .map(|(position, key)| self.key_row(position, key, keys.len()))
            .collect();
        for row in &rows {
            self.keys_group.add(row);
        }
        self.key_rows.replace(rows);
        self.keys_group.set_description(
            keys.is_empty()
                .then(|| crate::i18n::gettext("Add the columns the index sorts by."))
                .as_deref(),
        );

        self.add_key_menu.remove_all();
        let unused: Vec<String> = self
            .draft
            .borrow()
            .unused(&self.columns)
            .into_iter()
            .map(str::to_owned)
            .collect();
        for column in &unused {
            let item = gio::MenuItem::new(Some(&menu_label(column)), None);
            item.set_action_and_target_value(Some("index.add-key"), Some(&column.to_variant()));
            self.add_key_menu.append_item(&item);
        }
        self.add_key_button.set_sensitive(!unused.is_empty());
        self.shown_keys.replace(Some(keys));
    }

    fn key_row(self: &Rc<Self>, position: usize, key: &DraftKey, count: usize) -> adw::ActionRow {
        let row = adw::ActionRow::builder().title(&key.column).use_markup(false).build();
        if key.descending {
            row.set_subtitle(&crate::i18n::gettext("Descending"));
        }
        let order = gio::Menu::new();
        order.append(Some(&crate::i18n::gettext("Sort _Descending")), Some("key.descending"));
        let moves = gio::Menu::new();
        moves.append(Some(&crate::i18n::gettext("Move _Up")), Some("key.move-up"));
        moves.append(Some(&crate::i18n::gettext("Move D_own")), Some("key.move-down"));
        let removal = gio::Menu::new();
        removal.append(Some(&crate::i18n::gettext("_Remove")), Some("key.remove"));
        let menu = gio::Menu::new();
        menu.append_section(None, &order);
        menu.append_section(None, &moves);
        menu.append_section(None, &removal);
        let button = gtk::MenuButton::builder()
            .icon_name(crate::ui::icons::VIEW_MORE)
            .menu_model(&menu)
            .tooltip_text(crate::i18n::gettext("Key Options"))
            .valign(gtk::Align::Center)
            .build();
        button.add_css_class("flat");
        button.update_property(&[gtk::accessible::Property::Label(&crate::i18n::gettext("Key Options"))]);
        row.add_suffix(&button);

        let actions = gio::SimpleActionGroup::new();
        let descending = gio::SimpleAction::new_stateful("descending", None, &key.descending.to_variant());
        let weak = Rc::downgrade(self);
        descending.connect_activate(move |action, _| {
            let next = !action.state().and_then(|state| state.get::<bool>()).unwrap_or(false);
            action.set_state(&next.to_variant());
            edit_later(&weak, move |draft| draft.set_descending(position, next));
        });
        actions.add_action(&descending);
        let steps = [
            ("move-up", position > 0, Edit::Up),
            ("move-down", position + 1 < count, Edit::Down),
            ("remove", true, Edit::Remove),
        ];
        for (name, enabled, edit) in steps {
            let action = gio::SimpleAction::new(name, None);
            action.set_enabled(enabled);
            let weak = Rc::downgrade(self);
            action.connect_activate(move |_, _| {
                edit_later(&weak, move |draft| match edit {
                    Edit::Up => draft.move_key(position, true),
                    Edit::Down => draft.move_key(position, false),
                    Edit::Remove => draft.remove_key(position),
                });
            });
            actions.add_action(&action);
        }
        row.insert_action_group("key", Some(&actions));
        row
    }
}

#[derive(Debug, Clone, Copy)]
enum Edit {
    Up,
    Down,
    Remove,
}

/// The draft changes at once, and the rows a moment later: the menu the
/// edit came from belongs to a row that is about to be replaced, and is
/// still closing.
fn edit_later(inner: &Weak<Inner>, edit: impl FnOnce(&mut IndexDraft)) {
    let Some(inner) = inner.upgrade() else {
        return;
    };
    edit(&mut inner.draft.borrow_mut());
    if inner.refresh_queued.replace(true) {
        return;
    }
    let weak = Rc::downgrade(&inner);
    glib::idle_add_local_once(move || {
        if let Some(inner) = weak.upgrade() {
            inner.refresh_queued.set(false);
            inner.refresh();
        }
    });
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::super::form_dialog::tests::{WAIT, press_enter, window};
    use super::*;
    use crate::test_support::{drain_main_context, wait_until};

    fn dialog(added: &Rc<RefCell<Vec<IndexInfo>>>) -> IndexDialog {
        let sink = added.clone();
        IndexDialog::new(
            vec!["id".to_owned(), "email".to_owned(), "created_at".to_owned()],
            vec!["users_pkey".to_owned()],
            move |index| sink.borrow_mut().push(index),
        )
    }

    fn add_key(dialog: &IndexDialog, column: &str) {
        assert!(
            dialog
                .dialog
                .activate_action("index.add-key", Some(&column.to_variant()))
                .is_ok(),
            "no index.add-key action"
        );
    }

    fn key_titles(dialog: &IndexDialog) -> Vec<String> {
        dialog
            .inner
            .key_rows
            .borrow()
            .iter()
            .map(|row| row.title().to_string())
            .collect()
    }

    #[gtk4::test]
    fn add_button_insensitive_until_valid() {
        adw::init().expect("libadwaita initialises under the test backend");
        let added = Rc::new(RefCell::new(Vec::new()));
        let dialog = dialog(&added);
        let submit = dialog.inner.form.submit.clone();

        assert!(!submit.is_sensitive());
        dialog.inner.name_row.set_text("by_email");
        assert!(!submit.is_sensitive(), "an index without keys can be added");
        add_key(&dialog, "email");
        assert!(submit.is_sensitive());
        dialog.inner.name_row.set_text("USERS_PKEY");
        assert!(!submit.is_sensitive(), "a name the table already has can be added");
        assert_eq!(
            dialog.inner.form.caption().as_deref(),
            Some("The table already has an index with this name.")
        );
    }

    #[gtk4::test]
    fn empty_name_row_has_error_class() {
        adw::init().expect("libadwaita initialises under the test backend");
        let added = Rc::new(RefCell::new(Vec::new()));
        let dialog = dialog(&added);
        let name_row = dialog.inner.name_row.clone();

        assert!(!name_row.has_css_class("error"), "an untouched form opens marked wrong");
        assert_eq!(dialog.inner.form.caption(), None);
        name_row.set_text("by_email");
        name_row.set_text("");

        assert!(name_row.has_css_class("error"));
        assert_eq!(dialog.inner.form.caption().as_deref(), Some("Index name is required."));
        name_row.set_text("by_email");
        assert!(!name_row.has_css_class("error"));
    }

    #[gtk4::test]
    fn the_add_menu_offers_only_unused_columns() {
        adw::init().expect("libadwaita initialises under the test backend");
        let added = Rc::new(RefCell::new(Vec::new()));
        let dialog = dialog(&added);
        let labels = |dialog: &IndexDialog| -> Vec<String> {
            let menu = &dialog.inner.add_key_menu;
            (0..menu.n_items())
                .filter_map(|item| menu.item_attribute_value(item, "label", Some(glib::VariantTy::STRING)))
                .filter_map(|label| label.str().map(str::to_owned))
                .collect()
        };

        assert_eq!(labels(&dialog), ["id", "email", "created__at"]);
        add_key(&dialog, "id");
        add_key(&dialog, "email");
        add_key(&dialog, "created_at");

        assert!(labels(&dialog).is_empty());
        assert!(!dialog.inner.add_key_button.is_sensitive());
    }

    #[gtk4::test]
    fn move_up_reorders_keys() {
        let window = window();
        let added = Rc::new(RefCell::new(Vec::new()));
        let dialog = dialog(&added);
        dialog.present(window.upcast_ref());
        add_key(&dialog, "email");
        add_key(&dialog, "created_at");
        let second = dialog.inner.key_rows.borrow()[1].clone();

        assert!(second.activate_action("key.move-up", None).is_ok());
        drain_main_context();
        let first = dialog.inner.key_rows.borrow()[0].clone();
        assert!(first.activate_action("key.descending", None).is_ok());
        drain_main_context();

        assert_eq!(key_titles(&dialog), ["created_at", "email"]);
        dialog.inner.name_row.set_text("by_created");
        dialog.inner.form.submit.emit_clicked();
        let index = added.borrow().first().cloned().expect("the index was added");
        assert_eq!(
            index
                .keys
                .iter()
                .map(|key| (key.column_name().unwrap_or_default().to_owned(), key.descending()))
                .collect::<Vec<_>>(),
            [("created_at".to_owned(), true), ("email".to_owned(), false)]
        );
        let first = dialog.inner.key_rows.borrow()[0].clone();
        assert_eq!(first.subtitle().as_deref(), Some("Descending"));
    }

    #[gtk4::test]
    fn removing_the_last_key_leaves_the_form_invalid() {
        adw::init().expect("libadwaita initialises under the test backend");
        let added = Rc::new(RefCell::new(Vec::new()));
        let dialog = dialog(&added);
        dialog.inner.name_row.set_text("by_email");
        add_key(&dialog, "email");
        let row = dialog.inner.key_rows.borrow()[0].clone();

        assert!(row.activate_action("key.remove", None).is_ok());
        drain_main_context();

        assert!(key_titles(&dialog).is_empty());
        assert!(!dialog.inner.form.submit.is_sensitive());
        assert_eq!(
            dialog.inner.keys_group.description().as_deref(),
            Some("Add the columns the index sorts by.")
        );
    }

    #[gtk4::test]
    fn enter_on_valid_form_submits() {
        let window = window();
        let added = Rc::new(RefCell::new(Vec::new()));
        let dialog = dialog(&added);
        dialog.present(window.upcast_ref());
        let name_row = dialog.inner.name_row.clone();
        wait_until(WAIT, || name_row.is_mapped()).expect("the form never appeared");
        name_row.set_text("by_email");
        add_key(&dialog, "email");

        press_enter(&name_row);

        wait_until(WAIT, || added.borrow().len() == 1).expect("Enter did not add the index");
        assert_eq!(added.borrow()[0].name, "by_email");
    }

    #[gtk4::test]
    fn enter_on_invalid_form_does_nothing() {
        let window = window();
        let added = Rc::new(RefCell::new(Vec::new()));
        let dialog = dialog(&added);
        dialog.present(window.upcast_ref());
        let name_row = dialog.inner.name_row.clone();
        wait_until(WAIT, || name_row.is_mapped()).expect("the form never appeared");
        name_row.set_text("by_email");

        press_enter(&name_row);

        assert!(
            wait_until(Duration::from_secs(1), || !added.borrow().is_empty()).is_err(),
            "Enter added an index with no keys"
        );
        assert!(name_row.is_mapped(), "Enter closed an invalid form");
    }
}
