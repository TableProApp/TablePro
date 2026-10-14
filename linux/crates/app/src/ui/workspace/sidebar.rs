//! The sidebar of the session's tables.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use relm4::factory::FactoryVecDeque;

use tablepro_core::meta::{ObjectInfo, ObjectScope};
use tablepro_session::runtime::WatchForwarder;
use tablepro_session::{ObjectListSnapshot, Session};

use super::{OpenMode, Workspace, WorkspaceInput, WorkspaceModel, WorkspaceSender, sidebar_section_header};
use crate::runtime::DeliverInput;
use crate::services::session_context::SessionContext;
use crate::ui::sidebar_row::{SidebarRow, SidebarRowOutput};

/// The sidebar's rows, and the schema each one is in, by row index.
pub(super) struct Sidebar {
    pub factory: FactoryVecDeque<SidebarRow>,
    /// Takes the rows' output to the workspace.
    pub bridge: glib::JoinHandle<()>,
    pub schemas: Rc<RefCell<Vec<Option<String>>>>,
}

pub(super) fn spawn_local(future: futures::future::LocalBoxFuture<'static, ()>) {
    glib::spawn_future_local(future);
}

/// Deliver each new object list the session's catalog commits for the
/// sidebar's scope. The list on screen when the watch starts is not
/// delivered again, and a refresh that failed keeps the list it had.
pub(super) fn catalog_watch(
    session: &Arc<Session>,
    mut deliver: impl FnMut(ObjectListSnapshot) + 'static,
) -> WatchForwarder {
    let objects = session.subscribe_objects(ObjectScope::DefaultSchema);
    let mut shown = objects.borrow().generation;
    WatchForwarder::new(
        objects,
        move |snapshot: ObjectListSnapshot| {
            if snapshot.generation != shown {
                shown = snapshot.generation;
                deliver(snapshot);
            } else if let Some(error) = &snapshot.last_error {
                tracing::warn!(%error, "the table list could not be read again");
            }
        },
        spawn_local,
    )
}

