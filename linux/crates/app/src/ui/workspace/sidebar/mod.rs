//! The window's connection tree, and each session's part of it: the
//! session's schemas and their tables, indexed off the GTK thread, with
//! the table actions their menus reach.

mod catalog_watch;
mod connection_tree;
mod key_listing;
mod object_key;
mod object_target;
mod sidebar_affordances;
mod sidebar_event;
mod sidebar_index;
mod sidebar_list;
mod sidebar_list_imp;
mod sidebar_menu;
mod sidebar_model;
mod sidebar_object;
mod sidebar_object_imp;
mod sidebar_view;
#[cfg(test)]
pub(crate) mod tests;
mod tree_menu;
mod tree_node;
mod tree_row;

use std::sync::Arc;

use gtk4::prelude::*;
use tablepro_core::DataModel;
use tablepro_core::ddl;
use tablepro_core::dialect::{DatabaseLayout, SqlDialect};
use tablepro_core::meta::{ObjectInfo, ObjectScope, SchemaInfo, TableRef};
use tablepro_session::runtime::{TaskFailure, Tasks};
use tablepro_session::{ObjectListSnapshot, Session};

pub(super) use catalog_watch::{catalog_watch, reconnect_watch, spawn_local};
pub(crate) use connection_tree::{ConnectionTree, SessionRowState};
pub(crate) use key_listing::{KeySidebar, KeysListed};
pub(super) use sidebar_affordances::SidebarAffordances;
use sidebar_index::SidebarIndex;
pub(super) use sidebar_view::SidebarView;

use super::table_naming::TableNaming;
use super::{OpenMode, WorkspaceInput, WorkspaceModel, WorkspaceSender};
use crate::runtime::DeliverInput;
use sidebar_event::SidebarEvent;

/// Build the session's part of the sidebar, sending what the user asks
/// of it to `input`. A sidebar of keys searches on the server, so a
/// search the tree gives it asks the workspace for a new listing; one of
/// collections lists them as tables are listed, in its own words.
pub(super) fn build(input: &WorkspaceSender, session: &Session, tasks: &Tasks, model: DataModel) -> SidebarView {
    let events = input.clone();
    let view = SidebarView::new(
        move |event| events.deliver(workspace_input(event)),
        SidebarAffordances::for_session(session),
        Some(tasks.clone()),
    );
    match model {
        DataModel::KeyValue => {
            let listing = input.clone();
            view.hold_keys(move || listing.deliver(WorkspaceInput::ListKeys));
        }
        DataModel::Document => view.hold_collections(),
        DataModel::Relational => {}
    }
    view
}

fn workspace_input(event: SidebarEvent) -> WorkspaceInput {
    let select = |table: TableRef, open_mode| WorkspaceInput::SelectTable {
        schema: table.schema,
        name: table.name,
        open_mode,
    };
    match event {
        SidebarEvent::Open(table) => select(table, OpenMode::SwitchOrAppend),
        SidebarEvent::OpenInNewTab(table) => select(table, OpenMode::NewTab),
        SidebarEvent::EditStructure(table) => WorkspaceInput::EditStructureTab {
            schema: table.schema,
            table: table.name,
        },
        SidebarEvent::ShowCreateTable(table) => WorkspaceInput::ShowCreateTableForExisting {
            schema: table.schema,
            table: table.name,
        },
        SidebarEvent::ImportCsv(table) => WorkspaceInput::ImportCsvRequested {
            schema: table.schema,
            table: table.name,
        },
        SidebarEvent::TruncateTable(table) => WorkspaceInput::TruncateTablePrompt(table),
        SidebarEvent::DropTable(table) => WorkspaceInput::DropTablePrompt {
            schema: table.schema,
            table: table.name,
        },
        SidebarEvent::NewTable(schema) => WorkspaceInput::NewTableTab { schema },
        SidebarEvent::NewSchema => WorkspaceInput::NewSchemaPrompt,
        SidebarEvent::DropSchema(schema) => WorkspaceInput::DropSchemaPrompt(schema),
        SidebarEvent::DropDatabase(database) => WorkspaceInput::DropDatabasePrompt(database),
        SidebarEvent::ShowDiagram(schema) => WorkspaceInput::ShowDiagram { schema },
        SidebarEvent::ShowDefinition(object) => WorkspaceInput::ShowDefinition(object),
    }
}

/// What the sidebar shows for one object list: its index, and the
/// schemas its sections were made from when they could be read.
#[derive(Debug)]
pub(crate) struct SidebarListing {
    pub(crate) index: SidebarIndex,
    pub(crate) schemas: Option<Arc<[SchemaInfo]>>,
}

