//! The New Schema and New Database forms: only the options the engine
//! takes, the server's own choices in the pickers, and Create on only
//! once the statement builds.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;

use tablepro_core::WriteKind;
use tablepro_core::ddl::{
    self, BuildDdlError, CatalogCapabilities, CatalogOption, CharacterSet, DatabaseChoices, DatabaseDraft,
    DatabaseNoun, DdlOperation, DdlPlan, KeyspaceReplication, SchemaDraft,
};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::TableRef;

use super::catalog_ops::{CatalogInput, CatalogLanded, asks_first, read_choices};
use super::{WorkspaceInput, WorkspaceModel, WorkspaceSender};
use crate::i18n::{gettext, gettext_f};
use crate::runtime::DeliverInput;
use crate::ui::error_text;
use crate::ui::form_dialog::{FormDialog, give_state};
use crate::ui::write_confirmation::{self, WriteConfirmation};
use crate::workspace::database_target;

/// A picker this long gets a search entry.
const SEARCHABLE: usize = 12;
const NETWORK_TOPOLOGY: u32 = 0;
const SIMPLE: u32 = 1;

/// Which form the server's choices were read for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CatalogForm {
    Schema,
    Database,
}

impl WorkspaceModel {
    /// Sidebar "New Schema…".
    pub(super) fn on_new_schema_prompt(&mut self) {
        let Some((session, _, capabilities)) = self.writable_catalog() else {
            return;
        };
        if !capabilities.create_schema {
            self.refuse_catalog_change(&gettext("Cannot Create Schema"), DdlOperation::CreateSchema);
            return;
        }
        self.read_choices_for(CatalogForm::Schema, session, capabilities.schema_owner);
    }

    /// "New Database…" or "New Keyspace…" on a connection's row.
    pub(super) fn on_new_database_prompt(&mut self) {
        let Some((session, _, capabilities)) = self.writable_catalog() else {
            return;
        };
        if !capabilities.create_database {
            self.refuse_catalog_change(&gettext("Cannot Create Database"), DdlOperation::CreateDatabase);
            return;
        }
        let fields = capabilities.database_fields;
        let picks = fields.owner
            || fields.template
            || fields.encoding
            || fields.locale
            || fields.character_set
            || fields.collation
            || fields.replication
            || capabilities.on_cluster;
        self.read_choices_for(CatalogForm::Database, session, picks);
    }

    /// The form opens once the server's choices are read, or at once
    /// where it has nothing to pick.
    fn read_choices_for(&self, form: CatalogForm, session: Arc<tablepro_session::Session>, picks: bool) {
        if !picks {
            self.present_catalog_form(form, DatabaseChoices::default());
            return;
        }
        let input = self.input.clone();
        crate::runtime::spawn_and_deliver(&self.context.tasks, read_choices(session), move |read| {
            let choices = read.ok().flatten().map(Box::new);
            input.deliver(WorkspaceInput::Catalog(CatalogInput::ChoicesRead { form, choices }));
        });
    }

    pub(super) fn present_catalog_form(&self, form: CatalogForm, choices: DatabaseChoices) {
        match form {
            CatalogForm::Schema => self.present_new_schema(choices),
            CatalogForm::Database => self.present_new_database(choices),
        }
    }

    fn present_new_schema(&self, choices: DatabaseChoices) {
        let Some((session, dialect, capabilities)) = self.writable_catalog() else {
            return;
        };
        let (form, dialog) = FormDialog::new(&gettext("New Schema"), &gettext("_Create"));
        let group = adw::PreferencesGroup::new();
        let name = FormDialog::entry_row(&gettext("Name"));
        group.add(&name);
        let owner = capabilities.schema_owner.then(|| {
            Picker::new(
                &group,
                &gettext("Owner"),
                default_entry(choices.defaults.owner.as_deref()),
                choices.owners,
            )
        });
        form.page.add(&group);
        let state = Rc::new(SchemaForm {
            form,
            name,
            owner,
            dialect,
            capabilities,
        });
        let weak = Rc::downgrade(&state);
        let check = Rc::new(move || {
            if let Some(state) = weak.upgrade() {
                state.check();
            }
        });
        let changed = check.clone();
        state.name.connect_changed(move |_| changed());
        if let Some(owner) = &state.owner {
            owner.row.connect_selected_notify(move |_| check());
        }
        let (input, parent, asks) = (self.input.clone(), self.parent_ref(), asks_first(&session));
        let submitting = Rc::downgrade(&state);
        state.form.submit.connect_clicked(move |_| {
            if let Some(state) = submitting.upgrade() {
                state.submit(&input, parent.as_ref(), asks.clone());
            }
        });
        state.check();
        give_state(&dialog, state);
        dialog.present(self.dialog_parent().as_ref());
    }

