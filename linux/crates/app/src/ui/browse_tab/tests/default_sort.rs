use std::sync::Arc;
use std::time::Duration;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_core::DriverError;
use tablepro_test_support::{ConnectionScript, FakeReply};

use super::super::{GridInput, InitialSort, PagingInput};
use super::{Harness, WAIT, column, column_view, page_queries, rows, serving_table};
use crate::test_support::wait_until;
use crate::ui::data_grid::GridRequest;

fn serving_rows() -> ConnectionScript {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada"])));
    script
}

fn loaded(harness: &Harness) {
    wait_until(WAIT, || !harness.tab().is_loading() && harness.shown().len() == 1).expect("first page");
}

#[gtk4::test]
fn the_default_sort_reaches_the_first_page_query_and_header() {
    let harness = Harness::open_with_sort(serving_rows(), InitialSort::Default, "primary-key", "descending");
    loaded(&harness);

    let queries = page_queries(&harness);
    assert_eq!(queries.len(), 1);
    assert!(queries[0].contains("ORDER BY \"users\".\"id\" DESC"), "{}", queries[0]);
    assert_eq!(harness.tab().current_sort(), Some((0, false)));
    let sorter = column_view(harness.tab())
        .sorter()
        .and_downcast::<gtk4::ColumnViewSorter>()
        .expect("sorter");
    assert_eq!(sorter.primary_sort_column(), harness.grid().data_view_column(0));
    assert_eq!(sorter.primary_sort_order(), gtk4::SortType::Descending);
}

#[gtk4::test]
fn kept_sorts_include_an_explicitly_unsorted_first_page() {
    for kept in [None, Some((1, true))] {
        let harness = Harness::open_with_sort(serving_rows(), InitialSort::Kept(kept), "primary-key", "descending");
        loaded(&harness);
        assert_eq!(harness.tab().current_sort(), kept);
        if kept.is_some() {
            assert!(page_queries(&harness)[0].contains("ORDER BY \"users\".\"name\" ASC"));
        } else {
            // Stable paging can add the key's ascending order without selecting a header sort.
            assert!(!page_queries(&harness)[0].contains("DESC"));
            let sorter = column_view(harness.tab())
                .sorter()
                .and_downcast::<gtk4::ColumnViewSorter>()
                .expect("sorter");
            assert!(sorter.primary_sort_column().is_none());
        }
    }
}

#[gtk4::test]
fn refresh_and_preference_changes_preserve_the_users_sort() {
    let harness = Harness::open_with_sort(serving_rows(), InitialSort::Default, "primary-key", "descending");
    loaded(&harness);
    harness.grid().sort_by(Some((1, true)));
    wait_until(WAIT, || {
        page_queries(&harness).len() == 2 && !harness.tab().is_loading()
    })
    .expect("manual sort");

    harness
        .stores
        .settings
        .get()
        .set_default_sort("first-column")
        .expect("preference");
    harness.tab().send(PagingInput::Refresh);
    wait_until(WAIT, || {
        page_queries(&harness).len() == 3 && !harness.tab().is_loading()
    })
    .expect("refresh");

    assert_eq!(harness.tab().current_sort(), Some((1, true)));
    assert!(page_queries(&harness)[2].contains("ORDER BY \"users\".\"name\" ASC"));
}

#[gtk4::test]
fn a_failed_metadata_read_keeps_the_default_for_its_retry() {
    let mut script = serving_rows();
    script.fetch_columns.once(FakeReply::err(DriverError::server("busy")));
    let harness = Harness::open_with_sort(script, InitialSort::Default, "primary-key", "descending");
    wait_until(WAIT, || harness.visible_page().as_deref() == Some("error")).expect("metadata failure");
    assert!(page_queries(&harness).is_empty());

    harness.tab().send(PagingInput::Refresh);
    loaded(&harness);

    assert_eq!(harness.tab().current_sort(), Some((0, false)));
    assert!(page_queries(&harness)[0].contains("ORDER BY \"users\".\"id\" DESC"));
}

