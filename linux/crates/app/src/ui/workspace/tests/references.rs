use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_core::browse::RowReference;
use tablepro_core::column::{ColumnDefault, ColumnType};
use tablepro_core::filter::{Combinator, FilterOp, FilterRule, FilterSet, FilterValue};
use tablepro_core::meta::{ObjectInfo, ObjectKind, RowCountEstimate, RowIdentity, TableEstimate, TableRef};
use tablepro_core::{ColumnInfo, QueryResult, Value};
use tablepro_test_support::{ConnectionScript, FakeReply};
use uuid::Uuid;

use super::super::workspace_persistence::workspace_record;
use super::super::{OpenMode, WorkspaceInput};
use super::shell_of;
use crate::runtime::DeliverInput;
use crate::test_support::{descendants, drain_main_context, wait_until};
use crate::ui::browse_tab::BrowseTab;
use crate::ui::session_window::tests::{TestWindow, WAIT};
use crate::workspace::TabRecord;

fn column(name: &str, primary_key: bool) -> ColumnInfo {
    ColumnInfo {
        name: name.to_owned(),
        column_type: ColumnType::untyped_text("text"),
        nullable: !primary_key,
        primary_key,
        is_auto_increment: false,
        is_generated: false,
        partition_scoped: false,
        default: ColumnDefault::None,
        comment: None,
    }
}

/// `orders` and `customers`, each with one keyed row.
fn serving_tables(script: &mut ConnectionScript) {
    let columns = [column("id", true), column("name", false)];
    script.fetch_columns.always(FakeReply::ok(columns.to_vec()));
    script.row_identity.always(FakeReply::ok(RowIdentity::UniqueKey {
        columns: vec!["id".to_owned()],
    }));
    script.count_rows.always(FakeReply::ok(1));
    script.table_estimate.always(FakeReply::ok(TableEstimate {
        rows: RowCountEstimate::Approximate(1),
        heap_blocks: None,
    }));
    script.query_bound.always(FakeReply::ok(QueryResult::new(
        columns.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
        vec![vec![Value::Int(42), Value::Text("Ada".to_owned())]],
    )));
    script.list_objects.always(FakeReply::ok(
        ["orders", "customers"]
            .into_iter()
            .map(|name| ObjectInfo {
                schema: None,
                name: name.to_owned(),
                kind: ObjectKind::Table,
            })
            .collect(),
    ));
    script.fetch_outbound_foreign_keys.always(FakeReply::ok(Vec::new()));
    script.fetch_inbound_foreign_keys.always(FakeReply::ok(Vec::new()));
}

fn customer(id: &str) -> RowReference {
    RowReference {
        table: TableRef::unqualified("customers"),
        filter: FilterSet {
            combinator: Combinator::And,
            rules: vec![FilterRule {
                column: "id".to_owned(),
                op: FilterOp::Eq,
                value: Some(FilterValue::Single(id.to_owned())),
            }],
            extra_sql: None,
        },
    }
}

fn open_orders(test: &TestWindow) -> (Uuid, libadwaita::TabPage) {
    let workspace = test.workspace();
    let before = workspace.selected_tab();
    workspace
        .sender()
        .expect("the workspace's input")
        .deliver(WorkspaceInput::SelectTable {
            schema: None,
            name: "orders".to_owned(),
            open_mode: OpenMode::NewTab,
        });
    let mut id = None;
    wait_until(WAIT, || {
        id = workspace.selected_tab().filter(|tab| Some(*tab) != before);
        id.is_some()
    })
    .expect("the orders tab");
    let page = shell_of(&workspace)
        .imp()
        .tab_view
        .selected_page()
        .expect("the orders page");
    (id.expect("the tab's id"), page)
}

fn follow(test: &TestWindow, source: Uuid, reference: RowReference) {
    test.workspace()
        .sender()
        .expect("the workspace's input")
        .deliver(WorkspaceInput::FollowReference {
            tab: source,
            reference: Box::new(reference),
        });
}

/// The table tab in front once it is not `source`.
fn front_tab_other_than(test: &TestWindow, source: &libadwaita::TabPage) -> (libadwaita::TabPage, BrowseTab) {
    let view = shell_of(&test.workspace()).imp().tab_view.clone();
    let mut front = None;
    wait_until(WAIT, || {
        front = view.selected_page().filter(|page| page != source);
        front.is_some()
    })
    .expect("a new tab in front");
    let page = front.expect("the page in front");
    let tab = page.child().downcast::<BrowseTab>().expect("a table tab");
    (page, tab)
}

