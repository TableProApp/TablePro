//! Emptying a table and dropping a schema or database from the sidebar,
//! what follows once one lands, and the runner every catalog change
//! shares with Drop Table: one recorded write the window's close waits
//! for.

use std::collections::VecDeque;
use std::rc::Rc;
use std::sync::{Arc, Weak};

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use uuid::Uuid;

use tablepro_core::ddl::{
    self, BuildDdlError, CatalogCapabilities, DatabaseChoices, DatabaseDraft, DatabaseNoun, DdlOperation, DdlPlan,
    DropDatabaseOptions, DropSchemaOptions, InboundForeignKey, SchemaDraft, TruncateTableOptions,
};
use tablepro_core::dialect::{DatabaseLayout, SqlDialect};
use tablepro_core::meta::{ObjectScope, SchemaInfo, TableRef};
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::{SafeModeLevel, WriteKind};
use tablepro_session::{OperationError, OperationKind, Session};

use super::catalog_dialogs::CatalogForm;
use super::structure::{display_name, key_list, read_definition, referencing_keys, settled};
use super::{WorkspaceInput, WorkspaceModel, WorkspaceTab};
use crate::i18n::{gettext, gettext_f, ngettext_f};
use crate::runtime::DeliverInput;
use crate::ui::SessionWindowInput;
use crate::ui::error_text;
use crate::ui::write_confirmation::asks_before_writes;
use crate::workspace::{CatalogChange, PendingState, database_target, run_catalog_change};

const CANCEL: &str = "cancel";
pub(super) const TRUNCATE: &str = "truncate";
pub(super) const DROP: &str = "drop";

/// The steps of a catalog change between the sidebar's or the window's
/// ask and the write.
#[derive(Debug)]
pub(crate) enum CatalogInput {
    TruncateTableChecked(Box<TruncateCheck>),
    TruncateTableConfirmed {
        table: TableRef,
        options: TruncateTableOptions,
        /// The other tables the truncate empties through Cascade.
        cascaded: Vec<TableRef>,
    },
    /// Every tab on these tables reads them again.
    ReloadTables(Vec<TableRef>),
    /// How many objects the schema still holds, read before the drop asks.
    DropSchemaChecked {
        schema: String,
        held: usize,
    },
    DropSchemaConfirmed {
        schema: String,
        options: DropSchemaOptions,
    },
    /// The clusters a drop can run on, read before it asks.
    DropDatabaseChecked {
        database: String,
        clusters: Vec<String>,
    },
    DropDatabaseConfirmed {
        database: String,
        options: DropDatabaseOptions,
    },
    /// What the server offers for the form's pickers, `None` when it
    /// lists nothing.
    ChoicesRead {
        form: CatalogForm,
        choices: Option<Box<DatabaseChoices>>,
    },
    CreateSchema(SchemaDraft),
    CreateDatabase(Box<DatabaseDraft>),
    /// The DROP DATABASE ran, or failed, which lets the window open the
    /// database again.
    DatabaseDropSettled {
        target: DatabaseDrop,
        result: Result<(), OperationError>,
    },
    Landed(CatalogLanded),
}

/// A database the session under `key` is dropping, and which session
/// that is: by the time the window has let go of the database, the same
/// key can be open again as another session, perhaps to another server.
#[derive(Debug, Clone)]
pub(crate) struct DatabaseDrop {
    pub(crate) key: tablepro_session::SessionKey,
    pub(crate) origin: Weak<Session>,
    pub(crate) database: String,
}

impl DatabaseDrop {
    /// Whether `session` is the one the user confirmed the drop on.
    pub(crate) fn confirmed_by(&self, session: &Arc<Session>) -> bool {
        self.origin
            .upgrade()
            .is_some_and(|origin| Arc::ptr_eq(&origin, session))
    }
}

/// What was read before the prompt to empty a table asks.
#[derive(Debug)]
pub(crate) struct TruncateCheck {
    table: TableRef,
    /// The keys of other tables that point at it.
    referencing: Vec<InboundForeignKey>,
    /// Every other table a cascading truncate empties with it.
    cascades: Vec<TableRef>,
    clusters: Vec<String>,
}

/// A catalog change the server applied.
#[derive(Debug)]
pub(crate) enum CatalogLanded {
    Truncated { table: TableRef, cascaded: Vec<TableRef> },
    SchemaCreated,
    SchemaDropped(String),
    DatabaseCreated(String),
    DatabaseDropped(String),
}

impl WorkspaceModel {
    pub(super) fn on_catalog_input(&mut self, input: CatalogInput) {
        match input {
            CatalogInput::TruncateTableChecked(check) => self.on_truncate_table_checked(*check),
            CatalogInput::TruncateTableConfirmed {
                table,
                options,
                cascaded,
            } => self.on_truncate_table_confirmed(table, options, cascaded),
            CatalogInput::ReloadTables(tables) => self.reload_tables(&tables),
            CatalogInput::DropSchemaChecked { schema, held } => self.on_drop_schema_checked(schema, held),
            CatalogInput::DropSchemaConfirmed { schema, options } => self.on_drop_schema_confirmed(schema, options),
            CatalogInput::DropDatabaseChecked { database, clusters } => {
                self.present_drop_database_prompt(database, clusters);
            }
            CatalogInput::DropDatabaseConfirmed { database, options } => {
                self.on_drop_database_confirmed(database, options);
            }
            CatalogInput::ChoicesRead { form, choices } => {
                self.present_catalog_form(form, choices.map(|choices| *choices).unwrap_or_default());
            }
            CatalogInput::CreateSchema(draft) => self.on_create_schema(draft),
            CatalogInput::CreateDatabase(draft) => self.on_create_database(*draft),
            CatalogInput::DatabaseDropSettled { target, result } => self.on_database_drop_settled(target, result),
            CatalogInput::Landed(landed) => self.on_catalog_landed(landed),
        }
    }