pub(super) fn build(workspace: &Workspace, context: &Rc<SessionContext>, input: &WorkspaceSender) -> Sidebar {
    let imp = workspace.imp();
    let schemas: Rc<RefCell<Vec<Option<String>>>> = Rc::new(RefCell::new(Vec::new()));
    let (bridge_sender, bridge) = crate::runtime::relm4_bridge(input.clone());
    let factory: FactoryVecDeque<SidebarRow> = FactoryVecDeque::builder()
        .launch(
            gtk::ListBox::builder()
                .selection_mode(gtk::SelectionMode::Single)
                .activate_on_single_click(true)
                .css_classes(["navigation-sidebar"])
                .build(),
        )
        .forward(&bridge_sender, |out| match out {
            // A plain click and Enter come through the list box's
            // row-activated below, the one signal that fires for both.
            SidebarRowOutput::OpenInNewTab { schema, name } => WorkspaceInput::SelectTable {
                schema,
                name,
                open_mode: OpenMode::NewTab,
            },
            SidebarRowOutput::EditStructure { schema, name } => {
                WorkspaceInput::EditStructureTab { schema, table: name }
            }
            SidebarRowOutput::ShowCreateTable { schema, name } => {
                WorkspaceInput::ShowCreateTableForExisting { schema, table: name }
            }
            SidebarRowOutput::ImportCsv { schema, name } => WorkspaceInput::ImportCsvRequested { schema, table: name },
            SidebarRowOutput::DropTable { schema, name } => WorkspaceInput::DropTablePrompt { schema, table: name },
        });

    let listbox = factory.widget();
    imp.sidebar_scroll.set_child(Some(listbox));

    let schemas_for_activate = schemas.clone();
    let activate_input = input.clone();
    listbox.connect_row_activated(move |_, row| {
        let name = row.widget_name().to_string();
        let index = usize::try_from(row.index()).unwrap_or_default();
        let schema = schemas_for_activate.borrow().get(index).cloned().unwrap_or(None);
        activate_input.deliver(WorkspaceInput::SelectTable {
            schema,
            name,
            open_mode: OpenMode::SwitchOrAppend,
        });
    });

    let search = imp.table_search.get();
    let schemas_for_filter = schemas.clone();
    listbox.set_filter_func(move |row| {
        let query = search.text().to_lowercase();
        // The schema matches too, so "auth" finds every table in that
        // schema, and so does the dotted name the tab title shows.
        sidebar_row_matches(
            &query,
            &row.widget_name(),
            schemas_for_filter
                .borrow()
                .get(usize::try_from(row.index()).unwrap_or_default())
                .and_then(|schema| schema.as_deref()),
        )
    });
    let listbox_for_invalidate = listbox.clone();
    imp.table_search.connect_search_changed(move |_| {
        listbox_for_invalidate.invalidate_filter();
    });
    imp.table_search_bar.connect_entry(&*imp.table_search);
    imp.table_search_bar.set_key_capture_widget(Some(&*imp.sidebar_root));

    // An empty list with no placeholder reads as broken.
    let placeholder = adw::StatusPage::builder()
        .icon_name(crate::ui::icons::VIEW_LIST)
        .title(crate::i18n::gettext("No tables"))
        .description(crate::i18n::gettext(
            "Nothing matches the current search, or this connection has no tables yet.",
        ))
        .build();
    placeholder.add_css_class("compact");
    listbox.set_placeholder(Some(&placeholder));

    imp.table_search_toggle
        .bind_property("active", &*imp.table_search_bar, "search-mode-enabled")
        .bidirectional()
        .sync_create()
        .build();

    let schemas_for_header = schemas.clone();
    let header_input = input.clone();
    let session = context.active.clone();
    listbox.set_header_func(move |row, before| {
        let schemas = schemas_for_header.borrow();
        let distinct: std::collections::BTreeSet<&str> = schemas.iter().filter_map(|s| s.as_deref()).collect();
        // A connection with one schema still gets a header, for its
        // "New Table" button.
        let multi_schema = distinct.len() >= 2;
        let current = schemas
            .get(usize::try_from(row.index()).unwrap_or_default())
            .cloned()
            .flatten();
        let previous = before
            .and_then(|before| schemas.get(usize::try_from(before.index()).unwrap_or_default()))
            .cloned()
            .flatten();
        let needs = match (&current, &previous) {
            (Some(current), Some(previous)) => current != previous,
            (Some(_), None) => true,
            (None, None) => before.is_none() && !multi_schema,
            (None, Some(_)) => false,
        };
        if !needs {
            row.set_header(gtk::Widget::NONE);
            return;
        }
        let can_create_table = session
            .get()
            .and_then(|session| session.current_dialect())
            .and_then(|dialect| dialect.ddl().map(|ddl| ddl.capabilities().create_table))
            .unwrap_or(false);
        let input = header_input.clone();
        let schema = current.clone();
        let header = sidebar_section_header::sidebar_section_header(current.as_deref(), can_create_table, move || {
            input.deliver(WorkspaceInput::NewTableTab { schema: schema.clone() });
        });
        row.set_header(Some(&header));
    });

    Sidebar {
        factory,
        bridge,
        schemas,
    }
}

/// Whether a row shows for `query`, already lowercased: by its table
/// name, its schema, or the two as `schema.table`.
fn sidebar_row_matches(query: &str, table: &str, schema: Option<&str>) -> bool {
    if query.is_empty() {
        return true;
    }
    let table = table.to_lowercase();
    if table.contains(query) {
        return true;
    }
    let Some(schema) = schema else {
        return false;
    };
    let schema = schema.to_lowercase();
    schema.contains(query) || format!("{schema}.{table}").contains(query)
}

/// Only what the grid can page through: routines and sequences have no
/// rows to show.
fn browsable(objects: Vec<ObjectInfo>) -> Vec<ObjectInfo> {
    objects
        .into_iter()
        .filter(|object| object.kind.is_browsable())
        .collect()
}

impl WorkspaceModel {
    pub(super) fn show_objects(&mut self, objects: &[ObjectInfo]) {
        self.repopulate_sidebar(browsable(objects.to_vec()));
    }