    fn present_new_database(&self, choices: DatabaseChoices) {
        let Some((session, dialect, capabilities)) = self.writable_catalog() else {
            return;
        };
        let title = match capabilities.database_noun {
            DatabaseNoun::Keyspace => gettext("New Keyspace"),
            DatabaseNoun::Database => gettext("New Database"),
        };
        let (form, dialog) = FormDialog::new(&title, &gettext("_Create"));
        let state = Rc::new(database_form(form, choices, dialect, capabilities));
        state.follow_character_set();
        connect_database_form(&state);
        let (input, parent, asks) = (self.input.clone(), self.parent_ref(), asks_first(&session));
        let submitting = Rc::downgrade(&state);
        state.form.submit.connect_clicked(move |_| {
            if let Some(state) = submitting.upgrade() {
                state.submit(&input, parent.as_ref(), asks.clone());
            }
        });
        state.check();
        give_state(&dialog, state);
        dialog.present(self.dialog_parent().as_ref());
    }

    /// The window, held weakly by a form that outlives nothing of it.
    fn parent_ref(&self) -> Option<glib::WeakRef<gtk::Widget>> {
        self.dialog_parent().map(|parent| parent.downgrade())
    }

    pub(super) fn on_create_schema(&mut self, draft: SchemaDraft) {
        let target = TableRef::new(Some(draft.name.clone()), "");
        self.start_catalog_change(
            WriteKind::SchemaChanges,
            target,
            move |dialect, _| ddl::plan_create_schema(dialect, &draft),
            move |result| match result {
                Ok(()) => WorkspaceInput::Catalog(CatalogInput::Landed(CatalogLanded::SchemaCreated)),
                Err(error) => WorkspaceInput::ShowAlert {
                    title: gettext("Could Not Create Schema"),
                    body: error_text::operation_error_message(&error),
                },
            },
        );
    }

    pub(super) fn on_create_database(&mut self, draft: DatabaseDraft) {
        let (target, created) = (database_target(&draft.name), draft.name.clone());
        self.start_catalog_change(
            WriteKind::DatabaseChanges,
            target,
            move |dialect, _| ddl::plan_create_database(dialect, &draft),
            move |result| match result {
                Ok(()) => WorkspaceInput::Catalog(CatalogInput::Landed(CatalogLanded::DatabaseCreated(created))),
                Err(error) => WorkspaceInput::ShowAlert {
                    title: gettext("Could Not Create Database"),
                    body: error_text::operation_error_message(&error),
                },
            },
        );
    }
}

/// Create is on only for a plan that builds. Its problem shows once
/// there is a name, so a form does not open on an error.
fn show_plan(form: &FormDialog, name: &str, planned: &Result<DdlPlan, BuildDdlError>) {
    let problem = match planned {
        Err(error) if !name.is_empty() => Some(error_text::build_error_text(error)),
        _ => None,
    };
    form.show_state(planned.is_ok(), problem);
}

/// Under Confirm Writes the statements are asked about first.
fn confirm_then(
    parent: Option<gtk::Widget>,
    asks_first: Option<String>,
    heading: String,
    sql: String,
    create: impl FnOnce() + 'static,
) {
    let Some(connection) = asks_first else {
        create();
        return;
    };
    let Some(parent) = parent else {
        tracing::debug!("no window to ask in before a create");
        return;
    };
    glib::spawn_future_local(async move {
        let confirmation = WriteConfirmation::creation(&connection, heading, sql);
        if write_confirmation::confirm(&parent, &confirmation).await {
            create();
        }
    });
}

struct SchemaForm {
    form: FormDialog,
    name: adw::EntryRow,
    owner: Option<Picker>,
    dialect: Arc<dyn SqlDialect>,
    capabilities: CatalogCapabilities,
}

impl SchemaForm {
    fn draft(&self) -> SchemaDraft {
        SchemaDraft {
            name: self.name.text().trim().to_owned(),
            owner: self.owner.as_ref().and_then(Picker::picked),
        }
    }

    fn check(&self) -> Option<DdlPlan> {
        let draft = self.draft();
        let planned = ddl::named(&self.capabilities, CatalogOption::Name, &draft.name)
            .and_then(|_| ddl::plan_create_schema(&*self.dialect, &draft));
        show_plan(&self.form, &draft.name, &planned);
        planned.ok()
    }