    /// The session and what its engine does to whole tables, schemas and
    /// databases. A connection that may not write says so, and nothing
    /// runs.
    pub(super) fn writable_catalog(&self) -> Option<(Arc<Session>, Arc<dyn SqlDialect>, CatalogCapabilities)> {
        let Some(session) = self.context.active.get() else {
            self.show_toast(&gettext("Connect to a database first."));
            return None;
        };
        if session.read_only() {
            self.show_toast(&gettext("This connection is read-only."));
            return None;
        }
        let Some(dialect) = session.current_dialect() else {
            self.show_toast(&gettext("The connection is not back yet. Try again once it is."));
            return None;
        };
        let capabilities = ddl::catalog_capabilities(&*dialect);
        Some((session, dialect, capabilities))
    }

    /// Say the engine cannot do `operation`, for a menu offered before a
    /// reconnect to another server version.
    pub(super) fn refuse_catalog_change(&self, title: &str, operation: DdlOperation) {
        self.show_error_alert(
            title,
            &error_text::build_error_text(&BuildDdlError::Unsupported(operation)),
        );
    }

    /// Run a catalog change as a save of its own: a window close waits
    /// for it or stops it, a quit keeps the process until it answers, and
    /// the history records it. `answer` goes through the workspace's
    /// input, so one that lands after a disconnect is dropped with it.
    /// False when it did not start, and `answer` is never called.
    pub(super) fn start_catalog_change<P, A>(&self, kind: WriteKind, target: TableRef, plan: P, answer: A) -> bool
    where
        P: Fn(&dyn SqlDialect, &TableRef) -> Result<DdlPlan, BuildDdlError> + Send + Sync + 'static,
        A: FnOnce(Result<(), OperationError>) -> WorkspaceInput + 'static,
    {
        let Some(session) = self.context.active.get() else {
            self.show_toast(&gettext("Connect to a database first."));
            return false;
        };
        if session.read_only() {
            self.show_toast(&gettext("This connection is read-only."));
            return false;
        }
        let handle = self.workspace_handle.clone();
        let Some(ticket) = handle.ledger().begin(&*self.context.hold, Uuid::new_v4(), kind) else {
            return false;
        };
        let change = CatalogChange {
            kind,
            target,
            history: handle.history_entry(&session),
        };
        let cancel = ticket.cancel.clone();
        let work = async move { run_catalog_change(session, change, &cancel, plan).await };
        let input = self.input.clone();
        crate::runtime::spawn_and_deliver(&self.context.tasks, work, move |result| {
            input.deliver(answer(settled(result)));
            handle.ledger().settle(ticket.id);
        });
        true
    }

    /// Sidebar "Truncate Table…" or "Delete All Documents…". Where another
    /// table's foreign key decides whether the table can be emptied, the
    /// keys are read first, so a refusal comes before the question. Where
    /// Cascade can empty them too, every table it would reach is read.
    pub(super) fn on_truncate_table_prompt(&mut self, table: TableRef) {
        let Some((session, _, capabilities)) = self.writable_catalog() else {
            return;
        };
        if !capabilities.truncate_table {
            self.refuse_catalog_change(&gettext("Cannot Truncate Table"), DdlOperation::TruncateTable);
            return;
        }
        let (walks_cascade, refuses_referenced) = (
            capabilities.truncate_cascade,
            capabilities.truncate_refused_when_referenced,
        );
        let reads_clusters = capabilities.on_cluster;
        let work = async move {
            let (referencing, cascades) = match (walks_cascade, refuses_referenced) {
                (true, _) => cascade_from(&session, &table).await,
                (false, true) => (keys_pointing_at(session.clone(), table.clone()).await, Vec::new()),
                (false, false) => (Vec::new(), Vec::new()),
            };
            let clusters = match reads_clusters {
                true => read_choices(session)
                    .await
                    .map(|choices| choices.clusters)
                    .unwrap_or_default(),
                false => Vec::new(),
            };
            TruncateCheck {
                table,
                referencing,
                cascades,
                clusters,
            }
        };
        let input = self.input.clone();
        crate::runtime::spawn_and_deliver(&self.context.tasks, work, move |result| match result {
            Ok(check) => input.deliver(WorkspaceInput::Catalog(CatalogInput::TruncateTableChecked(Box::new(
                check,
            )))),
            Err(failure) => tracing::warn!(%failure, "the table could not be read before emptying it"),
        });
    }

