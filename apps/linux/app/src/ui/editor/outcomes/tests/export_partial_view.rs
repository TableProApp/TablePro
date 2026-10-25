use super::*;

#[test]
#[ignore = "requires an isolated GTK display"]
fn exporting_after_partial_view_uses_the_guarded_query_and_its_bind_values() {
    relm4::adw::init().unwrap();
    let (_runtime, database, origin) = stream_export_origin();
    let page = std::sync::Arc::new(cursor_page(&[1, 2], true).result);
    let request = crate::ui::export_dialog::StreamExportRequest {
        query: crate::ui::export_dialog::StreamExportQuery {
            origin: origin.clone(),
            driver_id: "sqlite".into(),
            sql: "SELECT id FROM items WHERE id > ?".into(),
            params: vec![tablepro_core::Value::Int(0)],
            timeout_secs: 30,
            suggested_name: "items".into(),
            session: None,
        },
        columns: page.columns.clone(),
    };
    let streamed = StreamedResult {
        pages: vec![page.clone()],
        page_indices: vec![2],
        page_row_counts: vec![1, 1, page.rows.len(), 1],
        columns: page.columns.clone(),
        total_pages: 4,
        total_rows: tablepro_core::MAX_QUERY_CURSOR_PAGE_ROWS * 3 + 2,
        terminal: StreamTerminal::Loading,
        export: Some(request.clone()),
        generation: 0,
        spool: None,
    };
    let outcome = super::super::StatementOutcome {
        identity: StatementIdentity {
            statement_index: 0,
            digest: [7; 32],
        },
        sql_preview: "SELECT id FROM items".into(),
        elapsed_ms: 0,
        kind: StatementOutcomeKind::Streamed(Box::new(streamed.clone())),
        pinned: false,
    };
    let (grid_sender, receiver) = relm4::channel::<crate::ui::grid::GridMsg>();
    let widget = super::super::build_streamed_result_widget(
        &outcome,
        &streamed,
        &grid_sender,
        Some(origin.id),
        database,
        Default::default(),
        None,
    );

    let button = stream_export_button(&widget).unwrap();
    button.emit_clicked();
    let Some(crate::ui::grid::GridMsg::ExportStreamedResults(export)) = receiver.recv_sync() else {
        panic!("the export action must carry a full query export request");
    };

    assert_eq!(export.query.origin, origin);
    assert_eq!(export.query.sql, "SELECT id FROM items WHERE id > ?");
    assert_eq!(export.query.params, [tablepro_core::Value::Int(0)]);
    assert_eq!(export.query.suggested_name, "items");
    assert_eq!(export.columns[0].name, "id");
    assert_eq!(streamed.pages.len(), 1);
    assert!(streamed.total_rows > streamed.pages[0].rows.len());
}
