//! Add Foreign Key: a name, the referenced table picked from the
//! catalog, the columns of the key each paired with a column of that
//! table, and what deleting or updating a referenced row does.

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::gio;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::ForeignKeyInfo;
use tablepro_core::ddl::ReferentialAction;
use tablepro_core::meta::{ObjectScope, TableRef};
use tablepro_session::runtime::{TaskFailure, Tasks};
use tablepro_session::{OperationError, Session};

use super::foreign_key_draft::{ForeignKeyDraft, ForeignKeyDraftError};
use super::form_dialog::{FormDialog, give_state, mark_invalid};
use super::referential_action_label::{action_at, action_labels};
use super::table_choice_object::{TableChoiceObject, table_choices};

pub(super) struct ForeignKeyDialogInit {
    /// The draft's columns, in table order.
    pub columns: Vec<String>,
    /// The names the table's foreign keys already take.
    pub existing: Vec<String>,
    /// The actions the engine takes, in the order it offers them.
    pub actions: &'static [ReferentialAction],
    pub session: Arc<Session>,
    pub tasks: Tasks,
}

/// The dialog, which owns the form's state (`give_state`).
pub(super) struct ForeignKeyDialog {
    dialog: adw::Dialog,
    #[cfg(test)]
    inner: Rc<Inner>,
}

/// The pair rows as built: the key's columns and the referenced table's,
/// once read. A pair chosen in a row changes neither.
type PairShape = (Vec<String>, Option<Vec<String>>);

struct Inner {
    form: FormDialog,
    name_row: adw::EntryRow,
    table_row: adw::ComboRow,
    table_spinner: adw::Spinner,
    tables: gio::ListStore,
    column_checks: Vec<(String, gtk::CheckButton)>,
    pairs_group: adw::PreferencesGroup,
    pair_rows: RefCell<Vec<(String, adw::ComboRow)>>,
    shown_pairs: RefCell<Option<PairShape>>,
    columns: Vec<String>,
    existing: Vec<String>,
    session: Arc<Session>,
    tasks: Tasks,
    draft: RefCell<ForeignKeyDraft>,
    /// The chosen table's columns, once read.
    referenced_columns: RefCell<Option<Vec<String>>>,
    /// Counts the tables chosen, so the columns of one chosen earlier,
    /// read after it, are dropped.
    choice: Cell<u64>,
    /// A read of the catalog that failed, which the form says first.
    load_error: RefCell<Option<String>>,
    name_edited: Cell<bool>,
    columns_edited: Cell<bool>,
    on_add: Box<dyn Fn(ForeignKeyInfo)>,
}

