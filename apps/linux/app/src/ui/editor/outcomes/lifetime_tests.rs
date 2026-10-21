use super::super::stream_pages::{MAX_RETAINED_STREAM_PAGES, StreamPageCache};
use super::*;
use std::sync::Arc;
use tablepro_core::{ColumnInfo, QueryResult, Value};

fn page(index: u64) -> Arc<QueryResult> {
    Arc::new(QueryResult {
        columns: vec![ColumnInfo {
            name: "id".into(),
            data_type: "BIGINT".into(),
            nullable: false,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }],
        rows: (0..5_000)
            .map(|row| vec![Value::Int(index as i64 * 5_000 + row)])
            .collect(),
        truncated: false,
    })
}

fn clear(holder: &gtk::Box) {
    while let Some(child) = holder.first_child() {
        holder.remove(&child);
    }
}

fn append_live_page(
    holder: &gtk::Box,
    outcome: &StatementOutcome,
    target: &super::super::stream_view::LiveStreamTarget<'_>,
) {
    let StatementOutcomeKind::Streamed(result) = &outcome.kind else {
        panic!("expected a streamed outcome");
    };
    if holder.first_child().is_none() {
        holder.append(&build_outcome_widget(
            outcome,
            target.grid_sender,
            target.connection_id,
            target.database.clone(),
            target.settings_store.clone(),
        ));
        return;
    }
    assert!(super::super::stream_view::update_live_stream(
        holder, outcome, result, target
    ));
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn streamed_widgets_release_evicted_pages_and_cancelled_results_on_close() {
    gtk::init().unwrap();
    let mut cache = StreamPageCache::default();
    let mut pages = Vec::new();
    let holder = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let (sender, _receiver) = relm4::channel();
    let settings = LocalResultSettingsStore::default();
    let database = Arc::new(crate::services::database_service::DatabaseService::new_isolated());
    let make_outcome = |streamed| StatementOutcome {
        identity: StatementIdentity::default(),
        sql_preview: "SELECT id FROM items".into(),
        elapsed_ms: 0,
        kind: StatementOutcomeKind::Streamed(Box::new(streamed)),
        pinned: false,
    };
    for index in 0..12 {
        let result = page(index);
        pages.push(Arc::downgrade(&result));
        cache.append(index, result).unwrap();
        let outcome = make_outcome(cache.snapshot(StreamTerminal::Loading, None));
        append_live_page(
            &holder,
            &outcome,
            &super::super::stream_view::LiveStreamTarget {
                grid_sender: &sender,
                connection_id: None,
                database: database.clone(),
                settings_store: settings.clone(),
            },
        );
        drop(outcome);
        for retired in pages.iter().take(pages.len().saturating_sub(MAX_RETAINED_STREAM_PAGES)) {
            assert!(
                retired.upgrade().is_none(),
                "an evicted page remains in a retired result grid"
            );
        }
    }
    clear(&holder);
    let outcome = make_outcome(cache.snapshot(StreamTerminal::Cancelled, None));
    holder.append(&build_outcome_widget(&outcome, &sender, None, database, settings));
    drop(outcome);
    drop(cache);
    assert_eq!(
        pages.iter().filter(|page| page.upgrade().is_some()).count(),
        MAX_RETAINED_STREAM_PAGES
    );
    clear(&holder);
    drop(holder);
    assert!(
        pages.iter().all(|page| page.upgrade().is_none()),
        "closing cancelled results must release their pages"
    );
}