/// Read the session's schemas and index `objects` under them, or under
/// `known` when they cannot be read, offering to drop none the session
/// keeps. The index is built on a blocking thread: sorting a large
/// catalog by collation keys would freeze the window.
pub(super) async fn list_catalog(
    session: Arc<Session>,
    tasks: Tasks,
    objects: Arc<[ObjectInfo]>,
    known: Arc<[SchemaInfo]>,
) -> Result<SidebarListing, TaskFailure> {
    let schemas = match session.schemas().await {
        Ok(schemas) => Some(schemas),
        Err(error) => {
            tracing::debug!(%error, "the schemas could not be read for the sidebar");
            None
        }
    };
    let dialect = session.current_dialect();
    let database = session.database().map(str::to_owned);
    tasks
        .spawn_blocking_task(move || {
            let listed = schemas.as_deref().unwrap_or(&known);
            let mut index = SidebarIndex::build(&objects, listed);
            index.withhold_drops(|name| kept(dialect.as_deref(), database.as_deref(), name));
            if dialect
                .as_deref()
                .is_some_and(|dialect| dialect.unqualified_default_schema())
                && let Some(default) = listed.iter().find(|schema| schema.is_default)
            {
                index.unqualify(&default.name);
            }
            SidebarListing { index, schemas }
        })
        .await
}

/// Whether the sidebar never offers to drop the schema `name`. Where the
/// schemas are the server's databases, that is the database the session
/// opened or one the engine keeps for itself; elsewhere a schema the
/// engine keeps, whatever the database is called. The index already
/// withholds the default schema. A session with no connection offers
/// none.
fn kept(dialect: Option<&dyn SqlDialect>, database: Option<&str>, name: &str) -> bool {
    let Some(dialect) = dialect else {
        return true;
    };
    match dialect.database_layout() {
        DatabaseLayout::AsSchemas => database == Some(name) || ddl::protects_database(dialect, name),
        DatabaseLayout::WithSchemas | DatabaseLayout::Single => ddl::protects_schema(dialect, name),
    }
}

impl WorkspaceModel {
    /// What the sidebar shows before the list of every schema lands: that
    /// list when the session read it, or else the default schema's, which
    /// the connect read. Then every schema's list is asked for. Nothing
    /// is shown until the first list is indexed, which takes a large
    /// catalog longer than a frame.
    pub(super) fn open_sidebar(&mut self) {
        if self.keys.is_some() {
            self.list_keys();
            return;
        }
        let Some(session) = self.context.active.get() else {
            return;
        };
        let all = session.catalog().subscribe(ObjectScope::AllSchemas).borrow().clone();
        self.all_schemas_listed = all.generation > 0;
        let objects = if self.all_schemas_listed {
            all.objects
        } else {
            session
                .subscribe_objects(ObjectScope::DefaultSchema)
                .borrow()
                .objects
                .clone()
        };
        self.read_sidebar(objects);
        self.list_all_schemas();
    }

    fn list_all_schemas(&self) {
        let Some(session) = self.context.active.get() else {
            return;
        };
        // The catalog watch delivers what lands, and a failure keeps the
        // list there was.
        drop(
            self.context
                .tasks
                .spawn_task(async move { session.objects(ObjectScope::AllSchemas).await }),
        );
    }

    /// Read the session's schemas, which place the sidebar's sections and
    /// decide whether tab titles name their schema, then show `objects`
    /// under them. Only the last read asked for is shown.
    fn read_sidebar(&mut self, objects: Arc<[ObjectInfo]>) {
        let Some(session) = self.context.active.get() else {
            return;
        };
        self.sidebar_read += 1;
        let read = self.sidebar_read;
        let input = self.input.clone();
        let listing = list_catalog(
            session,
            self.context.tasks.clone(),
            objects,
            self.catalog_schemas.clone(),
        );
        crate::runtime::spawn_and_deliver(&self.context.tasks, listing, move |listing| {
            match listing.and_then(|listing| listing) {
                Ok(listing) => input.deliver(WorkspaceInput::SidebarRead { read, listing }),
                Err(failure) => tracing::warn!(%failure, "the sidebar's list could not be indexed"),
            }
        });
    }

    pub(super) fn on_sidebar_read(&mut self, read: u64, listing: SidebarListing) {
        if read != self.sidebar_read {
            // A catalog's index frees a few strings per table.
            drop(self.context.tasks.spawn_blocking_task(move || drop(listing)));
            return;
        }
        if let Some(schemas) = listing.schemas {
            self.catalog_schemas = schemas;
        }
        self.sidebar.show(listing.index);
        self.on_table_naming(TableNaming::of(&self.catalog_schemas));
    }