impl ForeignKeyDialog {
    pub(super) fn new(init: ForeignKeyDialogInit, on_add: impl Fn(ForeignKeyInfo) + 'static) -> Self {
        let ForeignKeyDialogInit {
            columns,
            existing,
            actions,
            session,
            tasks,
        } = init;
        let (form, dialog) = FormDialog::new(&crate::i18n::gettext("Add Foreign Key"), &crate::i18n::gettext("_Add"));
        let details = adw::PreferencesGroup::new();
        let name_row = FormDialog::entry_row(&crate::i18n::gettext("Name"));
        details.add(&name_row);

        let tables = gio::ListStore::new::<TableChoiceObject>();
        let table_row = adw::ComboRow::builder()
            .title(crate::i18n::gettext("Referenced Table"))
            .model(&tables)
            .enable_search(true)
            .sensitive(false)
            .build();
        table_row.set_search_match_mode(gtk::StringFilterMatchMode::Substring);
        table_row.set_expression(Some(&gtk::PropertyExpression::new(
            TableChoiceObject::static_type(),
            None::<&gtk::Expression>,
            "label",
        )));
        let table_spinner = adw::Spinner::new();
        table_row.add_suffix(&table_spinner);
        let references = adw::PreferencesGroup::new();
        references.add(&table_row);

        let checklist = adw::PreferencesGroup::builder()
            .title(crate::i18n::gettext("Columns"))
            .description(crate::i18n::gettext(
                "The columns of this table that hold the reference.",
            ))
            .build();
        let column_checks: Vec<(String, gtk::CheckButton)> = columns
            .iter()
            .map(|column| {
                let row = adw::ActionRow::builder().title(column).use_markup(false).build();
                let check = gtk::CheckButton::builder().valign(gtk::Align::Center).build();
                row.add_prefix(&check);
                row.set_activatable_widget(Some(&check));
                checklist.add(&row);
                (column.clone(), check)
            })
            .collect();

        let pairs_group = adw::PreferencesGroup::builder()
            .title(crate::i18n::gettext("Referenced Columns"))
            .visible(false)
            .build();

        let labels = action_labels(actions);
        let labels: Vec<&str> = labels.iter().map(String::as_str).collect();
        let on_delete_row = adw::ComboRow::builder()
            .title(crate::i18n::gettext("On Delete"))
            .model(&gtk::StringList::new(&labels))
            .build();
        let on_update_row = adw::ComboRow::builder()
            .title(crate::i18n::gettext("On Update"))
            .model(&gtk::StringList::new(&labels))
            .build();
        let actions_group = adw::PreferencesGroup::builder()
            .title(crate::i18n::gettext("Actions"))
            .build();
        actions_group.add(&on_delete_row);
        actions_group.add(&on_update_row);

        for group in [&details, &references, &checklist, &pairs_group, &actions_group] {
            form.page.add(group);
        }

        let inner = Rc::new(Inner {
            form,
            name_row: name_row.clone(),
            table_row: table_row.clone(),
            table_spinner,
            tables,
            column_checks,
            pairs_group,
            pair_rows: RefCell::default(),
            shown_pairs: RefCell::default(),
            columns,
            existing,
            session,
            tasks,
            draft: RefCell::default(),
            referenced_columns: RefCell::default(),
            choice: Cell::new(0),
            load_error: RefCell::default(),
            name_edited: Cell::new(false),
            columns_edited: Cell::new(false),
            on_add: Box::new(on_add),
        });

        let weak = Rc::downgrade(&inner);
        name_row.connect_changed(move |row| {
            if let Some(inner) = weak.upgrade() {
                inner.name_edited.set(true);
                inner.draft.borrow_mut().name = row.text().to_string();
                inner.refresh();
            }
        });
        for (column, check) in &inner.column_checks {
            let (weak, column) = (Rc::downgrade(&inner), column.clone());
            check.connect_toggled(move |check| {
                if let Some(inner) = weak.upgrade() {
                    inner.columns_edited.set(true);
                    let referenced = inner.referenced_columns.borrow().clone().unwrap_or_default();
                    inner
                        .draft
                        .borrow_mut()
                        .set_checked(&inner.columns, &column, check.is_active(), &referenced);
                    inner.refresh();
                }
            });
        }
        for (row, on_delete) in [(&on_delete_row, true), (&on_update_row, false)] {
            let weak = Rc::downgrade(&inner);
            row.connect_selected_notify(move |row| {
                if let Some(inner) = weak.upgrade() {
                    let action = action_at(actions, row.selected());
                    let mut draft = inner.draft.borrow_mut();
                    match on_delete {
                        true => draft.on_delete = action,
                        false => draft.on_update = action,
                    }
                }
            });
        }
        let weak = Rc::downgrade(&inner);
        inner.form.submit.connect_clicked(move |_| {
            if let Some(inner) = weak.upgrade() {
                inner.submit();
            }
        });
        inner.load_tables();
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
        if let Ok(key) = valid {
            (self.on_add)(key);
            self.form.close();
        }
    }

    /// The catalog's tables, read once as the dialog opens.
    fn load_tables(self: &Rc<Self>) {
        let session = self.session.clone();
        let weak = Rc::downgrade(self);
        let _delivery = crate::runtime::spawn_and_deliver(
            &self.tasks,
            async move { session.objects(ObjectScope::AllSchemas).await },
            move |read| {
                if let Some(inner) = weak.upgrade() {
                    inner.tables_read(read);
                }
            },
        );
    }

    fn tables_read(
        self: &Rc<Self>,
        read: Result<Result<Arc<[tablepro_core::meta::ObjectInfo]>, Arc<OperationError>>, TaskFailure>,
    ) {
        self.table_spinner.set_visible(false);
        match settled(read) {
            Ok(objects) => {
                // The first table is no more the user's choice than any
                // other, so the row starts on none.
                let choices: Vec<TableChoiceObject> = std::iter::once(TableChoiceObject::none())
                    .chain(table_choices(&objects))
                    .collect();
                self.tables.splice(0, self.tables.n_items(), &choices);
                self.table_row.set_selected(0);
                self.table_row.set_sensitive(true);
                let weak = Rc::downgrade(self);
                self.table_row.connect_selected_item_notify(move |row| {
                    if let Some(inner) = weak.upgrade() {
                        let table = row
                            .selected_item()
                            .and_downcast::<TableChoiceObject>()
                            .and_then(|choice| choice.table().cloned());
                        inner.choose_table(table);
                    }
                });
            }
            Err(error) => {
                self.load_error.replace(Some(crate::i18n::gettext_f(
                    "Couldn't read the tables: {error}",
                    &[("error", &error)],
                )));
            }
        }
        self.refresh();
    }