    fn on_truncate_table_checked(&mut self, check: TruncateCheck) {
        let Some((session, dialect, capabilities)) = self.writable_catalog() else {
            return;
        };
        if !check.referencing.is_empty() && capabilities.truncate_refused_when_referenced {
            self.show_error_alert(
                &gettext("Cannot Truncate Table"),
                &gettext_f(
                    "Foreign keys on other tables point at {table}: {keys}. Drop those foreign keys first, or delete the rows in a query.",
                    &[
                        ("table", &display_name(&check.table)),
                        ("keys", &key_list(&check.table, &check.referencing)),
                    ],
                ),
            );
            return;
        }
        let unsaved = Unsaved {
            here: !self.unsaved_tabs_on(&check.table).is_empty(),
            cascaded: check
                .cascades
                .iter()
                .any(|table| !self.unsaved_tabs_on(table).is_empty()),
        };
        let prompt = truncate_prompt(check, unsaved, &session, dialect, &capabilities);
        let input = self.input.clone();
        let (table, cascades, controls) = (prompt.table, prompt.cascades, prompt.controls);
        prompt.prompt.on_response(TRUNCATE, move || {
            let options = controls.options();
            let cascaded = match options.cascade {
                true => cascades.clone(),
                false => Vec::new(),
            };
            input.deliver(WorkspaceInput::Catalog(CatalogInput::TruncateTableConfirmed {
                table: table.clone(),
                options,
                cascaded,
            }));
        });
        prompt.prompt.present(self.dialog_parent().as_ref());
    }

    fn on_truncate_table_confirmed(&mut self, table: TableRef, options: TruncateTableOptions, cascaded: Vec<TableRef>) {
        let emptied = table.clone();
        self.start_catalog_change(
            WriteKind::SchemaChanges,
            table,
            move |dialect, table| ddl::plan_truncate_table(dialect, table, &options),
            move |result| match result {
                Ok(()) => WorkspaceInput::Catalog(CatalogInput::Landed(CatalogLanded::Truncated {
                    table: emptied,
                    cascaded,
                })),
                Err(error) => failed(gettext("Truncate Failed"), &error),
            },
        );
    }

    /// Every tab on the tables reads them again.
    fn reload_tables(&self, tables: &[TableRef]) {
        let Some(session) = self.context.active.get() else {
            return;
        };
        for table in tables {
            self.reload_table_tabs(&session, table);
        }
    }

    /// The table tabs on `table` holding row edits not yet saved, which
    /// would point at rows that are gone once it is emptied.
    pub(super) fn unsaved_tabs_on(&self, table: &TableRef) -> Vec<Uuid> {
        let tabs: Vec<Uuid> = self
            .workspace_tabs
            .borrow()
            .values()
            .filter_map(|tab| match tab {
                WorkspaceTab::Table(slot) if slot.schema == table.schema && slot.table == table.name => Some(slot.id),
                _ => None,
            })
            .collect();
        tabs.into_iter()
            .filter(|tab| {
                self.change_trackers.get(*tab).is_some_and(|tracker| {
                    matches!(
                        tracker.pending_state(),
                        PendingState::Unsaved | PendingState::OutcomeUnknown(_)
                    )
                })
            })
            .collect()
    }

    /// The tables of the table tabs that hold no unsaved edits, other
    /// than those in `known`.
    fn clean_table_tabs_besides(&self, known: &[TableRef]) -> Vec<TableRef> {
        let tabs: Vec<(Uuid, TableRef)> = self
            .workspace_tabs
            .borrow()
            .values()
            .filter_map(|tab| match tab {
                WorkspaceTab::Table(slot) => Some((slot.id, TableRef::new(slot.schema.clone(), slot.table.clone()))),
                _ => None,
            })
            .collect();
        let mut clean: Vec<TableRef> = Vec::new();
        for (tab, table) in tabs {
            let unsaved = self.change_trackers.get(tab).is_some_and(|tracker| {
                matches!(
                    tracker.pending_state(),
                    PendingState::Unsaved | PendingState::OutcomeUnknown(_)
                )
            });
            if !unsaved && !known.contains(&table) && !clean.contains(&table) {
                clean.push(table);
            }
        }
        clean
    }

    /// Sidebar "Drop Schema…". What the schema still holds is counted
    /// first: an engine that cannot drop it with everything in it is
    /// refused before the question.
    pub(super) fn on_drop_schema_prompt(&mut self, schema: String) {
        let Some((session, dialect, capabilities)) = self.writable_catalog() else {
            return;
        };
        if !capabilities.drop_schema {
            self.refuse_catalog_change(&gettext("Cannot Drop Schema"), DdlOperation::DropSchema);
            return;
        }
        if !droppable_schema(&self.catalog_schemas, session.database(), &*dialect, &schema) {
            tracing::debug!("a schema the sidebar no longer offers to drop was asked to drop");
            return;
        }
        let work = async move {
            let held = match session.objects(ObjectScope::AllSchemas).await {
                Ok(objects) => objects
                    .iter()
                    .filter(|object| object.schema.as_deref() == Some(schema.as_str()))
                    .count(),
                Err(error) => {
                    tracing::debug!(%error, "the schema's objects could not be counted before a drop");
                    0
                }
            };
            (schema, held)
        };
        let input = self.input.clone();
        crate::runtime::spawn_and_deliver(&self.context.tasks, work, move |result| match result {
            Ok((schema, held)) => {
                input.deliver(WorkspaceInput::Catalog(CatalogInput::DropSchemaChecked {
                    schema,
                    held,
                }));
            }
            Err(failure) => tracing::warn!(%failure, "the schema could not be read before a drop"),
        });
    }

