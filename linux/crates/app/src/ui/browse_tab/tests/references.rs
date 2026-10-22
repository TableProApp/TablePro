use std::cell::RefCell;
use std::rc::Rc;

use gtk4::subclass::prelude::ObjectSubclassIsExt;
use tablepro_core::browse::RowReference;
use tablepro_core::column::{ColumnKind, TextLength};
use tablepro_core::ddl::InboundForeignKey;
use tablepro_core::filter::{Combinator, FilterOp, FilterRule, FilterSet, FilterValue};
use tablepro_core::meta::TableRef;
use tablepro_core::{ColumnInfo, DriverError, ForeignKeyInfo};
use tablepro_session::fakes::FakeEstablish;
use tablepro_test_support::{CallCounters, FakeReply};

use super::{Harness, TableFilter, WAIT, column, rows, serving_table, text};
use crate::test_support::{drain_main_context, wait_until};
use crate::ui::browse_tab::BrowseTabInput;
use crate::ui::grid::{GridMsg, TableKeys};

fn name_key() -> ForeignKeyInfo {
    ForeignKeyInfo {
        name: "users_name_fkey".to_owned(),
        columns: vec!["name".to_owned()],
        ref_schema: None,
        ref_table: "people".to_owned(),
        ref_columns: vec!["name".to_owned()],
        on_delete: None,
        on_update: None,
    }
}

fn orders_key() -> InboundForeignKey {
    InboundForeignKey {
        name: "orders_user_id_fkey".to_owned(),
        table: TableRef::unqualified("orders"),
        columns: vec!["user_id".to_owned()],
        referenced_columns: vec!["id".to_owned()],
    }
}

fn keys_of(harness: &Harness) -> TableKeys {
    let model = harness.tab().imp().model.borrow();
    let keys = model.as_ref().expect("the tab is open").keys.get();
    (*keys).clone()
}

fn name_is(name: &str) -> FilterSet {
    FilterSet {
        combinator: Combinator::And,
        rules: vec![FilterRule {
            column: "name".to_owned(),
            op: FilterOp::Eq,
            value: Some(FilterValue::Single(name.to_owned())),
        }],
        extra_sql: None,
    }
}

/// The table's columns with `name` typed as text, which a filter binds
/// as text.
fn text_columns() -> Vec<ColumnInfo> {
    let mut name = column("name", false);
    name.column_type.kind = ColumnKind::Text {
        length: TextLength::Unbounded,
    };
    vec![column("id", true), name]
}

/// The filter the tab's table keeps for the next tab opened on it.
fn remembered(harness: &Harness) -> FilterSet {
    let model = harness.tab().imp().model.borrow();
    let model = model.as_ref().expect("the tab is open");
    let connection_id = model.connection_id.expect("a saved connection");
    model.filter_settings.filters(connection_id, None, &model.table)
}

#[gtk4::test]
fn the_tab_reads_its_tables_keys_both_ways_with_its_columns() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada"])));
    script.fetch_foreign_keys.always(FakeReply::ok(vec![name_key()]));
    script
        .fetch_inbound_foreign_keys
        .always(FakeReply::ok(vec![orders_key()]));
    let harness = Harness::open(script, []);
    let counters = harness.connection.counters();

    wait_until(WAIT, || !keys_of(&harness).outbound.is_empty()).expect("the keys were read");

    let keys = keys_of(&harness);
    assert_eq!(keys.table, TableRef::unqualified("users"));
    assert_eq!(keys.outbound, [name_key()]);
    assert_eq!(keys.inbound, [orders_key()]);
    assert_eq!(CallCounters::get(&counters.fetch_inbound_foreign_keys), 1);
}

