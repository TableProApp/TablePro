use super::*;
use std::sync::Arc;

use tablepro_core::{ColumnInfo, QueryResult, Value};

fn rows(sql: &str) -> StatementOutcome {
    StatementOutcome {
        identity: super::super::StatementIdentity::default(),
        sql_preview: sql.into(),
        elapsed_ms: 1,
        kind: StatementOutcomeKind::Rows(Vec::new()),
        pinned: false,
    }
}

fn failed(sql: &str) -> StatementOutcome {
    StatementOutcome {
        kind: StatementOutcomeKind::Error("boom".into()),
        ..rows(sql)
    }
}

fn streamed(sql: &str, values: &[i64], terminal: super::super::stream_pages::StreamTerminal) -> StatementOutcome {
    let mut cache = super::super::stream_pages::StreamPageCache::default();
    let page = page(values);
    assert!(cache.append(0, page).is_ok());
    let result = cache.snapshot(terminal, None);
    StatementOutcome {
        kind: StatementOutcomeKind::Streamed(Box::new(result)),
        ..rows(sql)
    }
}

fn page(values: &[i64]) -> Arc<QueryResult> {
    Arc::new(QueryResult {
        columns: vec![ColumnInfo {
            name: "id".into(),
            data_type: "INTEGER".into(),
            nullable: false,
            primary_key: true,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }],
        rows: values.iter().map(|value| vec![Value::Int(*value)]).collect(),
        truncated: false,
    })
}

#[test]
fn nothing_is_pinned_until_asked() {
    let mut pins = PinnedResults::default();
    let shown = pins.show(vec![rows("SELECT 1")]);
    assert_eq!(shown.len(), 1);
    assert!(!pins.is_pinned());
    assert!(pins.has_results());
}

#[test]
fn pinned_results_stay_ahead_of_the_next_run() {
    let mut pins = PinnedResults::default();
    pins.show(vec![rows("SELECT 1"), failed("SELECT x")]);
    assert_eq!(pins.pin_last(), 1);

    let shown = pins.show(vec![rows("SELECT 2")]);

    assert_eq!(shown.len(), 2);
    assert!(shown[0].pinned);
    assert_eq!(shown[0].sql_preview, "SELECT 1");
    assert!(!shown[1].pinned);
}

#[test]
#[ignore = "app-server isolated regression"]
fn an_evicted_stream_page_stays_alive_while_pinned_and_releases_after_unpin() {
    let mut cache = super::super::stream_pages::StreamPageCache::default();
    let first_page = page(&[1]);
    let first_page_weak = Arc::downgrade(&first_page);
    assert!(cache.append(0, first_page.clone()).is_ok());
    drop(first_page);

    let first_result = cache.snapshot(super::super::stream_pages::StreamTerminal::Complete, None);
    let mut wide_page = page(&[]).as_ref().clone();
    wide_page.rows = vec![vec![Value::Text("x".repeat(65 * 1024 * 1024))]];
    assert!(cache.append(1, Arc::new(wide_page)).is_ok());
    assert_eq!(cache.first_page(), 1);
    assert!(first_page_weak.upgrade().is_some());

    let first_outcome = StatementOutcome {
        kind: StatementOutcomeKind::Streamed(Box::new(first_result)),
        ..rows("SELECT 1")
    };
    let mut pins = PinnedResults::default();
    let first_render = pins.show(vec![first_outcome]);
    assert_eq!(pins.pin_last(), 1);
    drop(first_render);

    let next_render = pins.show(vec![streamed(
        "SELECT 2",
        &[2],
        super::super::stream_pages::StreamTerminal::Complete,
    )]);
    assert!(first_page_weak.upgrade().is_some());
    drop(next_render);

    drop(pins.unpin_all());

    assert!(first_page_weak.upgrade().is_none());
}

#[test]
fn pinning_keeps_the_statement_identity_used_by_local_result_settings() {
    let identity = super::super::StatementIdentity {
        statement_index: 2,
        digest: [9; 32],
    };
    let mut outcome = rows("SELECT 1");
    outcome.identity = identity;
    let mut pins = PinnedResults::default();
    pins.show(vec![outcome]);

    assert_eq!(pins.pin_last(), 1);
    assert_eq!(pins.pins[0].identity, identity);
}

#[test]
fn failed_statements_are_not_pinned() {
    let mut pins = PinnedResults::default();
    pins.show(vec![failed("SELECT x")]);
    assert!(!pins.has_results());
    assert_eq!(pins.pin_last(), 0);
}