    fn on_drop_schema_checked(&mut self, schema: String, held: usize) {
        let Some((session, dialect, capabilities)) = self.writable_catalog() else {
            return;
        };
        let count = u32::try_from(held).unwrap_or(u32::MAX);
        let args = [("schema", schema.as_str()), ("n", &held.to_string())];
        if held > 0 && !capabilities.drop_schema_cascade {
            self.show_error_alert(
                &gettext("Cannot Drop Schema"),
                &ngettext_f(
                    "“{schema}” still holds {n} object. Drop it first.",
                    "“{schema}” still holds {n} objects. Drop them first.",
                    count,
                    &args,
                ),
            );
            return;
        }
        let mut body = gettext("Everything in it will be permanently deleted.");
        if held > 0 {
            body.push(' ');
            body.push_str(&ngettext_f(
                "It holds {n} object. Turn on Cascade to drop it too, with anything elsewhere that depends on it.",
                "It holds {n} objects. Turn on Cascade to drop them too, with anything elsewhere that depends on them.",
                count,
                &args,
            ));
        }
        let mut prompt = CatalogPrompt::new(
            &gettext_f("Drop Schema “{schema}”?", &args),
            &body,
            (DROP, &gettext("_Drop")),
            asks_first(&session).as_deref(),
        );
        let cascade = capabilities.drop_schema_cascade.then(|| {
            prompt.switch(
                &gettext("Cascade"),
                &gettext("Also drop what is in it, and anything elsewhere that depends on it"),
            )
        });
        let (planned, read) = (schema.clone(), cascade.clone());
        prompt.follow(DROP, move || {
            let options = DropSchemaOptions {
                cascade: is_on(read.as_ref()),
            };
            let allowed = held == 0 || options.cascade;
            (ddl::plan_drop_schema(&*dialect, &planned, options), allowed)
        });
        let input = self.input.clone();
        prompt.on_response(DROP, move || {
            input.deliver(WorkspaceInput::Catalog(CatalogInput::DropSchemaConfirmed {
                schema: schema.clone(),
                options: DropSchemaOptions {
                    cascade: is_on(cascade.as_ref()),
                },
            }));
        });
        prompt.present(self.dialog_parent().as_ref());
    }

    fn on_drop_schema_confirmed(&mut self, schema: String, options: DropSchemaOptions) {
        let (target, dropped) = (TableRef::new(Some(schema.clone()), ""), schema.clone());
        self.start_catalog_change(
            WriteKind::SchemaChanges,
            target,
            move |dialect, _| ddl::plan_drop_schema(dialect, &schema, options),
            move |result| match result {
                Ok(()) => WorkspaceInput::Catalog(CatalogInput::Landed(CatalogLanded::SchemaDropped(dropped))),
                Err(error) => failed(gettext("Drop Failed"), &error),
            },
        );
    }

    /// Sidebar or window "Drop Database…". Whether it may still be
    /// dropped is checked again, since the menu that asked can be older
    /// than the list.
    pub(super) fn on_drop_database_prompt(&mut self, database: String) {
        let Some((session, dialect, capabilities)) = self.writable_catalog() else {
            return;
        };
        if !capabilities.drop_database {
            self.refuse_catalog_change(&gettext("Cannot Drop Database"), DdlOperation::DropDatabase);
            return;
        }
        let free = match dialect.database_layout() {
            DatabaseLayout::AsSchemas => {
                droppable_schema(&self.catalog_schemas, session.database(), &*dialect, &database)
            }
            DatabaseLayout::WithSchemas | DatabaseLayout::Single => {
                session.database() != Some(database.as_str()) && !ddl::protects_database(&*dialect, &database)
            }
        };
        if !free {
            tracing::debug!("a database the sidebar no longer offers to drop was asked to drop");
            return;
        }
        if !capabilities.on_cluster {
            self.present_drop_database_prompt(database, Vec::new());
            return;
        }
        let input = self.input.clone();
        crate::runtime::spawn_and_deliver(&self.context.tasks, read_choices(session), move |read| {
            let clusters = read.ok().flatten().map(|choices| choices.clusters).unwrap_or_default();
            input.deliver(WorkspaceInput::Catalog(CatalogInput::DropDatabaseChecked {
                database,
                clusters,
            }));
        });
    }

    fn present_drop_database_prompt(&self, database: String, clusters: Vec<String>) {
        let Some((session, dialect, capabilities)) = self.writable_catalog() else {
            return;
        };
        let args = [("name", database.as_str())];
        let heading = match capabilities.database_noun {
            DatabaseNoun::Keyspace => gettext_f("Drop Keyspace “{name}”?", &args),
            DatabaseNoun::Database => gettext_f("Drop Database “{name}”?", &args),
        };
        let mut body = gettext("All tables and data in it will be permanently deleted.");
        if dialect.database_layout() == DatabaseLayout::WithSchemas {
            body.push(' ');
            body.push_str(&gettext("Where it is open beside this connection, it closes first."));
        }
        let mut prompt = CatalogPrompt::new(
            &heading,
            &body,
            (DROP, &gettext("_Drop")),
            asks_first(&session).as_deref(),
        );
        let controls = DropDatabaseControls {
            force: capabilities.drop_database_force.then(|| {
                prompt.switch(
                    &gettext("Close Other Connections"),
                    &gettext("End every other session on it, so the server lets it go"),
                )
            }),
            cluster: cluster_choice(&mut prompt, &capabilities, clusters),
        };
        let (planned, read) = (database.clone(), controls.clone());
        prompt.follow(DROP, move || {
            (ddl::plan_drop_database(&*dialect, &planned, &read.options()), true)
        });
        let input = self.input.clone();
        prompt.on_response(DROP, move || {
            input.deliver(WorkspaceInput::Catalog(CatalogInput::DropDatabaseConfirmed {
                database: database.clone(),
                options: controls.options(),
            }));
        });
        prompt.present(self.dialog_parent().as_ref());
    }

