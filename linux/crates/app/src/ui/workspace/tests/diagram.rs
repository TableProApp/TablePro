use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_core::column::{ColumnDefault, ColumnType};
use tablepro_core::meta::{ObjectInfo, ObjectKind};
use tablepro_core::{ColumnInfo, ForeignKeyInfo};
use tablepro_test_support::{ConnectionScript, FakeReply};

use super::super::sidebar::SidebarView;
use super::super::{WorkspaceInput, WorkspaceTab};
use crate::runtime::DeliverInput;
use crate::test_support::{drain_main_context, first_descendant_of_type, wait_until};
use crate::ui::diagram::DiagramTab;
use crate::ui::session_window::tests::{Script, TestWindow, WAIT};
use crate::workspace::{DiagramPlace, TabRecord, WorkspaceRecord};

fn column(name: &str, primary_key: bool) -> ColumnInfo {
    ColumnInfo {
        name: name.to_owned(),
        column_type: ColumnType::untyped_text("integer"),
        nullable: false,
        primary_key,
        is_auto_increment: false,
        is_generated: false,
        partition_scoped: false,
        default: ColumnDefault::None,
        comment: None,
    }
}

/// `sales` holds customers and orders, with orders' key to customers.
fn sales(script: &mut ConnectionScript) {
    let object = |name: &str| ObjectInfo {
        schema: Some("sales".to_owned()),
        name: name.to_owned(),
        kind: ObjectKind::Table,
    };
    script
        .list_objects
        .always(FakeReply::ok(vec![object("customers"), object("orders")]));
    script.fetch_columns.when_sql_contains(
        "orders",
        FakeReply::ok(vec![column("id", true), column("customer_id", false)]),
    );
    script.fetch_columns.always(FakeReply::ok(vec![column("id", true)]));
    script.fetch_foreign_keys.when_sql_contains(
        "orders",
        FakeReply::ok(vec![ForeignKeyInfo {
            name: "orders_customer".to_owned(),
            columns: vec!["customer_id".to_owned()],
            ref_schema: Some("sales".to_owned()),
            ref_table: "customers".to_owned(),
            ref_columns: vec!["id".to_owned()],
            on_delete: None,
            on_update: None,
        }]),
    );
    script.fetch_foreign_keys.always(FakeReply::ok(Vec::new()));
    script.fetch_indexes.always(FakeReply::ok(Vec::new()));
}

fn diagrams(test: &TestWindow) -> Vec<DiagramTab> {
    test.workspace()
        .read(|model| {
            model
                .workspace_tabs
                .borrow()
                .values()
                .filter_map(|tab| match tab {
                    WorkspaceTab::Diagram(slot) => Some(slot.diagram.clone()),
                    _ => None,
                })
                .collect()
        })
        .unwrap_or_default()
}

fn show_diagram(test: &TestWindow, schema: &str) {
    test.workspace()
        .input()
        .expect("the workspace's input")
        .deliver(WorkspaceInput::ShowDiagram {
            schema: Some(schema.to_owned()),
        });
}

fn drawn(diagram: &DiagramTab) {
    wait_until(WAIT, || diagram.canvas().table_count() == 2).expect("the diagram's tables");
}

#[gtk4::test]
fn a_schema_has_one_diagram_tab_titled_for_it() {
    let test = TestWindow::connected_with("DiagramOneTab", sales);
    let view = test.workspace().imp().tab_view.get();

    show_diagram(&test, "sales");
    wait_until(WAIT, || diagrams(&test).len() == 1).expect("a diagram tab");
    let diagram = diagrams(&test).remove(0);
    drawn(&diagram);
    let page = view.selected_page().expect("the diagram in front");
    assert_eq!(page.child(), diagram.clone().upcast::<gtk4::Widget>());
    assert_eq!(page.title(), "sales · ER Diagram");
    WidgetExt::activate_action(&test.window, "win.new-editor-tab", None).expect("a new editor tab");
    drain_main_context();

    show_diagram(&test, "sales");
    drain_main_context();

    assert_eq!(diagrams(&test).len(), 1, "a second Show brings the first tab forward");
    assert_eq!(view.selected_page().map(|page| page.child()), Some(diagram.upcast()));
}

#[gtk4::test]
fn the_sidebar_shows_a_tables_schema_as_a_diagram() {
    let test = TestWindow::connected_with("DiagramFromSidebar", sales);
    let sidebar: SidebarView = test
        .workspace()
        .read(|model| model.sidebar.clone())
        .expect("the sidebar");
    wait_until(WAIT, || sidebar.shown() == 2).expect("the sidebar's tables");
    let list: gtk4::ListView = first_descendant_of_type(sidebar.widget()).expect("the sidebar's list");
    let key = (Some("sales".to_owned()), "orders".to_owned()).to_variant();

    WidgetExt::activate_action(&list, "sidebar.show-diagram", Some(&key)).expect("the menu's Show ER Diagram");

    wait_until(WAIT, || diagrams(&test).len() == 1).expect("a diagram tab");
    let diagram = diagrams(&test).remove(0);
    assert_eq!(diagram.schema().as_deref(), Some("sales"));
    WidgetExt::activate_action(&list, "sidebar.show-schema-diagram", Some(&Some("sales").to_variant()))
        .expect("the section header's button");
    drain_main_context();
    assert_eq!(diagrams(&test).len(), 1);
}