#[test]
fn an_empty_streamed_result_can_be_pinned_without_losing_its_metadata() {
    let mut pins = PinnedResults::default();
    pins.show(vec![streamed(
        "SELECT id FROM empty_table",
        &[],
        super::super::stream_pages::StreamTerminal::Complete,
    )]);

    assert!(pins.has_results());
    assert_eq!(pins.pin_last(), 1);

    let shown = pins.show(vec![rows("SELECT 2")]);
    assert_eq!(shown.len(), 2);
    let pinned = &shown[0];
    assert!(pinned.pinned);
    let StatementOutcomeKind::Streamed(result) = &pinned.kind else {
        panic!("streamed result should remain streamed when pinned");
    };
    assert_eq!(result.total_rows, 0);
    assert_eq!(result.pages.len(), 1);
    assert_eq!(result.pages[0].columns[0].name, "id");
    assert_eq!(shown[1].sql_preview, "SELECT 2");
}

#[test]
fn a_stream_with_prior_pages_remains_pinnable_after_a_later_fetch_failure() {
    let mut pins = PinnedResults::default();
    pins.show(vec![streamed(
        "SELECT id FROM items",
        &[7],
        super::super::stream_pages::StreamTerminal::Failed("fetch failed".into()),
    )]);

    assert!(pins.has_results());
    assert_eq!(pins.pin_last(), 1);
    let StatementOutcomeKind::Streamed(result) = &pins.pins[0].kind else {
        panic!("streamed result should remain streamed when pinned");
    };
    assert!(matches!(
        result.terminal,
        super::super::stream_pages::StreamTerminal::Failed(_)
    ));
    assert_eq!(result.pages[0].rows[0][0], Value::Int(7));
}

#[test]
fn the_oldest_pins_are_dropped_past_the_limit() {
    let mut pins = PinnedResults::default();
    for index in 0..=MAX_PINNED {
        pins.show(vec![rows(&format!("SELECT {index}"))]);
        pins.pin_last();
    }
    assert_eq!(pins.count(), MAX_PINNED);
    let shown = pins.show(Vec::new());
    assert_eq!(shown[0].sql_preview, "SELECT 1");
}

#[test]
#[ignore = "app-server isolated regression"]
fn evicting_old_stream_pins_releases_their_pages_and_unpin_releases_the_rest() {
    let mut pins = PinnedResults::default();
    let mut pages = Vec::new();
    for index in 0..=MAX_PINNED {
        let result = page(&[index as i64]);
        pages.push(Arc::downgrade(&result));
        let mut cache = super::super::stream_pages::StreamPageCache::default();
        cache.append(0, result).expect("append streamed page");
        let outcome = StatementOutcome {
            kind: StatementOutcomeKind::Streamed(Box::new(
                cache.snapshot(super::super::stream_pages::StreamTerminal::Complete, None),
            )),
            ..rows(&format!("SELECT {index}"))
        };

        pins.show(vec![outcome]);
        pins.pin_last();
    }

    assert!(pages[0].upgrade().is_none());
    assert!(pages[1..].iter().all(|page| page.upgrade().is_some()));

    let latest = pins.unpin_all();

    assert!(pages[..MAX_PINNED].iter().all(|page| page.upgrade().is_none()));
    assert!(pages[MAX_PINNED].upgrade().is_some());
    drop(latest);
    assert!(pages[MAX_PINNED].upgrade().is_some());

    pins.show(vec![rows("SELECT after")]);

    assert!(pages.iter().all(|page| page.upgrade().is_none()));
}

#[test]
fn unpinning_returns_the_latest_run_alone() {
    let mut pins = PinnedResults::default();
    pins.show(vec![rows("SELECT 1")]);
    pins.pin_last();
    pins.show(vec![rows("SELECT 2")]);

    let remaining = pins.unpin_all();

    assert!(!pins.is_pinned());
    assert_eq!(remaining.len(), 1);
    assert_eq!(remaining[0].sql_preview, "SELECT 2");
}

#[test]
fn a_stream_still_loading_is_not_pinned() {
    let mut pins = PinnedResults::default();
    pins.show(vec![streamed(
        "SELECT id FROM items",
        &[1],
        super::super::stream_pages::StreamTerminal::Loading,
    )]);

    assert!(!pins.has_results());
    assert_eq!(pins.pin_last(), 0);
}