    /// Where another database is a session of its own beside the
    /// connection, the window closes the one it holds on this database
    /// first and hands the drop back (0033).
    fn on_drop_database_confirmed(&mut self, database: String, options: DropDatabaseOptions) {
        let Some(session) = self.context.active.get() else {
            return;
        };
        let target = DatabaseDrop {
            key: self.key.clone(),
            origin: Arc::downgrade(&session),
            database,
        };
        match (self.database_layout(), self.shell.upgrade()) {
            (Some(DatabaseLayout::WithSchemas), Some(shell)) => {
                shell.tell_window(SessionWindowInput::ReleaseDatabase { target, options });
            }
            _ => self.on_database_released(target, options),
        }
    }

    /// Nothing of the window holds the database any longer. The drop runs
    /// only on the session it was confirmed on.
    pub(super) fn on_database_released(&mut self, target: DatabaseDrop, options: DropDatabaseOptions) {
        let confirmed_here = self
            .context
            .active
            .get()
            .is_some_and(|session| target.confirmed_by(&session));
        if !confirmed_here {
            tracing::debug!("a drop confirmed on a session this workspace no longer holds does not run");
            self.drop_finished(target);
            return;
        }
        let (database, settled) = (target.database.clone(), target.clone());
        let started = self.start_catalog_change(
            WriteKind::DatabaseChanges,
            database_target(&target.database),
            move |dialect, _| ddl::plan_drop_database(dialect, &database, &options),
            move |result| {
                WorkspaceInput::Catalog(CatalogInput::DatabaseDropSettled {
                    target: settled,
                    result,
                })
            },
        );
        if !started {
            self.drop_finished(target);
        }
    }

    fn on_database_drop_settled(&mut self, target: DatabaseDrop, result: Result<(), OperationError>) {
        let database = target.database.clone();
        self.drop_finished(target);
        match result {
            Ok(()) => self.on_catalog_landed(CatalogLanded::DatabaseDropped(database)),
            Err(error) => self.show_error_alert(&gettext("Drop Failed"), &error_text::operation_error_message(&error)),
        }
    }

    /// The window may open the database again, which it refused while
    /// the drop was on its way.
    fn drop_finished(&self, target: DatabaseDrop) {
        if let Some(shell) = self.shell.upgrade() {
            shell.tell_window(SessionWindowInput::DatabaseDropFinished(target));
        }
    }

    fn on_catalog_landed(&mut self, landed: CatalogLanded) {
        match landed {
            CatalogLanded::Truncated { table, cascaded } => self.on_truncated(table, cascaded),
            CatalogLanded::SchemaCreated => self.catalog_shape_changed(),
            CatalogLanded::SchemaDropped(schema) => {
                self.close_tabs_in(&schema);
                self.catalog_shape_changed();
            }
            CatalogLanded::DatabaseCreated(database) => {
                self.databases_changed_everywhere();
                self.open_beside(database);
            }
            CatalogLanded::DatabaseDropped(database) => {
                // Where the databases are the schemas, the tabs on its
                // tables name it as their schema.
                if self.database_layout() == Some(DatabaseLayout::AsSchemas) {
                    self.close_tabs_in(&database);
                }
                self.databases_changed_everywhere();
            }
        }
    }

    /// The edits the prompt said would go are dropped, and every tab on
    /// a table it emptied, through Cascade too, reads it again. The reads
    /// go through the input, after the drop of the edits.
    fn on_truncated(&mut self, table: TableRef, cascaded: Vec<TableRef>) {
        self.show_toast(&gettext_f("“{table}” is empty", &[("table", &display_name(&table))]));
        let mut emptied: Vec<TableRef> = std::iter::once(table).chain(cascaded).collect();
        let discarded: Vec<Uuid> = emptied.iter().flat_map(|table| self.unsaved_tabs_on(table)).collect();
        if !discarded.is_empty() {
            self.workspace_handle.discard(&discarded, false);
        }
        // A PostgreSQL truncate also empties the table's partitions and
        // inheritance children, which no foreign key names, so every other
        // tab with nothing unsaved reads its rows again. One with unsaved
        // edits keeps them, and its save's row guards refuse rows now gone.
        emptied.extend(self.clean_table_tabs_besides(&emptied));
        self.input
            .deliver(WorkspaceInput::Catalog(CatalogInput::ReloadTables(emptied)));
    }

    /// Close the tabs on a schema, or on a database that is one, that is
    /// gone. Reopen Closed Tab never offers them.
    fn close_tabs_in(&mut self, schema: &str) {
        let targets: Vec<Uuid> = self
            .workspace_tabs
            .borrow()
            .iter()
            .filter(|(_, tab)| match tab {
                WorkspaceTab::Table(slot) => slot.schema.as_deref() == Some(schema),
                WorkspaceTab::Structure(slot) => slot.schema.as_deref() == Some(schema),
                WorkspaceTab::Diagram(slot) => slot.schema.as_deref() == Some(schema),
                WorkspaceTab::Editor(_) | WorkspaceTab::Key(_) => false,
            })
            .map(|(id, _)| *id)
            .collect();
        self.forget_tabs(targets);
    }

    /// Every session of the connection lists the server's databases
    /// again, this one too.
    fn databases_changed_everywhere(&mut self) {
        match self.shell.upgrade() {
            Some(shell) => shell.tell_window(SessionWindowInput::DatabasesChanged(self.key.clone())),
            None => self.on_databases_changed(),
        }
    }

    /// A database was created or dropped somewhere on the connection.
    pub(super) fn on_databases_changed(&mut self) {
        self.relist_editor_databases();
        self.catalog_shape_changed();
    }