    /// The key's columns lose their partners until the new table's
    /// columns are read, then pair with the ones of the same name.
    fn choose_table(self: &Rc<Self>, table: Option<TableRef>) {
        let choice = self.choice.get() + 1;
        self.choice.set(choice);
        self.referenced_columns.replace(None);
        self.load_error.replace(None);
        {
            let mut draft = self.draft.borrow_mut();
            draft.referenced = table.clone();
            draft.pair_with(&[]);
        }
        self.table_spinner.set_visible(table.is_some());
        if let Some(table) = table {
            let session = self.session.clone();
            let weak = Rc::downgrade(self);
            let read_table = table.clone();
            let _delivery = crate::runtime::spawn_and_deliver(
                &self.tasks,
                async move { session.columns(read_table).await },
                move |read| {
                    if let Some(inner) = weak.upgrade()
                        && inner.choice.get() == choice
                    {
                        inner.columns_read(&table, read);
                    }
                },
            );
        }
        self.refresh();
    }

    fn columns_read(
        self: &Rc<Self>,
        table: &TableRef,
        read: Result<Result<Arc<[tablepro_core::ColumnInfo]>, Arc<OperationError>>, TaskFailure>,
    ) {
        self.table_spinner.set_visible(false);
        match settled(read) {
            Ok(columns) => {
                let names: Vec<String> = columns.iter().map(|column| column.name.clone()).collect();
                self.draft.borrow_mut().pair_with(&names);
                self.referenced_columns.replace(Some(names));
            }
            Err(error) => {
                self.load_error.replace(Some(crate::i18n::gettext_f(
                    "Couldn't read the columns of {table}: {error}",
                    &[("table", &table.name), ("error", &error)],
                )));
            }
        }
        self.refresh();
    }

    fn refresh(self: &Rc<Self>) {
        self.show_pairs();
        let errors = match self.draft.borrow().validate(&self.existing) {
            Ok(_) => Vec::new(),
            Err(errors) => errors,
        };
        let loaded = self.referenced_columns.borrow().is_some();
        let shown: Vec<&ForeignKeyDraftError> = errors
            .iter()
            .filter(|error| match error {
                ForeignKeyDraftError::NameMissing | ForeignKeyDraftError::NameTaken => self.name_edited.get(),
                ForeignKeyDraftError::NoTable | ForeignKeyDraftError::NoPairs => self.columns_edited.get(),
                ForeignKeyDraftError::UnpairedColumn(_) => loaded,
            })
            .collect();
        mark_invalid(
            &self.name_row,
            shown.iter().any(|error| {
                matches!(
                    error,
                    ForeignKeyDraftError::NameMissing | ForeignKeyDraftError::NameTaken
                )
            }),
        );
        mark_invalid(
            &self.table_row,
            shown.iter().any(|error| matches!(error, ForeignKeyDraftError::NoTable)),
        );
        for (column, row) in self.pair_rows.borrow().iter() {
            let unpaired = shown
                .iter()
                .any(|error| matches!(error, ForeignKeyDraftError::UnpairedColumn(unpaired) if unpaired == column));
            mark_invalid(row, unpaired);
        }
        let problem = self
            .load_error
            .borrow()
            .clone()
            .or_else(|| shown.first().map(|error| error.message()));
        self.form.show_state(errors.is_empty(), problem);
    }

