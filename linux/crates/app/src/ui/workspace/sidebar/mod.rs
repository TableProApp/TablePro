//! The sidebar of the session's tables: every schema's tables and views
//! in one recycling list, a section per schema, with one shared menu.

mod catalog_watch;
mod object_key;
mod sidebar_affordances;
mod sidebar_event;
mod sidebar_header_factory;
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
use tablepro_session::ObjectListSnapshot;

pub(super) use catalog_watch::{catalog_watch, reconnect_watch, spawn_local};
pub(super) use sidebar_affordances::SidebarAffordances;
pub(super) use sidebar_view::SidebarView;

use super::table_naming::TableNaming;
use super::{OpenMode, Workspace, WorkspaceInput, WorkspaceModel, WorkspaceSender};
use crate::runtime::DeliverInput;
use sidebar_event::SidebarEvent;

/// Build the sidebar into the workspace's template, sending what the
/// user asks of it to `input`.
pub(super) fn build(workspace: &Workspace, input: &WorkspaceSender, affordances: SidebarAffordances) -> SidebarView {
    let imp = workspace.imp();
    let events = input.clone();
    let view = SidebarView::new(move |event| events.deliver(workspace_input(event)), affordances);
    imp.sidebar_slot.set_child(Some(view.widget()));
    view.follow_search(&imp.table_search);
    imp.table_search_bar.connect_entry(&*imp.table_search);
    imp.table_search_bar.set_key_capture_widget(Some(&*imp.sidebar_root));
    imp.table_search_toggle
        .bind_property("active", &*imp.table_search_bar, "search-mode-enabled")
        .bidirectional()
        .sync_create()
        .build();
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
        SidebarEvent::DropTable(table) => WorkspaceInput::DropTablePrompt {
            schema: table.schema,
            table: table.name,
        },
        SidebarEvent::NewTable(schema) => WorkspaceInput::NewTableTab { schema },
    }
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
    /// the connect read. Then every schema's list is asked for.
    pub(super) fn open_sidebar(&mut self) {
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
        self.sidebar.apply_objects(&objects, &self.catalog_schemas);
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
        crate::runtime::spawn_and_deliver(
            &self.context.tasks,
            async move { session.schemas().await },
            move |schemas| {
                let schemas = match schemas {
                    Ok(Ok(schemas)) => Some(schemas),
                    Ok(Err(error)) => {
                        tracing::debug!(%error, "the schemas could not be read for the sidebar");
                        None
                    }
                    Err(failure) => {
                        tracing::debug!(%failure, "the schema read for the sidebar did not finish");
                        None
                    }
                };
                input.deliver(WorkspaceInput::SidebarRead { read, objects, schemas });
            },
        );
    }

    pub(super) fn on_sidebar_read(
        &mut self,
        read: u64,
        objects: &Arc<[ObjectInfo]>,
        schemas: Option<Arc<[SchemaInfo]>>,
    ) {
        if read != self.sidebar_read {
            return;
        }
        if let Some(schemas) = schemas {
            self.catalog_schemas = shown_schemas(&schemas, objects).into();
        }
        self.sidebar.apply_objects(objects, &self.catalog_schemas);
        self.on_table_naming(TableNaming::of(&self.catalog_schemas));
    }

    /// Every schema's list landed: a reconnect, a schema change or the
    /// first read.
    pub(super) fn on_catalog_changed(&mut self, snapshot: ObjectListSnapshot) {
        self.all_schemas_listed = true;
        self.read_sidebar(snapshot.objects);
    }

    pub(super) fn on_catalog_read_failed(&self, message: &str) {
        self.show_toast(&crate::i18n::gettext_f(
            "Could not refresh the table list: {error}",
            &[("error", message)],
        ));
    }

    /// A reconnect committed the default schema's list and left every
    /// other list stale, so the sidebar's is read again. Until every
    /// schema's list first lands, the default schema's is what it shows.
    pub(super) fn on_default_list_committed(&mut self, snapshot: ObjectListSnapshot) {
        if !self.all_schemas_listed {
            self.read_sidebar(snapshot.objects);
        }
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
        let table = self
            .selected_browse_slot_table()
            .map(|(schema, name)| TableRef::new(schema, name));
        self.sidebar.sync_selection(table.as_ref());
    }
}