#[gtk4::test]
fn explicitly_clearing_sort_before_metadata_cancels_the_default() {
    let mut script = serving_rows();
    script.fetch_columns.always(FakeReply::Late {
        after: Duration::from_millis(150),
        outcome: Ok(vec![column("id", true), column("name", false)]),
    });
    let harness = Harness::open_with_sort(script, InitialSort::Default, "primary-key", "descending");

    harness.tab().send(GridInput::Request(GridRequest::Sort(None)));
    loaded(&harness);

    assert_eq!(harness.tab().current_sort(), None);
    assert!(!page_queries(&harness)[0].contains("DESC"));
}

#[gtk4::test]
fn a_keyless_table_and_an_engine_without_sorting_skip_the_default() {
    let mut keyless = serving_rows();
    keyless
        .fetch_columns
        .always(FakeReply::ok(vec![column("id", false), column("name", false)]));
    keyless
        .row_identity
        .always(FakeReply::ok(tablepro_core::meta::RowIdentity::Unordered));
    let harness = Harness::open_with_sort(keyless, InitialSort::Default, "primary-key", "descending");
    loaded(&harness);
    assert_eq!(harness.tab().current_sort(), None);
    drop(harness);

    let mut unsupported = serving_rows();
    unsupported.dialect = Arc::new(tablepro_driver_cassandra::CqlDialect::new(
        &tablepro_core::ServerInfo::new("Cassandra", "5.0", 5, 0, 0),
    ));
    let harness = Harness::open_with_sort(unsupported, InitialSort::Default, "primary-key", "descending");
    wait_until(WAIT, || harness.grid().data_view_column(0).is_some()).expect("metadata");
    assert_eq!(harness.tab().current_sort(), None);
    assert!(harness.grid().data_view_column(0).expect("column").sorter().is_none());
}

#[gtk4::test]
fn stale_metadata_cannot_consume_the_pending_default() {
    use super::super::{BrowseCommand, BrowseRequestKind, ColumnsReply, DataInput};
    use crate::runtime::Stamped;
    use crate::ui::tab_load::LoadFailure;
    use tablepro_core::meta::RowIdentity;

    let mut script = serving_rows();
    script.fetch_columns.always(FakeReply::UntilStopped);
    let harness = Harness::open_with_sort(script, InitialSort::Default, "primary-key", "descending");
    let (stale, current) = {
        let mut borrowed = harness.tab().imp().model.borrow_mut();
        let model = borrowed.as_mut().expect("model");
        (
            model.sequencer.issue(BrowseRequestKind::Columns),
            model.sequencer.issue(BrowseRequestKind::Columns),
        )
    };
    let reply = || ColumnsReply {
        columns: vec![column("id", true), column("name", false)].into(),
        identity: RowIdentity::UniqueKey {
            columns: vec!["id".into()],
        },
    };
    harness
        .tab()
        .send(DataInput::Command(Box::new(BrowseCommand::Columns(Stamped {
            stamp: stale.stamp,
            value: Ok(reply()),
        }))));
    assert_eq!(harness.tab().current_sort(), None);
    assert!(
        harness
            .tab()
            .imp()
            .model
            .borrow()
            .as_ref()
            .expect("model")
            .default_sort
            .is_some()
    );
    harness
        .tab()
        .send(DataInput::Command(Box::new(BrowseCommand::Columns(Stamped {
            stamp: current.stamp,
            value: Err(LoadFailure::NoColumns),
        }))));
    assert!(
        harness
            .tab()
            .imp()
            .model
            .borrow()
            .as_ref()
            .expect("model")
            .default_sort
            .is_some()
    );
    let retry = harness
        .tab()
        .imp()
        .model
        .borrow_mut()
        .as_mut()
        .expect("model")
        .sequencer
        .issue(BrowseRequestKind::Columns);
    harness
        .tab()
        .send(DataInput::Command(Box::new(BrowseCommand::Columns(Stamped {
            stamp: retry.stamp,
            value: Ok(reply()),
        }))));
    assert_eq!(harness.tab().current_sort(), Some((0, false)));
    assert!(
        harness
            .tab()
            .imp()
            .model
            .borrow()
            .as_ref()
            .expect("model")
            .default_sort
            .is_none()
    );
}