    /// A row per column of the key, choosing among the referenced
    /// table's columns, built again only when the key's columns or the
    /// table's change.
    fn show_pairs(self: &Rc<Self>) {
        let pairs = self.draft.borrow().pairs.clone();
        let referenced = self.referenced_columns.borrow().clone();
        let shape: PairShape = (
            pairs.iter().map(|(column, _)| column.clone()).collect(),
            referenced.clone(),
        );
        if self.shown_pairs.borrow().as_ref() == Some(&shape) {
            return;
        }
        for (_, row) in self.pair_rows.borrow_mut().drain(..) {
            self.pairs_group.remove(&row);
        }
        let candidates = referenced.unwrap_or_default();
        // A column pairs with nothing until the user or a matching name
        // pairs it, never with whichever column comes first.
        let none = crate::i18n::gettext("None");
        let labels: Vec<&str> = std::iter::once(none.as_str())
            .chain(candidates.iter().map(String::as_str))
            .collect();
        let rows: Vec<(String, adw::ComboRow)> = pairs
            .iter()
            .map(|(column, partner)| {
                let row = adw::ComboRow::builder()
                    .title(crate::i18n::gettext_f("{column} references", &[("column", column)]))
                    .use_markup(false)
                    .model(&gtk::StringList::new(&labels))
                    .sensitive(shape.1.is_some())
                    .build();
                let selected = partner
                    .as_ref()
                    .and_then(|partner| candidates.iter().position(|candidate| candidate == partner))
                    .and_then(|position| u32::try_from(position + 1).ok())
                    .unwrap_or(0);
                row.set_selected(selected);
                let (weak, column_for_choice, candidates) = (Rc::downgrade(self), column.clone(), candidates.clone());
                row.connect_selected_notify(move |row| {
                    if let Some(inner) = weak.upgrade() {
                        let partner = row
                            .selected()
                            .checked_sub(1)
                            .and_then(|position| usize::try_from(position).ok())
                            .and_then(|position| candidates.get(position).cloned());
                        inner.draft.borrow_mut().pair(&column_for_choice, partner);
                        inner.refresh();
                    }
                });
                self.pairs_group.add(&row);
                (column.clone(), row)
            })
            .collect();
        self.pairs_group.set_visible(!rows.is_empty());
        self.pair_rows.replace(rows);
        self.shown_pairs.replace(Some(shape));
    }
}

