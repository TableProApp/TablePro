//! The sidebar of the session's tables: every schema's tables and views
//! in one recycling list, a section per schema, with one shared menu.

mod catalog_watch;
mod key_listing;
mod object_key;
mod sidebar_affordances;
mod sidebar_event;
mod sidebar_header_factory;
mod sidebar_index;
mod sidebar_list;
mod sidebar_list_imp;
mod sidebar_menu;
mod sidebar_model;
mod sidebar_object;
mod sidebar_object_imp;
mod sidebar_row_factory;
mod sidebar_view;
#[cfg(test)]
mod tests;

use std::collections::BTreeSet;
use std::sync::Arc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita::prelude::*;
use tablepro_core::meta::{ObjectInfo, ObjectScope, SchemaInfo, TableRef};
use tablepro_session::runtime::{TaskFailure, Tasks};
use tablepro_session::{ObjectListSnapshot, Session};

pub(super) use catalog_watch::{catalog_watch, reconnect_watch, spawn_local};
pub(crate) use key_listing::{KeySidebar, KeysListed};
pub(super) use sidebar_affordances::SidebarAffordances;
use sidebar_index::SidebarIndex;
pub(super) use sidebar_view::SidebarView;

use super::table_naming::TableNaming;
use super::{OpenMode, Workspace, WorkspaceInput, WorkspaceModel, WorkspaceSender};
use crate::runtime::DeliverInput;
use sidebar_event::SidebarEvent;

/// Build the sidebar into the workspace's template, sending what the
/// user asks of it to `input`. A sidebar of `keys` searches on the
/// server, so its search asks the workspace for a new listing.
pub(super) fn build(
    workspace: &Workspace,
    input: &WorkspaceSender,
    session: &Session,
    tasks: &Tasks,
    keys: bool,
) -> SidebarView {
    let imp = workspace.imp();
    let events = input.clone();
    let view = SidebarView::new(
        move |event| events.deliver(workspace_input(event)),
        SidebarAffordances::for_session(session),
        Some(tasks.clone()),
    );
    imp.sidebar_slot.set_child(Some(view.widget()));
    if keys {
        view.hold_keys();
        let listing = input.clone();
        view.follow_key_search(&imp.table_search, move || listing.deliver(WorkspaceInput::ListKeys));
        describe_key_search(workspace);
        describe_key_empty_page(workspace);
    } else {
        view.follow_search(&imp.table_search);
    }
    imp.table_search_bar.connect_entry(&*imp.table_search);
    imp.table_search_bar.set_key_capture_widget(Some(&*imp.sidebar_root));
    imp.table_search_toggle
        .bind_property("active", &*imp.table_search_bar, "search-mode-enabled")
        .bidirectional()
        .sync_create()
        .build();
    view
}

/// The search and its buttons name keys, not tables.
fn describe_key_search(workspace: &Workspace) {
    let imp = workspace.imp();
    let filter = crate::i18n::gettext("Filter keys");
    imp.table_search
        .set_placeholder_text(Some(&crate::i18n::gettext("Filter keys…")));
    imp.table_search
        .update_property(&[gtk4::accessible::Property::Label(&filter)]);
    crate::ui::a11y::describe_icon_button(
        &imp.table_search_toggle.get(),
        &crate::i18n::gettext("Search Keys"),
        None,
    );
    crate::ui::a11y::describe_icon_button(
        &imp.refresh_tables_button.get(),
        &crate::i18n::gettext("Refresh Keys"),
        Some("win.refresh-tables"),
    );
}

/// The page with no tab open speaks of keys and an editor of commands.
fn describe_key_empty_page(workspace: &Workspace) {
    let imp = workspace.imp();
    imp.empty_page.set_title(&crate::i18n::gettext("Select a Key"));
    imp.empty_page.set_description(Some(&crate::i18n::gettext(
        "Choose a key in the sidebar or open the editor.",
    )));
    imp.empty_editor_button.set_label(&crate::i18n::gettext("Open Editor"));
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
        SidebarEvent::DropTable(table) => WorkspaceInput::DropTablePrompt {
            schema: table.schema,
            table: table.name,
        },
        SidebarEvent::NewTable(schema) => WorkspaceInput::NewTableTab { schema },
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
/// `known` when they cannot be read. The index is built on a blocking
/// thread: sorting a large catalog by collation keys would freeze the
/// window.
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
    tasks
        .spawn_blocking_task(move || {
            let schemas: Option<Arc<[SchemaInfo]>> = schemas.map(|schemas| shown_schemas(&schemas, &objects).into());
            SidebarListing {
                index: SidebarIndex::build(&objects, schemas.as_deref().unwrap_or(&known)),
                schemas,
            }
        })
        .await
}

/// The schemas the sidebar shows sections for: the session's own, and
/// any an object names that the session does not list, as a server whose
/// databases are its schemas lists only the one it is in.
fn shown_schemas(schemas: &[SchemaInfo], objects: &[ObjectInfo]) -> Vec<SchemaInfo> {
    let known: BTreeSet<&str> = schemas.iter().map(|schema| schema.name.as_str()).collect();
    let extra: BTreeSet<&str> = objects
        .iter()
        .filter(|object| object.kind.is_browsable())
        .filter_map(|object| object.schema.as_deref())
        .filter(|schema| !known.contains(schema))
        .collect();
    schemas
        .iter()
        .cloned()
        .chain(extra.into_iter().map(|name| SchemaInfo {
            name: name.to_owned(),
            is_default: false,
            is_system: false,
        }))
        .collect()
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

    /// Read the session's tables again, and every table's columns on
    /// their next ask: what changed the schema did not say which tables
    /// it touched.
    pub(super) fn refresh_catalog(&mut self) {
        if self.keys.is_some() {
            self.list_keys();
            return;
        }
        let Some(session) = self.context.active.get() else {
            return;
        };
        session.invalidate_columns();
        self.on_schema_changed(None, None);
    }

    /// A run that sent DDL, or a commit that may publish it, changes what
    /// the sidebar and the completion list.
    pub(super) fn on_editor_run_finished(&mut self, id: uuid::Uuid) {
        let changed = matches!(
            self.workspace_tabs.borrow().get(&id),
            Some(super::WorkspaceTab::Editor(slot)) if slot.editor.last_run_changes_catalog()
        );
        if changed {
            self.refresh_catalog();
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

    /// With no table tab in front, no row stays selected: one would say
    /// the editor shows that table.
    pub(super) fn sync_sidebar_selection(&self) {
        let shown = self
            .selected_workspace_tab_id()
            .and_then(|id| self.workspace_tabs.borrow().get(&id)?.sidebar_object());
        self.sidebar.sync_selection(shown.as_ref());
    }
}