    fn submit(&self, input: &WorkspaceSender, parent: Option<&glib::WeakRef<gtk::Widget>>, asks: Option<String>) {
        let Some(plan) = self.check() else {
            return;
        };
        let draft = self.draft();
        self.form.close();
        let heading = gettext_f("Create Schema “{name}”?", &[("name", &draft.name)]);
        let input = input.clone();
        confirm_then(
            parent.and_then(glib::WeakRef::upgrade),
            asks,
            heading,
            plan.preview(),
            move || input.deliver(WorkspaceInput::Catalog(CatalogInput::CreateSchema(draft))),
        );
    }
}

struct DatabaseForm {
    form: FormDialog,
    name: adw::EntryRow,
    owner: Option<Picker>,
    template: Option<Picker>,
    encoding: Option<Picker>,
    locale: Option<Picker>,
    character_set: Option<Picker>,
    collation: Option<Picker>,
    cluster: Option<Picker>,
    replication: Option<Replication>,
    tablets: Option<adw::SwitchRow>,
    first_collection: Option<adw::EntryRow>,
    /// Each character set's collations, which the collation picker
    /// follows.
    character_sets: Vec<CharacterSet>,
    default_character_set: Option<String>,
    /// The server's own collation, which holds while both pickers are left
    /// to the server.
    default_collation: Option<String>,
    dialect: Arc<dyn SqlDialect>,
    capabilities: CatalogCapabilities,
}

/// The rows `capabilities` names and nothing else, with the server's
/// choices in them.
fn database_form(
    form: FormDialog,
    choices: DatabaseChoices,
    dialect: Arc<dyn SqlDialect>,
    capabilities: CatalogCapabilities,
) -> DatabaseForm {
    let fields = capabilities.database_fields;
    let DatabaseChoices {
        owners,
        templates,
        encodings,
        locales,
        character_sets,
        collations,
        clusters,
        data_centers,
        defaults,
    } = choices;
    let group = adw::PreferencesGroup::new();
    let name = FormDialog::entry_row(&gettext("Name"));
    group.add(&name);
    let picker = |title: String, default: Option<&str>, values: Vec<String>| {
        Picker::new(&group, &title, default_entry(default), values)
    };
    let owner = fields
        .owner
        .then(|| picker(gettext("Owner"), defaults.owner.as_deref(), owners));
    let template = fields.template.then(|| picker(gettext("Template"), None, templates));
    let encoding = fields
        .encoding
        .then(|| picker(gettext("Encoding"), defaults.encoding.as_deref(), encodings));
    let locale = fields
        .locale
        .then(|| picker(gettext("Locale"), defaults.locale.as_deref(), locales));
    let set_names: Vec<String> = character_sets.iter().map(|set| set.name.clone()).collect();
    let character_set = fields
        .character_set
        .then(|| picker(gettext("Character set"), defaults.character_set.as_deref(), set_names));
    // Where a character set is picked, its own collations fill the list.
    let collation = fields.collation.then(|| match fields.character_set {
        true => picker(gettext("Collation"), defaults.collation.as_deref(), Vec::new()),
        false => picker(gettext("Collation"), defaults.collation.as_deref(), collations),
    });
    let cluster = (capabilities.on_cluster && !clusters.is_empty())
        .then(|| Picker::new(&group, &gettext("Cluster"), gettext("This server only"), clusters));
    let replication = fields.replication.then(|| Replication::new(&group, data_centers));
    let tablets = fields.tablets.then(|| {
        let row = adw::SwitchRow::builder()
            .title(gettext("Tablets"))
            .subtitle(gettext("Split each table's data into tablets the cluster balances"))
            .active(true)
            .build();
        group.add(&row);
        row
    });
    form.page.add(&group);
    let first_collection = fields.first_collection.then(|| {
        let collection = adw::PreferencesGroup::builder()
            .description(gettext("MongoDB stores a database only once it holds a collection."))
            .build();
        let row = FormDialog::entry_row(&gettext("First collection"));
        collection.add(&row);
        form.page.add(&collection);
        row
    });
    DatabaseForm {
        form,
        name,
        owner,
        template,
        encoding,
        locale,
        character_set,
        collation,
        cluster,
        replication,
        tablets,
        first_collection,
        character_sets,
        default_character_set: defaults.character_set,
        default_collation: defaults.collation,
        dialect,
        capabilities,
    }
}