    /// Each editor tab asks the server for its databases again, for its
    /// bar's menu.
    pub(super) fn relist_editor_databases(&self) {
        for tab in self.workspace_tabs.borrow().values() {
            if let WorkspaceTab::Editor(slot) = tab {
                slot.editor.list_databases();
            }
        }
    }

    /// A database created where the connection's catalog lists only its
    /// own opens beside it, so it shows.
    fn open_beside(&self, database: String) {
        if self.database_layout() == Some(DatabaseLayout::WithSchemas)
            && let Some(shell) = self.shell.upgrade()
        {
            shell.tell_window(SessionWindowInput::OpenDatabaseIn {
                key: self.key.clone(),
                database,
            });
        }
    }

    fn database_layout(&self) -> Option<DatabaseLayout> {
        let dialect = self.context.active.get()?.current_dialect()?;
        Some(dialect.database_layout())
    }
}

/// Whether the sidebar still lists the schema `name` and may drop it.
/// Where the server's databases are the schemas it is a database: not
/// one the engine keeps, nor the one the session opened. Elsewhere it
/// is a schema of the session's database, which can share that
/// database's name: not one the engine keeps, nor the default.
pub(super) fn droppable_schema(
    schemas: &[SchemaInfo],
    own_database: Option<&str>,
    dialect: &dyn SqlDialect,
    name: &str,
) -> bool {
    let listed = schemas.iter().find(|schema| schema.name == name);
    if !listed.is_some_and(|schema| !schema.is_system && !schema.is_default) {
        return false;
    }
    match dialect.database_layout() {
        DatabaseLayout::AsSchemas => !ddl::protects_database(dialect, name) && own_database != Some(name),
        DatabaseLayout::WithSchemas | DatabaseLayout::Single => !ddl::protects_schema(dialect, name),
    }
}

/// The connection's name when its Safe Mode asks before every write, so
/// the question shows the statements too.
pub(super) fn asks_first(session: &Session) -> Option<String> {
    (session.safe_mode() == SafeModeLevel::ConfirmWrites).then(|| session.metadata().name.clone())
}

fn failed(title: String, error: &OperationError) -> WorkspaceInput {
    WorkspaceInput::ShowAlert {
        title,
        body: error_text::operation_error_message(error),
    }
}

/// What the server offers for a new database's options. `None` when it
/// lists none, so every picker keeps only the server's default.
pub(super) async fn read_choices(session: Arc<Session>) -> Option<DatabaseChoices> {
    let read = session
        .run(OperationKind::Metadata, |lease, options| async move {
            Ok(lease.fetch_database_choices(options).await?)
        })
        .await;
    match read {
        Ok(choices) => Some(choices),
        Err(error) => {
            tracing::debug!(%error, "the server's options for a new database could not be read");
            None
        }
    }
}

/// The keys of other tables that point at `table`, and every table a
/// cascading truncate of it empties beside it: those, the tables pointing
/// at them, and so on, each once. A table's keys on itself go with it.
/// Keys that cannot be read end the walk there, and the server decides.
async fn cascade_from(session: &Session, table: &TableRef) -> (Vec<InboundForeignKey>, Vec<TableRef>) {
    let mut referencing = Vec::new();
    let mut reached: Vec<TableRef> = Vec::new();
    let mut pending = VecDeque::from([table.clone()]);
    while let Some(next) = pending.pop_front() {
        for key in inbound_keys(session, next.clone()).await {
            if key.table == next {
                continue;
            }
            if next == *table {
                referencing.push(key.clone());
            }
            if key.table != *table && !reached.contains(&key.table) {
                reached.push(key.table.clone());
                pending.push_back(key.table);
            }
        }
    }
    (referencing, reached)
}

async fn inbound_keys(session: &Session, table: TableRef) -> Vec<InboundForeignKey> {
    let read = session
        .run(OperationKind::Metadata, move |lease, options| {
            let table = table.clone();
            async move { Ok(lease.fetch_inbound_foreign_keys(&table, options).await?) }
        })
        .await;
    match read {
        Ok(keys) => keys,
        Err(error) => {
            tracing::debug!(%error, "the foreign keys pointing at a table could not be read before emptying it");
            Vec::new()
        }
    }
}

/// The keys of other tables that point at `table`. Keys that cannot be
/// read leave the refusal to the server.
async fn keys_pointing_at(session: Arc<Session>, table: TableRef) -> Vec<InboundForeignKey> {
    match read_definition(session, table).await {
        Ok((definition, _)) => referencing_keys(&definition),
        Err(error) => {
            tracing::debug!(%error, "the table's foreign keys could not be read before emptying it");
            Vec::new()
        }
    }
}

/// Whether open tabs hold row edits a truncate would discard: on the
/// table itself, and on the tables Cascade empties with it.
#[derive(Debug, Clone, Copy)]
struct Unsaved {
    here: bool,
    cascaded: bool,
}

/// The question that empties a table, with the options it takes.
struct TruncatePrompt {
    prompt: CatalogPrompt,
    table: TableRef,
    cascades: Vec<TableRef>,
    controls: TruncateControls,
}