/// A read that never answered reads like the operation it ran.
fn settled<T>(read: Result<Result<T, Arc<OperationError>>, TaskFailure>) -> Result<T, String> {
    match read {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(error)) => Err(crate::ui::error_text::operation_error_message(&error)),
        Err(failure) => Err(crate::ui::error_text::operation_error_message(&OperationError::from(
            failure,
        ))),
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnDefault, ColumnType};
    use tablepro_core::meta::{ObjectInfo, ObjectKind};
    use tablepro_core::{ColumnInfo, DriverError};
    use tablepro_test_support::{ConnectionScript, FakeReply};

    use super::super::form_dialog::tests::{WAIT, window};
    use super::*;
    use crate::test_support::{FakeSession, drain_main_context, wait_until};

    struct Harness {
        dialog: Option<ForeignKeyDialog>,
        added: Rc<RefCell<Vec<ForeignKeyInfo>>>,
        _window: adw::Window,
        _fake: FakeSession,
        runtime: Option<crate::runtime::AppRuntime>,
    }

    impl Harness {
        fn open(script: ConnectionScript) -> Self {
            let window = window();
            let runtime = crate::test_support::test_runtime();
            let fake = FakeSession::start(script, [], runtime.tasks());
            let added = Rc::new(RefCell::new(Vec::new()));
            let sink = added.clone();
            let dialog = ForeignKeyDialog::new(
                ForeignKeyDialogInit {
                    columns: vec!["id".to_owned(), "account_id".to_owned(), "owner_id".to_owned()],
                    existing: vec!["fk_taken".to_owned()],
                    actions: &ReferentialAction::ALL,
                    session: fake.session.clone(),
                    tasks: runtime.tasks(),
                },
                move |key| sink.borrow_mut().push(key),
            );
            dialog.present(window.upcast_ref());
            Self {
                dialog: Some(dialog),
                added,
                _window: window,
                _fake: fake,
                runtime: Some(runtime),
            }
        }

        fn inner(&self) -> &Rc<Inner> {
            &self.dialog.as_ref().expect("the dialog is open").inner
        }

        fn wait_for_tables(&self) {
            let inner = self.inner().clone();
            wait_until(WAIT, || inner.table_row.is_sensitive()).expect("the tables to be read");
        }

        fn check(&self, column: &str) {
            let check = self
                .inner()
                .column_checks
                .iter()
                .find(|(name, _)| name == column)
                .map(|(_, check)| check.clone())
                .expect("a check for the column");
            check.set_active(true);
        }

        fn pair_row(&self, column: &str) -> adw::ComboRow {
            self.inner()
                .pair_rows
                .borrow()
                .iter()
                .find(|(name, _)| name == column)
                .map(|(_, row)| row.clone())
                .expect("a pair row for the column")
        }
    }

    impl Drop for Harness {
        fn drop(&mut self) {
            if let Some(dialog) = self.dialog.take() {
                dialog.dialog.force_close();
            }
            drain_main_context();
            if let Some(runtime) = self.runtime.take() {
                runtime.shutdown();
            }
        }
    }

    fn object(name: &str, kind: ObjectKind) -> ObjectInfo {
        ObjectInfo {
            schema: Some("public".to_owned()),
            name: name.to_owned(),
            kind,
        }
    }

    fn column(name: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: ColumnType::untyped_text("integer"),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn catalog() -> ConnectionScript {
        let mut script = ConnectionScript::default();
        script.list_objects.always(FakeReply::ok(vec![
            object("users", ObjectKind::Table),
            object("active_users", ObjectKind::View),
            object("accounts", ObjectKind::Table),
        ]));
        script
            .fetch_columns
            .always(FakeReply::ok(vec![column("id"), column("owner_id")]));
        script
    }

    fn table_labels(inner: &Inner) -> Vec<String> {
        (0..inner.tables.n_items())
            .filter_map(|position| inner.tables.item(position).and_downcast::<TableChoiceObject>())
            .map(|choice| choice.label())
            .collect()
    }

    #[gtk4::test]
    fn referenced_table_combo_searches_catalog_tables() {
        let harness = Harness::open(catalog());

        harness.wait_for_tables();
        let inner = harness.inner();

        assert_eq!(table_labels(inner), ["None", "accounts", "users"]);
        assert!(inner.table_row.enables_search());
        assert_eq!(
            inner.table_row.search_match_mode(),
            gtk::StringFilterMatchMode::Substring
        );
        assert!(inner.table_row.expression().is_some());
        assert_eq!(inner.table_row.selected(), 0);
        assert!(!inner.table_spinner.is_visible());
        assert_eq!(inner.draft.borrow().referenced, None);
    }

    #[gtk4::test]
    fn choosing_table_loads_columns_and_autopairs_same_name() {
        let harness = Harness::open(catalog());
        harness.wait_for_tables();
        let inner = harness.inner().clone();
        inner.name_row.set_text("fk_owner");
        harness.check("owner_id");
        assert!(!harness.pair_row("owner_id").is_sensitive());
        assert_eq!(
            inner.form.caption().as_deref(),
            Some("Choose the table the key references.")
        );

        inner.table_row.set_selected(1);
        wait_until(WAIT, || inner.referenced_columns.borrow().is_some()).expect("the columns to be read");

        let pair = harness.pair_row("owner_id");
        assert!(pair.is_sensitive());
        assert_eq!(
            pair.selected_item()
                .and_downcast::<gtk::StringObject>()
                .map(|item| item.string().to_string())
                .as_deref(),
            Some("owner_id")
        );
        assert!(inner.form.submit.is_sensitive());
        inner.form.submit.emit_clicked();
        let added = harness.added.borrow();
        assert_eq!(added.len(), 1);
        assert_eq!(added[0].columns, ["owner_id"]);
        assert_eq!(added[0].ref_columns, ["owner_id"]);
        assert_eq!(
            (added[0].ref_schema.as_deref(), added[0].ref_table.as_str()),
            (Some("public"), "accounts")
        );
        assert_eq!((added[0].on_delete, added[0].on_update), (None, None));
    }

    #[gtk4::test]
    fn a_column_with_no_partner_waits_for_one() {
        let harness = Harness::open(catalog());
        harness.wait_for_tables();
        let inner = harness.inner().clone();
        inner.name_row.set_text("fk_account");
        harness.check("account_id");
        inner.table_row.set_selected(1);
        wait_until(WAIT, || inner.referenced_columns.borrow().is_some()).expect("the columns to be read");

        let pair = harness.pair_row("account_id");
        assert_eq!(pair.selected(), 0);
        assert!(pair.has_css_class("error"));
        assert!(!inner.form.submit.is_sensitive());
        assert_eq!(
            inner.form.caption().as_deref(),
            Some("Choose the column “account_id” references.")
        );

        pair.set_selected(1);

        assert!(!pair.has_css_class("error"));
        assert!(inner.form.submit.is_sensitive());
        assert_eq!(
            inner.draft.borrow().pairs,
            [("account_id".to_owned(), Some("id".to_owned()))]
        );
    }

    #[gtk4::test]
    fn a_catalog_that_cannot_be_read_says_so() {
        let mut script = ConnectionScript::default();
        script
            .list_objects
            .always(FakeReply::err(DriverError::server("permission denied")));
        let harness = Harness::open(script);
        let inner = harness.inner().clone();

        wait_until(WAIT, || inner.form.caption().is_some()).expect("the failure to show");

        assert!(
            inner
                .form
                .caption()
                .is_some_and(|caption| caption.starts_with("Couldn't read the tables:")),
            "{:?}",
            inner.form.caption()
        );
        assert!(!inner.table_row.is_sensitive());
        assert!(!inner.table_spinner.is_visible());
    }
}