    /// Every schema's list landed: a reconnect, a schema change or the
    /// first read.
    pub(super) fn on_catalog_changed(&mut self, snapshot: ObjectListSnapshot) {
        // A key-value engine's catalog is empty; its keys are listed apart.
        if self.keys.is_some() {
            return;
        }
        self.all_schemas_listed = true;
        self.catalog_banner.set_revealed(false);
        self.read_sidebar(snapshot.objects);
    }

    /// The list on screen stays, under a banner that says why it could
    /// not be read again and stays until a read lands. The banner wraps
    /// to three lines, so the whole reason is in its tooltip too.
    pub(super) fn on_catalog_read_failed(&self, message: &str) {
        let title = crate::i18n::gettext_f("Could not refresh the table list: {error}", &[("error", message)]);
        self.catalog_banner.set_title(&title);
        self.catalog_banner.set_tooltip_text(Some(&title));
        self.catalog_banner.set_revealed(true);
    }

    /// Read the session's schemas and tables again, and every table's
    /// columns on their next ask: what changed the schema did not say
    /// which tables it touched. Another tab or client may have made or
    /// dropped a database, so the editors' database menus are read again
    /// too.
    pub(super) fn refresh_catalog(&mut self) {
        self.relist_editor_databases();
        if self.keys.is_some() {
            self.list_keys();
            return;
        }
        let Some(session) = self.context.active.get() else {
            return;
        };
        session.invalidate_columns();
        self.diagrams_out_of_date(None, false);
        self.catalog_shape_changed();
    }

    /// A schema or database was made or dropped. The schemas are read
    /// before the objects, so the list the catalog watch takes to the
    /// sidebar is indexed under the new ones; then the default schema's
    /// list, which the editor's completion reads, one read at a time.
    pub(super) fn catalog_shape_changed(&self) {
        let Some(session) = self.context.active.get() else {
            return;
        };
        drop(self.context.tasks.spawn_task(async move {
            // A failure keeps the schemas there were, under which the
            // new objects still show.
            if let Err(error) = session.refresh_schemas().await {
                tracing::debug!(%error, "the schemas could not be read again");
            }
            let _ = session.refresh_objects(ObjectScope::AllSchemas).await;
            let _ = session.refresh_objects(ObjectScope::DefaultSchema).await;
        }));
    }

    /// A run that sent DDL, or a commit that may publish it, changes what
    /// the sidebar and the completion list.
    pub(super) fn on_editor_run_finished(&mut self, id: uuid::Uuid) {
        let moved_to = match self.workspace_tabs.borrow().get(&id) {
            Some(super::WorkspaceTab::Editor(slot)) if slot.editor.last_run_changes_catalog() => {
                Some(slot.editor.tab_database())
            }
            _ => None,
        };
        let Some(moved_to) = moved_to else {
            return;
        };
        self.refresh_catalog();
        // The statement ran in the tab's database, whose session the
        // window may hold beside this one (0030).
        if let (Some(database), Some(shell)) = (moved_to, self.shell.upgrade()) {
            shell.tell_window(crate::ui::SessionWindowInput::MovedTab(crate::ui::MovedTab::Refresh {
                key: self.key.clone(),
                database,
            }));
        }
    }

    /// A reconnect committed the default schema's list and its schemas,
    /// and left every other list stale, so the sidebar's is read again.
    /// The schemas are read now, under the list on screen, so they name
    /// the tabs even when every schema's list cannot be read again.
    /// Until every schema's list first lands, the default schema's is
    /// what the sidebar shows.
    pub(super) fn on_default_list_committed(&mut self, snapshot: ObjectListSnapshot) {
        // A reconnect of a key-value engine lists its keys again.
        if self.keys.is_some() {
            self.list_keys();
            return;
        }
        let objects = match (self.all_schemas_listed, self.context.active.get()) {
            (true, Some(session)) => session
                .catalog()
                .subscribe(ObjectScope::AllSchemas)
                .borrow()
                .objects
                .clone(),
            _ => snapshot.objects,
        };
        self.read_sidebar(objects);
        self.list_all_schemas();
    }

    /// The connection was replaced, perhaps by one to another server
    /// version, so what the sidebar offers is read again.
    pub(super) fn on_link_changed(&self) {
        if let Some(session) = self.context.active.get() {
            self.sidebar.set_affordances(SidebarAffordances::for_session(&session));
        }
    }
}