/// The keys only add to the cell menu, so a read of them that fails
/// leaves the rows on screen and is asked again on the next connection.
#[gtk4::test]
fn a_failed_key_read_leaves_the_rows_and_is_asked_again_on_the_next_link() {
    let mut first = serving_table();
    first.query_bound.always(FakeReply::ok(rows(&["kept"])));
    first
        .fetch_foreign_keys
        .always(FakeReply::err(DriverError::server("permission denied")));
    let mut second = serving_table();
    second.fetch_foreign_keys.always(FakeReply::ok(vec![name_key()]));
    let harness = Harness::open(first, [FakeEstablish::Connect(second)]);
    let counters = harness.connection.counters();
    wait_until(WAIT, || harness.shown() == text(&["kept"])).expect("the first page");
    wait_until(WAIT, || CallCounters::get(&counters.fetch_foreign_keys) == 1).expect("the keys were asked for");
    drain_main_context();
    assert_eq!(harness.visible_page().as_deref(), Some("grid"));
    assert!(keys_of(&harness).outbound.is_empty());

    harness.connection.mark_lost();

    wait_until(WAIT, || keys_of(&harness).outbound == [name_key()]).expect("the keys were asked for again");
    let replacement = harness.fake.replacement();
    assert_eq!(
        CallCounters::get(&replacement.counters().query_bound),
        0,
        "the rows were read again for a failed key read"
    );
    assert_eq!(harness.shown(), text(&["kept"]));
}

#[gtk4::test]
fn a_reference_the_grid_follows_goes_to_the_window() {
    let harness = Harness::open(serving_table(), []);
    let asked = Rc::new(RefCell::new(Vec::new()));
    harness.tab().connect_follow_reference({
        let asked = asked.clone();
        move |_, reference| asked.borrow_mut().push(reference)
    });
    let reference = RowReference {
        table: TableRef::unqualified("people"),
        filter: name_is("Ada"),
    };

    harness
        .tab()
        .send(BrowseTabInput::from(GridMsg::FollowReference(reference.clone())));

    assert_eq!(*asked.borrow(), [reference]);
}

/// A tab opened from a key shows the key's rows without changing the
/// filter the table keeps for the sidebar's next open, until the user
/// applies one of their own.
#[gtk4::test]
fn a_tab_opened_on_a_key_reads_under_its_filter_and_leaves_the_tables_alone() {
    let mut script = serving_table();
    script.fetch_columns.always(FakeReply::ok(text_columns()));
    script
        .query_bound
        .when_sql_contains("\"name\" = ", FakeReply::ok(rows(&["Ada"])))
        .always(FakeReply::ok(rows(&["everyone"])));
    let harness = Harness::open_on(script, name_is("Grace"), TableFilter::Followed(name_is("Ada")));

    wait_until(WAIT, || harness.shown() == text(&["Ada"])).expect("the key's rows");

    assert_eq!(harness.tab().applied_filter(), name_is("Ada"));
    assert_eq!(
        remembered(&harness),
        name_is("Grace"),
        "the key's filter replaced the table's"
    );
    let model = harness.tab().imp().model.borrow();
    let strip = &model.as_ref().expect("the tab is open").filter_strip;
    assert!(strip.revealed(), "the strip that says why one row shows is hidden");
    assert_eq!(strip.filter(), name_is("Ada"));
    drop(model);

    harness
        .tab()
        .send(super::PagingInput::FilterApplied(FilterSet::default()));

    wait_until(WAIT, || harness.shown() == text(&["everyone"])).expect("the cleared filter's rows");
    assert_eq!(
        remembered(&harness),
        FilterSet::default(),
        "an applied filter was not kept for the table"
    );
}

#[gtk4::test]
fn a_restored_tab_keeps_its_own_filter_with_the_strip_closed() {
    let mut script = serving_table();
    script.fetch_columns.always(FakeReply::ok(text_columns()));
    script.query_bound.always(FakeReply::ok(rows(&["Ada"])));
    let harness = Harness::open_on(script, name_is("Grace"), TableFilter::Kept(name_is("Ada")));

    wait_until(WAIT, || harness.shown() == text(&["Ada"])).expect("the first page");

    assert_eq!(harness.tab().applied_filter(), name_is("Ada"));
    assert_eq!(remembered(&harness), name_is("Grace"));
    let model = harness.tab().imp().model.borrow();
    assert!(!model.as_ref().expect("the tab is open").filter_strip.revealed());
}