    fn repopulate_sidebar(&mut self, objects: Vec<ObjectInfo>) {
        {
            let mut schemas = self.sidebar_schemas.borrow_mut();
            schemas.clear();
            schemas.extend(objects.iter().map(|object| object.schema.clone()));
        }
        let mut guard = self.sidebar_factory.guard();
        guard.clear();
        for object in objects {
            guard.push_back(object);
        }
        drop(guard);
        self.sidebar_factory.widget().invalidate_headers();
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::collections::VecDeque;
    use std::rc::Rc;
    use std::time::Duration;

    use tablepro_core::meta::ObjectKind;
    use tablepro_test_support::{CallCounters, ConnectionScript, FakeReply};

    use super::*;
    use crate::test_support::FakeSession;

    fn names(snapshot: &ObjectListSnapshot) -> Vec<String> {
        snapshot.objects.iter().map(|object| object.name.clone()).collect()
    }

    /// The workspace's input queue, holding what the catalog watch
    /// posted until the workspace handles it.
    type Queue = Rc<RefCell<VecDeque<ObjectListSnapshot>>>;

    fn post_to(queue: &Queue) -> impl FnMut(ObjectListSnapshot) + 'static {
        let queue = queue.clone();
        move |update| queue.borrow_mut().push_back(update)
    }

    fn refresh_objects(
        session: &Arc<Session>,
        runtime: &crate::runtime::AppRuntime,
    ) -> impl Future<Output = ()> + use<> {
        let session = session.clone();
        let refreshing = runtime
            .tasks()
            .spawn_task(async move { session.refresh_objects(ObjectScope::DefaultSchema).await });
        async move {
            let _ = refreshing.await;
        }
    }

    fn object(name: &str, kind: ObjectKind) -> ObjectInfo {
        ObjectInfo {
            schema: Some("public".to_owned()),
            name: name.to_owned(),
            kind,
        }
    }

    /// A workspace drops its catalog watch with itself, so a list read
    /// for its session after that reaches nothing.
    #[gtk4::test]
    fn a_late_catalog_commit_after_the_watch_drops_is_not_delivered() {
        let runtime = crate::test_support::test_runtime();
        let mut script = ConnectionScript::default();
        script.list_objects.always(FakeReply::Late {
            after: Duration::from_millis(300),
            outcome: Ok(vec![object("late", ObjectKind::Table)]),
        });
        let fake = FakeSession::start(script, [], runtime.tasks());
        let queue = Queue::default();
        let watching = catalog_watch(&fake.session, post_to(&queue));
        let late = refresh_objects(&fake.session, &runtime);
        let counters = fake.connection.counters();
        crate::test_support::wait_until(Duration::from_secs(5), || {
            CallCounters::get(&counters.list_objects) == 1
        })
        .expect("the list was asked for");

        drop(watching);
        crate::test_support::finish_on_main(Duration::from_secs(5), late).expect("the list to land");
        crate::test_support::drain_main_context();

        assert_eq!(
            names(&fake.session.subscribe_objects(ObjectScope::DefaultSchema).borrow()),
            ["late"],
            "the late list never landed, so the test proved nothing"
        );
        assert!(queue.borrow().is_empty(), "a dropped watch still delivered");
    }

    #[gtk4::test]
    fn a_new_list_is_delivered_once() {
        let runtime = crate::test_support::test_runtime();
        let mut script = ConnectionScript::default();
        script
            .list_objects
            .always(FakeReply::ok(vec![object("users", ObjectKind::Table)]));
        let fake = FakeSession::start(script, [], runtime.tasks());
        let queue = Queue::default();
        let _watching = catalog_watch(&fake.session, post_to(&queue));

        crate::test_support::finish_on_main(Duration::from_secs(5), refresh_objects(&fake.session, &runtime))
            .expect("the list to land");
        crate::test_support::wait_until(Duration::from_secs(5), || queue.borrow().len() == 1)
            .expect("the list was delivered");
        crate::test_support::drain_main_context();

        assert_eq!(queue.borrow().len(), 1);
        assert_eq!(names(&queue.borrow()[0]), ["users"]);
    }

    #[test]
    fn the_sidebar_lists_only_what_the_grid_can_page() {
        let listed = browsable(vec![
            object("users", ObjectKind::Table),
            object("active_users", ObjectKind::View),
            object("next_id", ObjectKind::Sequence),
            object("refresh", ObjectKind::Function),
        ]);

        let names: Vec<&str> = listed.iter().map(|object| object.name.as_str()).collect();
        assert_eq!(names, ["users", "active_users"]);
    }

    #[test]
    fn a_search_matches_the_table_its_schema_or_both() {
        assert!(sidebar_row_matches("", "users", None));
        assert!(sidebar_row_matches("use", "Users", Some("public")));
        assert!(sidebar_row_matches("auth", "tokens", Some("auth")));
        assert!(sidebar_row_matches("auth.tok", "tokens", Some("Auth")));
        assert!(!sidebar_row_matches("auth", "tokens", None));
    }
}