#[gtk4::test]
fn the_diagram_opens_a_tables_rows_and_structure() {
    let test = TestWindow::connected_with("DiagramOpensTables", sales);
    show_diagram(&test, "sales");
    wait_until(WAIT, || diagrams(&test).len() == 1).expect("a diagram tab");
    let diagram = diagrams(&test).remove(0);
    drawn(&diagram);
    let canvas = diagram.canvas();
    let orders = (0..2)
        .find(|&at| canvas.table(at).is_some_and(|table| table.name == "orders"))
        .expect("orders");
    canvas.focus_table(orders);

    WidgetExt::activate_action(&diagram, "diagram.open-table", None).expect("Open Table");
    let opened = |test: &TestWindow| {
        test.workspace()
            .read(|model| {
                model.workspace_tabs.borrow().values().any(|tab| {
                    matches!(tab, WorkspaceTab::Table(slot) if slot.table == "orders" && slot.schema.as_deref() == Some("sales"))
                })
            })
            .unwrap_or_default()
    };
    wait_until(WAIT, || opened(&test)).expect("the table's tab");
    WidgetExt::activate_action(&diagram, "diagram.show-structure", None).expect("Show Structure");
    let structure = |test: &TestWindow| {
        test.workspace()
            .read(|model| {
                model
                    .workspace_tabs
                    .borrow()
                    .values()
                    .any(|tab| matches!(tab, WorkspaceTab::Structure(slot) if slot.table == "orders"))
            })
            .unwrap_or_default()
    };
    wait_until(WAIT, || structure(&test)).expect("the structure tab");
}

#[gtk4::test]
fn a_closed_diagram_reopens_and_a_saved_one_comes_back() {
    let test = TestWindow::with_script(
        "DiagramRestore",
        Script {
            connection: {
                let mut script = ConnectionScript::default();
                sales(&mut script);
                script
            },
            ..Default::default()
        },
    );
    let store = test.services.storage.workspaces().clone();
    store
        .schedule(
            &test.key(),
            WorkspaceRecord {
                active_tab: Some(0),
                tabs: vec![TabRecord::Diagram {
                    schema: Some("sales".to_owned()),
                    places: vec![placed()],
                }],
            },
        )
        .expect("the record to queue");
    crate::test_support::finish_on_main(WAIT, store.flush(&test.key()))
        .expect("the flush to end")
        .expect("the record written");

    test.window
        .send(crate::ui::SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("workspace");
    wait_until(WAIT, || diagrams(&test).len() == 1).expect("the saved diagram");
    drawn(&diagrams(&test)[0]);
    assert!(
        diagrams(&test)[0].places().contains(&placed()),
        "the moved table is back where it was put"
    );
    let input = test.workspace().input().expect("the workspace's input");

    input.deliver(WorkspaceInput::CloseActiveWorkspaceTab);
    wait_until(WAIT, || diagrams(&test).is_empty()).expect("the diagram closed");
    input.deliver(WorkspaceInput::ReopenClosedTab);

    wait_until(WAIT, || diagrams(&test).len() == 1).expect("the diagram reopened");
    assert_eq!(diagrams(&test)[0].schema().as_deref(), Some("sales"));
    drawn(&diagrams(&test)[0]);
    assert!(diagrams(&test)[0].places().contains(&placed()));
}

/// Where the saved record says the user put orders.
fn placed() -> DiagramPlace {
    DiagramPlace {
        table: "orders".to_owned(),
        x: 900,
        y: 40,
    }
}

#[gtk4::test]
fn a_change_to_a_table_marks_its_schemas_diagram_out_of_date() {
    let test = TestWindow::connected_with("DiagramOutOfDate", sales);
    show_diagram(&test, "sales");
    wait_until(WAIT, || diagrams(&test).len() == 1).expect("a diagram tab");
    let diagram = diagrams(&test).remove(0);
    drawn(&diagram);
    let banner = diagram.imp().outdated_banner.get();
    let input = test.workspace().input().expect("the workspace's input");

    input.deliver(WorkspaceInput::SchemaChanged {
        schema: Some("audit".to_owned()),
        table: Some("events".to_owned()),
    });
    drain_main_context();
    assert!(!banner.is_revealed(), "another schema's change");

    input.deliver(WorkspaceInput::SchemaChanged {
        schema: Some("sales".to_owned()),
        table: Some("orders".to_owned()),
    });
    wait_until(WAIT, || banner.is_revealed()).expect("the banner offers a refresh");
}

/// The canvas draws in the theme's colours, which the app's stylesheet
/// hands it through its probes: the cards stand out from the window, and
/// the text from the cards.
#[gtk4::test]
fn the_diagram_draws_in_the_themes_colours() {
    let test = TestWindow::connected_with("DiagramColours", sales);
    show_diagram(&test, "sales");
    wait_until(WAIT, || diagrams(&test).len() == 1).expect("a diagram tab");
    let diagram = diagrams(&test).remove(0);
    drawn(&diagram);

    let palette = diagram.canvas().palette();

    assert_ne!(palette.background, palette.text);
    assert_ne!(palette.card, palette.text);
    assert_eq!(palette.background.alpha(), 1.0);
    assert!(palette.accent.alpha() > 0.0);
}