fn truncate_prompt(
    check: TruncateCheck,
    unsaved: Unsaved,
    session: &Session,
    dialect: Arc<dyn SqlDialect>,
    capabilities: &CatalogCapabilities,
) -> TruncatePrompt {
    let TruncateCheck {
        table,
        referencing,
        cascades,
        clusters,
    } = check;
    let documents = dialect.grammar() == SqlGrammar::Mongo;
    // The server refuses a referenced table unless the tables pointing
    // at it are emptied with it.
    let needs_cascade = capabilities.truncate_cascade && !referencing.is_empty();
    let name = display_name(&table);
    let (heading, verb) = match documents {
        true => (
            gettext_f("Delete All Documents in “{collection}”?", &[("collection", &name)]),
            gettext("_Delete All"),
        ),
        false => (
            gettext_f("Truncate “{table}”?", &[("table", &name)]),
            gettext("_Truncate"),
        ),
    };
    let body = truncate_body(&table, &referencing, documents, needs_cascade, unsaved.here);
    let mut prompt = CatalogPrompt::new(&heading, &body, (TRUNCATE, &verb), asks_first(session).as_deref());
    let controls = TruncateControls {
        restart_identity: capabilities.truncate_restart_identity.then(|| {
            prompt.switch(
                &gettext("Restart Identity"),
                &gettext("Sequences owned by its columns start again"),
            )
        }),
        cascade: capabilities
            .truncate_cascade
            .then(|| prompt.switch(&gettext("Cascade"), &cascade_subtitle(&table, &cascades, None))),
        cluster: cluster_choice(&mut prompt, capabilities, clusters),
    };
    let (planned, read) = (table.clone(), controls.clone());
    let emptied_too = cascade_subtitle(&table, &cascades, Some(unsaved.cascaded));
    let left_alone = cascade_subtitle(&table, &cascades, None);
    prompt.follow(TRUNCATE, move || {
        let options = read.options();
        // The tables Cascade reaches are named only while it would empty
        // them.
        if let Some(row) = read.cascade.as_ref().and_then(glib::WeakRef::upgrade) {
            row.set_subtitle(if options.cascade { &emptied_too } else { &left_alone });
        }
        let allowed = !needs_cascade || options.cascade;
        (ddl::plan_truncate_table(&*dialect, &planned, &options), allowed)
    });
    TruncatePrompt {
        prompt,
        table,
        cascades,
        controls,
    }
}

/// The Cascade row's subtitle: what it does, and with `on` the tables it
/// empties, and whether that loses unsaved edits in their tabs.
fn cascade_subtitle(table: &TableRef, cascades: &[TableRef], on: Option<bool>) -> String {
    let (Some(unsaved), false) = (on, cascades.is_empty()) else {
        return gettext("Also empty the tables whose foreign keys point at it");
    };
    let names: Vec<String> = cascades.iter().map(|cascaded| relative_name(table, cascaded)).collect();
    let tables = names.join(", ");
    let args = [("tables", tables.as_str())];
    let count = u32::try_from(names.len()).unwrap_or(u32::MAX);
    match unsaved {
        true => ngettext_f(
            "Also empties {tables}, and discards the unsaved changes in its open tabs",
            "Also empties {tables}, and discards the unsaved changes in their open tabs",
            count,
            &args,
        ),
        false => ngettext_f("Also empties {tables}", "Also empties {tables}", count, &args),
    }
}

/// `other` by name alone where it sits in `table`'s schema.
fn relative_name(table: &TableRef, other: &TableRef) -> String {
    match other.schema == table.schema {
        true => other.name.clone(),
        false => display_name(other),
    }
}

fn truncate_body(
    table: &TableRef,
    referencing: &[InboundForeignKey],
    documents: bool,
    needs_cascade: bool,
    unsaved: bool,
) -> String {
    let mut body = match documents {
        true => gettext("All documents in it will be deleted. The collection, its indexes and its options stay."),
        false => gettext(
            "All rows in it will be deleted. The table and its structure stay. This can't be undone from inside TablePro.",
        ),
    };
    if needs_cascade {
        let tables = referencing_tables(table, referencing);
        body.push(' ');
        body.push_str(&ngettext_f(
            "{tables} points at it. Turn on Cascade to empty it too.",
            "{tables} point at it. Turn on Cascade to empty them too.",
            u32::try_from(tables.len()).unwrap_or(u32::MAX),
            &[("tables", &tables.join(", "))],
        ));
    }
    if unsaved {
        body.push(' ');
        body.push_str(&gettext("Unsaved changes to its rows in open tabs will be discarded."));
    }
    body
}

/// The tables `keys` belong to, each once, qualified only where it sits
/// in another schema than `table`.
pub(super) fn referencing_tables(table: &TableRef, keys: &[InboundForeignKey]) -> Vec<String> {
    let mut tables: Vec<String> = Vec::new();
    for key in keys {
        let name = relative_name(table, &key.table);
        if !tables.contains(&name) {
            tables.push(name);
        }
    }
    tables
}

/// The truncate the prompt's rows describe now.
#[derive(Clone, Default)]
struct TruncateControls {
    restart_identity: Option<glib::WeakRef<adw::SwitchRow>>,
    cascade: Option<glib::WeakRef<adw::SwitchRow>>,
    cluster: Option<ClusterChoice>,
}

impl TruncateControls {
    fn options(&self) -> TruncateTableOptions {
        TruncateTableOptions {
            cascade: is_on(self.cascade.as_ref()),
            restart_identity: is_on(self.restart_identity.as_ref()),
            cluster: self.cluster.as_ref().and_then(ClusterChoice::picked),
        }
    }
}

/// The drop the prompt's rows describe now.
#[derive(Clone, Default)]
struct DropDatabaseControls {
    force: Option<glib::WeakRef<adw::SwitchRow>>,
    cluster: Option<ClusterChoice>,
}

impl DropDatabaseControls {
    fn options(&self) -> DropDatabaseOptions {
        DropDatabaseOptions {
            force: is_on(self.force.as_ref()),
            cluster: self.cluster.as_ref().and_then(ClusterChoice::picked),
        }
    }
}