/// Every row checks the form again as it changes; a character set picked
/// also changes the collations offered.
fn connect_database_form(state: &Rc<DatabaseForm>) {
    let weak = Rc::downgrade(state);
    let check: Rc<dyn Fn()> = Rc::new(move || {
        if let Some(state) = weak.upgrade() {
            if let Some(replication) = &state.replication {
                replication.show_strategy();
            }
            state.check();
        }
    });
    for entry in std::iter::once(&state.name).chain(state.first_collection.as_ref()) {
        let check = check.clone();
        entry.connect_changed(move |_| check());
    }
    let pickers = [
        &state.owner,
        &state.template,
        &state.encoding,
        &state.locale,
        &state.collation,
        &state.cluster,
    ];
    for picker in pickers.into_iter().flatten() {
        let check = check.clone();
        picker.row.connect_selected_notify(move |_| check());
    }
    if let Some(character_set) = &state.character_set {
        let weak = Rc::downgrade(state);
        character_set.row.connect_selected_notify(move |_| {
            if let Some(state) = weak.upgrade() {
                state.follow_character_set();
                state.check();
            }
        });
    }
    if let Some(replication) = &state.replication {
        replication.connect(&check);
    }
    if let Some(tablets) = &state.tablets {
        let check = check.clone();
        tablets.connect_active_notify(move |_| check());
    }
}

impl DatabaseForm {
    fn draft(&self) -> DatabaseDraft {
        let picked = |picker: &Option<Picker>| picker.as_ref().and_then(Picker::picked);
        let mut draft = DatabaseDraft::named(self.name.text().trim());
        draft.owner = picked(&self.owner);
        draft.template = picked(&self.template);
        draft.encoding = picked(&self.encoding);
        draft.locale = picked(&self.locale);
        draft.character_set = picked(&self.character_set);
        draft.collation = picked(&self.collation);
        draft.cluster = picked(&self.cluster);
        if let Some(replication) = &self.replication {
            draft.replication = Some(replication.chosen());
            draft.durable_writes = replication.durable_writes.is_active();
        }
        draft.tablets = self.tablets.as_ref().map(adw::SwitchRow::is_active);
        draft.first_collection = self.first_collection.as_ref().map(|row| row.text().trim().to_owned());
        draft
    }

    fn check(&self) -> Option<DdlPlan> {
        let draft = self.draft();
        let planned = ddl::named(&self.capabilities, CatalogOption::Name, &draft.name)
            .and_then(|_| ddl::plan_create_database(&*self.dialect, &draft));
        show_plan(&self.form, &draft.name, &planned);
        planned.ok()
    }

    /// The collations of the character set picked, or of the server's own
    /// while it is left to the server. Left to the server, neither option
    /// is sent and the server's own collation holds, which need not be its
    /// character set's default.
    fn follow_character_set(&self) {
        let (Some(character_set), Some(collation)) = (&self.character_set, &self.collation) else {
            return;
        };
        let picked = character_set.picked();
        let name = picked.clone().or_else(|| self.default_character_set.clone());
        let set = self.character_sets.iter().find(|set| Some(&set.name) == name.as_ref());
        let default = match picked {
            Some(_) => set.map(|set| set.default_collation.clone()),
            None => self.default_collation.clone(),
        };
        let collations = set.map(|set| set.collations.clone()).unwrap_or_default();
        collation.replace(default_entry(default.as_deref()), collations);
    }

    fn submit(&self, input: &WorkspaceSender, parent: Option<&glib::WeakRef<gtk::Widget>>, asks: Option<String>) {
        let Some(plan) = self.check() else {
            return;
        };
        let draft = self.draft();
        self.form.close();
        let args = [("name", draft.name.as_str())];
        let heading = match self.capabilities.database_noun {
            DatabaseNoun::Keyspace => gettext_f("Create Keyspace “{name}”?", &args),
            DatabaseNoun::Database => gettext_f("Create Database “{name}”?", &args),
        };
        let input = input.clone();
        confirm_then(
            parent.and_then(glib::WeakRef::upgrade),
            asks,
            heading,
            plan.preview(),
            move || input.deliver(WorkspaceInput::Catalog(CatalogInput::CreateDatabase(Box::new(draft)))),
        );
    }
}

/// A combo row whose first entry leaves the option out of the
/// statement, so the server's own choice holds.
struct Picker {
    row: adw::ComboRow,
    values: RefCell<Vec<String>>,
}