#[gtk4::test]
fn a_followed_key_opens_its_table_beside_the_tab_under_the_keys_filter() {
    let test = TestWindow::connected_with("FollowOpensBeside", serving_tables);
    let (source, source_page) = open_orders(&test);
    let view = shell_of(&test.workspace()).imp().tab_view.clone();
    // Another tab at the end, so beside the source is not simply last.
    let pages = view.n_pages();
    test.workspace()
        .sender()
        .expect("the workspace's input")
        .deliver(WorkspaceInput::NewEditorTab);
    wait_until(WAIT, || view.n_pages() == pages + 1).expect("the editor tab");
    view.set_selected_page(&source_page);

    follow(&test, source, customer("42"));

    let (page, tab) = front_tab_other_than(&test, &source_page);
    assert_eq!(tab.table(), "customers");
    assert_eq!(tab.applied_filter(), customer("42").filter);
    assert_eq!(view.page_position(&page), view.page_position(&source_page) + 1);
    assert_eq!(page.parent().as_ref(), Some(&source_page));
}

#[gtk4::test]
fn the_same_rows_followed_again_show_the_tab_already_open() {
    let test = TestWindow::connected_with("FollowReveals", serving_tables);
    let (source, source_page) = open_orders(&test);
    let view = shell_of(&test.workspace()).imp().tab_view.clone();
    follow(&test, source, customer("42"));
    let (opened, _) = front_tab_other_than(&test, &source_page);
    let pages = view.n_pages();

    view.set_selected_page(&source_page);
    follow(&test, source, customer("42"));
    wait_until(WAIT, || view.selected_page().as_ref() == Some(&opened)).expect("the open tab comes back");
    view.set_selected_page(&source_page);
    follow(&test, source, customer("7"));
    let (other, tab) = front_tab_other_than(&test, &source_page);

    assert_eq!(view.n_pages(), pages + 1, "only the other customer opened a tab");
    assert_ne!(other, opened);
    assert_eq!(tab.applied_filter(), customer("7").filter);
}

#[gtk4::test]
fn a_key_to_a_table_that_is_gone_says_so_and_opens_nothing() {
    let test = TestWindow::connected_with("FollowMissing", serving_tables);
    let (source, _) = open_orders(&test);
    let view = shell_of(&test.workspace()).imp().tab_view.clone();
    let pages = view.n_pages();
    let overlay = shell_of(&test.workspace()).toast_overlay();

    follow(
        &test,
        source,
        RowReference {
            table: TableRef::unqualified("ghost"),
            ..customer("42")
        },
    );

    wait_until(WAIT, || {
        descendants(&overlay)
            .iter()
            .filter_map(|widget| widget.downcast_ref::<gtk4::Label>())
            .any(|label| label.label() == "Can't find the table ghost")
    })
    .expect("the toast says the table is gone");
    drain_main_context();
    assert_eq!(view.n_pages(), pages);
}

/// Two tabs on one table keep their own filters through a restart and a
/// reopen, rather than the table's last one.
#[gtk4::test]
fn a_followed_tab_keeps_its_filter_in_the_saved_tabs_and_through_a_reopen() {
    let test = TestWindow::connected_with("FollowKeepsFilter", serving_tables);
    let (source, source_page) = open_orders(&test);
    follow(&test, source, customer("42"));
    let (page, _) = front_tab_other_than(&test, &source_page);
    let workspace = test.workspace();

    let record = workspace
        .with_model(|model| workspace_record(&model.tab_view, &model.workspace_tabs.borrow(), &model.index))
        .expect("the saved tabs");
    let kept: Vec<Option<FilterSet>> = record
        .tabs
        .iter()
        .filter_map(|tab| match tab {
            TabRecord::Table { table, filter, .. } if table == "customers" => Some(filter.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(kept, [Some(customer("42").filter)]);

    shell_of(&workspace).imp().tab_view.set_selected_page(&page);
    let input = workspace.sender().expect("the workspace's input");
    input.deliver(WorkspaceInput::CloseActiveWorkspaceTab);
    wait_until(WAIT, || {
        shell_of(&workspace).imp().tab_view.selected_page().as_ref() == Some(&source_page)
    })
    .expect("the tab closes back to its source");
    WidgetExt::activate_action(&test.window, "win.reopen-closed-tab", None).expect("win.reopen-closed-tab");
    let (_, reopened) = front_tab_other_than(&test, &source_page);

    assert_eq!(reopened.table(), "customers");
    assert_eq!(reopened.applied_filter(), customer("42").filter);
}