fn is_on(row: Option<&glib::WeakRef<adw::SwitchRow>>) -> bool {
    row.and_then(glib::WeakRef::upgrade).is_some_and(|row| row.is_active())
}

#[derive(Clone)]
struct ClusterChoice {
    row: glib::WeakRef<adw::ComboRow>,
    clusters: Vec<String>,
}

impl ClusterChoice {
    /// `None` while the first entry, this server only, is picked.
    fn picked(&self) -> Option<String> {
        let at = usize::try_from(self.row.upgrade()?.selected()).ok()?.checked_sub(1)?;
        self.clusters.get(at).cloned()
    }
}

/// A Cluster row only where the server is one of a cluster it lists: a
/// single server lists none.
fn cluster_choice(
    prompt: &mut CatalogPrompt,
    capabilities: &CatalogCapabilities,
    clusters: Vec<String>,
) -> Option<ClusterChoice> {
    if !capabilities.on_cluster || clusters.is_empty() {
        return None;
    }
    let entries: Vec<String> = std::iter::once(gettext("This server only"))
        .chain(clusters.iter().cloned())
        .collect();
    let row = prompt.combo(&gettext("Cluster"), &entries);
    Some(ClusterChoice { row, clusters })
}

/// A destructive catalog question as the HIG asks for one: Cancel first,
/// the default and what Escape answers; the verb in red; the options as
/// rows of a boxed list; and under Confirm Writes the statements, written
/// again whenever an option changes.
struct CatalogPrompt {
    dialog: adw::AlertDialog,
    content: gtk::Box,
    options: gtk::ListBox,
    switches: Vec<adw::SwitchRow>,
    combos: Vec<adw::ComboRow>,
    sql: Option<gtk::TextBuffer>,
}

impl CatalogPrompt {
    fn new(heading: &str, body: &str, verb: (&'static str, &str), asks_first: Option<&str>) -> Self {
        let body = match asks_first {
            Some(connection) => format!("{}\n{body}", asks_before_writes(connection)),
            None => body.to_owned(),
        };
        let dialog = adw::AlertDialog::new(Some(heading), Some(&body));
        // A table, schema or connection name is never markup.
        dialog.set_heading_use_markup(false);
        dialog.set_body_use_markup(false);
        dialog.add_response(CANCEL, &gettext("_Cancel"));
        dialog.add_response(verb.0, verb.1);
        dialog.set_response_appearance(verb.0, adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some(CANCEL));
        dialog.set_close_response(CANCEL);
        let options = gtk::ListBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .visible(false)
            .build();
        options.add_css_class("boxed-list");
        let content = gtk::Box::new(gtk::Orientation::Vertical, 12);
        content.append(&options);
        let sql = asks_first.and_then(|_| {
            dialog.set_prefer_wide_layout(true);
            let view = crate::ui::review_dialog::sql_view("", &dialog);
            content.append(&view);
            view.child().and_downcast::<gtk::TextView>().map(|text| text.buffer())
        });
        Self {
            dialog,
            content,
            options,
            switches: Vec::new(),
            combos: Vec::new(),
            sql,
        }
    }

    fn switch(&mut self, title: &str, subtitle: &str) -> glib::WeakRef<adw::SwitchRow> {
        let row = adw::SwitchRow::builder().title(title).subtitle(subtitle).build();
        self.options.append(&row);
        self.options.set_visible(true);
        let weak = row.downgrade();
        self.switches.push(row);
        weak
    }

    fn combo(&mut self, title: &str, entries: &[String]) -> glib::WeakRef<adw::ComboRow> {
        let entries: Vec<&str> = entries.iter().map(String::as_str).collect();
        let row = adw::ComboRow::builder()
            .title(title)
            .model(&gtk::StringList::new(&entries))
            .build();
        self.options.append(&row);
        self.options.set_visible(true);
        let weak = row.downgrade();
        self.combos.push(row);
        weak
    }

    /// Write the statements and turn the verb on or off now, and again
    /// whenever an option changes. `state` gives the plan the options
    /// make and whether the verb may answer with them.
    fn follow(&self, verb: &'static str, state: impl Fn() -> (Result<DdlPlan, BuildDdlError>, bool) + 'static) {
        let dialog = self.dialog.downgrade();
        let sql = self.sql.clone();
        let refresh = Rc::new(move || {
            let (planned, allowed) = state();
            if let Some(dialog) = dialog.upgrade() {
                dialog.set_response_enabled(verb, allowed && planned.is_ok());
            }
            if let Some(buffer) = &sql {
                let shown = match &planned {
                    Ok(plan) => plan.preview(),
                    Err(error) => error_text::build_error_text(error),
                };
                buffer.set_text(&shown);
            }
        });
        refresh();
        for row in &self.switches {
            let refresh = refresh.clone();
            row.connect_active_notify(move |_| refresh());
        }
        for row in &self.combos {
            let refresh = refresh.clone();
            row.connect_selected_notify(move |_| refresh());
        }
    }

    fn on_response(&self, verb: &'static str, answered: impl Fn() + 'static) {
        self.dialog.connect_response(Some(verb), move |_, _| answered());
    }

    fn present(self, parent: Option<&gtk::Widget>) {
        if !self.switches.is_empty() || !self.combos.is_empty() || self.sql.is_some() {
            self.dialog.set_extra_child(Some(&self.content));
        }
        self.dialog.present(parent);
    }
}