impl Picker {
    fn new(group: &adw::PreferencesGroup, title: &str, first: String, values: Vec<String>) -> Self {
        let row = adw::ComboRow::builder().title(title).build();
        row.set_search_match_mode(gtk::StringFilterMatchMode::Substring);
        row.set_expression(Some(&gtk::PropertyExpression::new(
            gtk::StringObject::static_type(),
            None::<&gtk::Expression>,
            "string",
        )));
        group.add(&row);
        let picker = Self {
            row,
            values: RefCell::default(),
        };
        picker.replace(first, values);
        picker
    }

    fn replace(&self, first: String, values: Vec<String>) {
        let entries: Vec<&str> = std::iter::once(first.as_str())
            .chain(values.iter().map(String::as_str))
            .collect();
        // Taken in first: setting the model announces the new selection,
        // and a handler reads the values.
        let model = gtk::StringList::new(&entries);
        self.row.set_enable_search(values.len() > SEARCHABLE);
        self.values.replace(values);
        self.row.set_model(Some(&model));
        self.row.set_selected(0);
    }

    /// `None` while the first entry is picked.
    fn picked(&self) -> Option<String> {
        let at = usize::try_from(self.row.selected()).ok()?.checked_sub(1)?;
        self.values.borrow().get(at).cloned()
    }
}

/// The first entry of a picker, naming the server's own choice where it
/// said which.
fn default_entry(default: Option<&str>) -> String {
    match default {
        Some(value) => gettext_f("Default ({value})", &[("value", value)]),
        None => gettext("Default"),
    }
}

/// A keyspace's replicas: one factor for the cluster, or one per data
/// centre.
struct Replication {
    strategy: adw::ComboRow,
    factor: adw::SpinRow,
    centres: Vec<(String, adw::SpinRow)>,
    durable_writes: adw::SwitchRow,
}

impl Replication {
    fn new(group: &adw::PreferencesGroup, data_centers: Vec<String>) -> Self {
        let names = [gettext("Network topology"), gettext("Simple")];
        let strategies: Vec<&str> = names.iter().map(String::as_str).collect();
        let strategy = adw::ComboRow::builder()
            .title(gettext("Replication"))
            .model(&gtk::StringList::new(&strategies))
            .build();
        let factor = replicas(&gettext("Replication factor"));
        let centres: Vec<(String, adw::SpinRow)> = data_centers
            .into_iter()
            .map(|centre| {
                let row = replicas(&gettext_f("Replicas in {dc}", &[("dc", &centre)]));
                (centre, row)
            })
            .collect();
        // With no data centre read there is nothing to name a replica
        // count after.
        strategy.set_selected(if centres.is_empty() { SIMPLE } else { NETWORK_TOPOLOGY });
        let durable_writes = adw::SwitchRow::builder()
            .title(gettext("Durable Writes"))
            .subtitle(gettext("Write each change to the commit log before it is acknowledged"))
            .active(true)
            .build();
        group.add(&strategy);
        group.add(&factor);
        for (_, row) in &centres {
            group.add(row);
        }
        group.add(&durable_writes);
        let replication = Self {
            strategy,
            factor,
            centres,
            durable_writes,
        };
        replication.show_strategy();
        replication
    }

    fn simple(&self) -> bool {
        self.strategy.selected() == SIMPLE
    }

    fn show_strategy(&self) {
        let simple = self.simple();
        self.factor.set_visible(simple);
        for (_, row) in &self.centres {
            row.set_visible(!simple);
        }
    }

    fn chosen(&self) -> KeyspaceReplication {
        match self.simple() {
            true => KeyspaceReplication::Simple {
                factor: replica_count(&self.factor),
            },
            false => KeyspaceReplication::NetworkTopology {
                factors: self
                    .centres
                    .iter()
                    .map(|(centre, row)| (centre.clone(), replica_count(row)))
                    .collect(),
            },
        }
    }

    fn connect(&self, check: &Rc<dyn Fn()>) {
        let changed = check.clone();
        self.strategy.connect_selected_notify(move |_| changed());
        for row in std::iter::once(&self.factor).chain(self.centres.iter().map(|(_, row)| row)) {
            let changed = check.clone();
            row.connect_value_notify(move |_| changed());
        }
        let changed = check.clone();
        self.durable_writes.connect_active_notify(move |_| changed());
    }
}

/// One replica is all a single-node cluster can hold; a real cluster
/// raises it.
fn replicas(title: &str) -> adw::SpinRow {
    let row = adw::SpinRow::with_range(1.0, 99.0, 1.0);
    // A data centre's name is never markup.
    row.set_use_markup(false);
    row.set_title(title);
    row.set_value(1.0);
    row
}

/// The row's range keeps the count from 1 to 99.
fn replica_count(row: &adw::SpinRow) -> u32 {
    row.value() as u32
}
