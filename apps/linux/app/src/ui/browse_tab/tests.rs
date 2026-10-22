use super::grid_render::column_layout_matches;
use super::paste::parse_clipboard_grid;
use super::value_parse::{parse_grid_cell_input, parse_pasted_cell};
use super::{
    BrowsePageRequest, BrowseTab, BrowseTabInit, BrowseTabInput, BrowseTabOutput, PageRequestTracker,
    RowCountRequestTracker, columns_for_browse_page, next_page_offset, previous_page_offset,
    projection_for_loaded_page,
};
use relm4::{Component, ComponentController};

fn browse_page(rows: usize, truncated: bool) -> QueryResult {
    QueryResult {
        columns: Vec::new(),
        rows: vec![vec![Value::Int(1)]; rows],
        truncated,
    }
}

#[test]
fn browse_next_page_uses_known_total_and_page_size_fallback() {
    let full = browse_page(2, false);
    let short = browse_page(1, false);
    assert_eq!(next_page_offset(0, 2, Some(2), Some(&full)), None);
    assert_eq!(next_page_offset(0, 2, Some(3), Some(&full)), Some(2));
    assert_eq!(next_page_offset(2, 2, Some(4), Some(&full)), None);
    assert_eq!(next_page_offset(2, 2, Some(5), Some(&full)), Some(4));
    assert_eq!(next_page_offset(0, 2, None, Some(&full)), Some(2));
    assert_eq!(next_page_offset(0, 2, None, Some(&short)), None);
}

#[test]
fn next_page_after_a_truncated_page_continues_from_the_first_row_not_shown() {
    let truncated = browse_page(37, true);
    assert_eq!(next_page_offset(0, 100, Some(5_000), Some(&truncated)), Some(37));
    assert_eq!(
        next_page_offset(10_037, 100, Some(50_000), Some(&truncated)),
        Some(10_074)
    );
    assert_eq!(next_page_offset(4_963, 100, Some(5_000), Some(&truncated)), None);
}

#[test]
fn a_truncated_page_has_a_next_page_when_the_total_is_unknown() {
    assert_eq!(next_page_offset(0, 100, None, Some(&browse_page(37, true))), Some(37));
}

#[test]
fn a_truncated_page_without_rows_skips_only_the_row_larger_than_the_budget() {
    let empty = browse_page(0, true);
    assert_eq!(next_page_offset(200, 100, None, Some(&empty)), Some(201));
    assert_eq!(next_page_offset(200, 100, Some(5_000), Some(&empty)), Some(201));
    assert_eq!(next_page_offset(4_999, 100, Some(5_000), Some(&empty)), None);
}

#[test]
fn previous_page_after_a_truncated_advance_stops_at_the_first_row() {
    assert_eq!(previous_page_offset(37, 100), Some(0));
    assert_eq!(previous_page_offset(137, 100), Some(37));
    assert_eq!(previous_page_offset(200, 100), Some(100));
    assert_eq!(previous_page_offset(0, 100), None);
}
use tablepro_core::{ColumnInfo, QueryResult, Value};
use uuid::Uuid;

fn column(name: &str, data_type: &str, primary_key: bool) -> ColumnInfo {
    ColumnInfo {
        name: name.into(),
        data_type: data_type.into(),
        nullable: !primary_key,
        primary_key,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: None,
        domain_type: None,
    }
}

#[test]
fn empty_input_is_an_empty_string_only_for_required_text_columns() {
    let mut required = column("name", "character varying(20)", false);
    required.nullable = false;
    assert_eq!(
        parse_grid_cell_input("", Some(&required), "postgres", None),
        Ok(Value::Text(String::new()))
    );
    let nullable = column("name", "character varying(20)", false);
    assert_eq!(
        parse_grid_cell_input("", Some(&nullable), "postgres", None),
        Ok(Value::Null)
    );
    let mut required_int = column("n", "integer", false);
    required_int.nullable = false;
    assert!(parse_grid_cell_input("", Some(&required_int), "postgres", None).is_err());
}

fn assert_cell_read_only(column: &ColumnInfo, value: &Value) {
    assert!(!crate::ui::grid::cell_allows_inline_edit(column, value));
}

#[test]
fn only_the_latest_browse_page_request_is_accepted() {
    let tracker = PageRequestTracker::default();
    let older = tracker.begin(0);
    let newer = tracker.begin(0);

    assert!(!tracker.accepts(older, 0));
    assert!(tracker.accepts(newer, 0));
}

#[test]
fn an_empty_page_uses_full_schema_headers_without_a_sparse_row_map() {
    let result = QueryResult {
        columns: Vec::new(),
        rows: Vec::new(),
        truncated: false,
    };
    assert_eq!(projection_for_loaded_page(&result, Some(vec![0, 2])), None);
}

#[test]
#[ignore = "requires isolated GTK display"]
fn browse_page_fetch_waits_until_the_new_columns_are_applied() {
    relm4::gtk::init().unwrap();
    let (output_sender, output_receiver) = relm4::channel::<BrowseTabOutput>();
    let (observed_sender, observed_receiver) = std::sync::mpsc::channel();
    relm4::spawn_local(async move {
        while let Some(output) = output_receiver.recv().await {
            if observed_sender.send(output).is_err() {
                break;
            }
        }
    });
    let mut controller = BrowseTab::builder()
        .launch(BrowseTabInit {
            tab_id: Uuid::new_v4(),
            schema: Some("public".into()),
            table: "customers".into(),
            driver_id: "postgres".into(),
            connection_id: None,
            read_only: false,
            page_size: 100,
            initial_offset: 0,
            initial_sort: None,
            persistence: crate::services::persistence_stores::PersistenceStores {
                column_widths: None,
                filter_settings: None,
                csv_import_mappings: None,
                named_filter_presets: None,
            },
            database: std::sync::Arc::new(crate::services::database_service::DatabaseService::new_isolated()),
        })
        .forward(&output_sender, |output| output);
    let context = relm4::gtk::glib::MainContext::default();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);

    controller
        .sender()
        .send(BrowseTabInput::ColumnsLoaded(vec![column("email", "text", false)]))
        .unwrap();

    let mut fetched_page = false;
    let mut fetched_count = false;
    while std::time::Instant::now() < deadline && !(fetched_page && fetched_count) {
        while let Ok(output) = observed_receiver.try_recv() {
            match output {
                BrowseTabOutput::FetchPage => fetched_page = true,
                BrowseTabOutput::FetchRowCount => fetched_count = true,
                _ => {}
            }
        }
        context.iteration(false);
        std::thread::sleep(std::time::Duration::from_millis(1));
    }

    assert!(fetched_page);
    assert!(fetched_count);
    assert_eq!(controller.model().columns()[0].name, "email");
    controller.detach_runtime();
}

fn spin_until(context: &relm4::gtk::glib::MainContext, mut condition: impl FnMut() -> bool) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
    while !condition() && std::time::Instant::now() < deadline {
        context.iteration(false);
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    assert!(condition());
}

fn spin_for(context: &relm4::gtk::glib::MainContext, duration: std::time::Duration) {
    let deadline = std::time::Instant::now() + duration;
    while std::time::Instant::now() < deadline {
        context.iteration(false);
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
}

#[test]
#[ignore = "requires isolated GTK display"]
fn deep_previous_page_uses_the_first_row_as_its_reverse_keyset_anchor() {
    relm4::gtk::init().unwrap();
    let (output_sender, output_receiver) = relm4::channel::<BrowseTabOutput>();
    relm4::spawn_local(async move { while output_receiver.recv().await.is_some() {} });
    let mut controller = BrowseTab::builder()
        .launch(BrowseTabInit {
            tab_id: Uuid::new_v4(),
            schema: Some("public".into()),
            table: "items".into(),
            driver_id: "postgres".into(),
            connection_id: None,
            read_only: false,
            page_size: 100,
            initial_offset: 20_000,
            initial_sort: None,
            persistence: crate::services::persistence_stores::PersistenceStores {
                column_widths: None,
                filter_settings: None,
                csv_import_mappings: None,
                named_filter_presets: None,
            },
            database: std::sync::Arc::new(crate::services::database_service::DatabaseService::new_isolated()),
        })
        .forward(&output_sender, |output| output);
    let context = relm4::gtk::glib::MainContext::default();
    controller
        .sender()
        .send(BrowseTabInput::ColumnsLoaded(vec![column("id", "integer", true)]))
        .unwrap();
    spin_until(&context, || controller.model().current_columns.len() == 1);
    let request = controller.model().page_requests.begin(20_000);
    controller
        .sender()
        .send(BrowseTabInput::RowsLoaded {
            request,
            result: QueryResult {
                columns: Vec::new(),
                rows: vec![vec![Value::Int(20_001)], vec![Value::Int(21_000)]],
                truncated: false,
            },
            projected_columns: None,
        })
        .unwrap();
    spin_until(&context, || controller.model().current_result.is_some());

    controller.sender().send(BrowseTabInput::PrevPage).unwrap();
    spin_until(&context, || controller.model().current_offset == 19_900);

    assert!(controller.model().reverse_page());
    assert_eq!(
        controller.model().keyset_before_cursor(),
        Some(&[Value::Int(20_001)][..])
    );
    assert_deep_last_page_selection(&mut controller, &context);
    controller.detach_runtime();
}

fn assert_deep_last_page_selection<T: ComponentController<BrowseTab>>(
    controller: &mut T,
    context: &relm4::gtk::glib::MainContext,
) {
    let count_request = controller.model().row_count_requests.begin();
    controller
        .sender()
        .send(BrowseTabInput::RowCountLoaded {
            request: count_request,
            count: 30_000,
        })
        .unwrap();
    spin_until(context, || controller.model().current_total_rows == Some(30_000));
    controller.sender().send(BrowseTabInput::LastPage).unwrap();
    spin_until(context, || controller.model().last_page());
    assert_eq!(controller.model().current_offset, 29_900);
}

#[test]
#[ignore = "requires isolated GTK display"]
fn browse_next_page_is_disabled_when_known_total_matches_page_end() {
    use relm4::gtk::prelude::WidgetExt;
    relm4::gtk::init().unwrap();
    let (output_sender, output_receiver) = relm4::channel::<BrowseTabOutput>();
    relm4::spawn_local(async move { while output_receiver.recv().await.is_some() {} });
    let mut controller = BrowseTab::builder()
        .launch(BrowseTabInit {
            tab_id: Uuid::new_v4(),
            schema: Some("main".into()),
            table: "items".into(),
            driver_id: "sqlite".into(),
            connection_id: None,
            read_only: false,
            page_size: 2,
            initial_offset: 0,
            initial_sort: None,
            persistence: crate::services::persistence_stores::PersistenceStores {
                column_widths: None,
                filter_settings: None,
                csv_import_mappings: None,
                named_filter_presets: None,
            },
            database: std::sync::Arc::new(crate::services::database_service::DatabaseService::new_isolated()),
        })
        .forward(&output_sender, |output| output);
    let context = relm4::gtk::glib::MainContext::default();
    controller
        .sender()
        .send(BrowseTabInput::ColumnsLoaded(vec![column("id", "integer", true)]))
        .unwrap();
    spin_until(&context, || controller.model().current_columns.len() == 1);
    let page_request = controller.model().page_requests.begin(0);
    let count_request = controller.model().row_count_requests.begin();
    controller
        .sender()
        .send(BrowseTabInput::RowsLoaded {
            request: page_request,
            result: QueryResult {
                columns: Vec::new(),
                rows: vec![vec![Value::Int(1)], vec![Value::Int(2)]],
                truncated: false,
            },
            projected_columns: None,
        })
        .unwrap();
    spin_until(&context, || controller.model().current_result.is_some());
    controller
        .sender()
        .send(BrowseTabInput::RowCountLoaded {
            request: count_request,
            count: 2,
        })
        .unwrap();
    spin_until(&context, || controller.model().current_total_rows == Some(2));
    assert!(!controller.model().next_button.is_sensitive());
    controller.sender().send(BrowseTabInput::NextPage).unwrap();
    spin_for(&context, std::time::Duration::from_millis(10));
    assert_eq!(controller.model().current_offset, 0);
    controller.detach_runtime();
}

#[test]
fn sqlite_grid_parses_unknown_numeric_affinity_values_without_losing_precision() {
    let enum_column = column("value", "ENUM", false);
    assert_eq!(
        parse_grid_cell_input("queued", Some(&enum_column), "sqlite", None),
        Ok(Value::Text("queued".into()))
    );
    assert_eq!(
        parse_grid_cell_input("3.5", Some(&enum_column), "sqlite", None),
        Ok(Value::Decimal(rust_decimal::Decimal::new(35, 1)))
    );
    for unsafe_number in ["1e999", "1e-400", "0.123456789012345678901234567890123"] {
        assert!(
            parse_grid_cell_input(unsafe_number, Some(&enum_column), "sqlite", None).is_err(),
            "unsafe SQLite NUMERIC-affinity input must be refused: {unsafe_number}"
        );
    }
    assert_eq!(
        parse_grid_cell_input("3.5", Some(&enum_column), "postgres", None),
        Ok(Value::Text("3.5".into()))
    );
}

#[test]
fn pasted_null_and_empty_text_stay_distinct() {
    let nullable_text = column("value", "text", false);
    let required_text = column("value", "text", true);
    let count = column("count", "integer", false);
    assert_eq!(
        parse_pasted_cell(None, Some(&nullable_text), "postgres", None),
        Ok(Value::Null)
    );
    assert_eq!(
        parse_pasted_cell(Some(""), Some(&nullable_text), "postgres", None),
        Ok(Value::Text(String::new()))
    );
    assert!(parse_pasted_cell(None, Some(&required_text), "postgres", None).is_err());
    assert_eq!(
        parse_pasted_cell(Some(""), Some(&count), "postgres", None),
        Ok(Value::Null)
    );
    let required_count = column("count", "integer", true);
    assert!(parse_pasted_cell(Some(""), Some(&required_count), "postgres", None).is_err());
    assert_eq!(
        parse_pasted_cell(Some("7"), Some(&count), "postgres", None),
        Ok(Value::Int(7))
    );
}

#[test]
fn grid_text_input_preserves_lf_and_crlf() {
    let text_column = column("value", "text", false);
    for clipboard in ["\"line1\nline2\"", "\"line1\r\nline2\""] {
        let value = parse_clipboard_grid(clipboard)[0][0].clone().unwrap();
        assert_eq!(
            parse_grid_cell_input(&value, Some(&text_column), "postgres", None),
            Ok(Value::Text(value.clone()))
        );
    }
    assert!(parse_grid_cell_input("1\n2", Some(&column("count", "integer", false)), "postgres", None).is_err());
}

#[tokio::test]
async fn grid_text_paste_stores_line_breaks_and_leaves_sibling_rows_unchanged() {
    use tablepro_core::{ConnectOptions, DatabaseDriver, OperationControl};

    let connection = drivers_sqlite::SqliteDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(5));
    connection
        .execute_controlled(
            "CREATE TABLE grid_text_paste (id INTEGER PRIMARY KEY, value TEXT NOT NULL)",
            &control,
        )
        .await
        .unwrap();
    connection
        .execute_controlled(
            "INSERT INTO grid_text_paste VALUES (1, 'before'), (2, 'sibling'), (3, 'before')",
            &control,
        )
        .await
        .unwrap();
    let columns = connection
        .fetch_columns_controlled(None, "grid_text_paste", &control)
        .await
        .unwrap();
    let value_index = columns.iter().position(|column| column.name == "value").unwrap();
    let pasted = parse_clipboard_grid("\"line1\nline2\"\n\"line3\r\nline4\"");
    for (index, id) in [1, 3].into_iter().enumerate() {
        let value = parse_grid_cell_input(
            pasted[index][0].as_deref().unwrap(),
            Some(&columns[value_index]),
            "sqlite",
            None,
        )
        .unwrap();
        let update = tablepro_core::sql_dialect::build_keyed_update(
            "sqlite",
            None,
            "grid_text_paste",
            &columns,
            &[(value_index, value)],
            &[Value::Int(id)],
        )
        .unwrap();
        connection
            .execute_in_transaction_controlled(&[update], &control)
            .await
            .unwrap();
    }
    let result = connection
        .query_controlled("SELECT id, value FROM grid_text_paste ORDER BY id", &control)
        .await
        .unwrap();
    assert_eq!(result.rows[0][value_index], Value::Text("line1\nline2".into()));
    assert_eq!(result.rows[1][value_index], Value::Text("sibling".into()));
    assert_eq!(result.rows[2][value_index], Value::Text("line3\r\nline4".into()));
    assert!(parse_grid_cell_input("1\n2", Some(&column("count", "integer", false)), "postgres", None).is_err());
}

#[test]
fn only_the_latest_row_count_request_is_accepted() {
    let tracker = RowCountRequestTracker::default();
    let older = tracker.begin();
    let newer = tracker.begin();

    assert!(!tracker.accepts(older));
    assert!(tracker.accepts(newer));
}

#[test]
fn browse_page_response_must_match_the_current_offset() {
    let tracker = PageRequestTracker::default();
    let request = tracker.begin(100);
    let same_id_wrong_offset = BrowsePageRequest {
        id: request.id,
        offset: 100,
    };

    assert!(!tracker.accepts(same_id_wrong_offset, 200));
    assert_ne!(request.id, Uuid::nil());
}

#[test]
fn mongodb_page_schema_updates_late_fields_and_mixed_types_before_grid_editing() {
    let loaded = vec![column("_id", "ObjectId", true), column("value", "string", false)];
    let page_columns = vec![
        column("_id", "ObjectId", true),
        column("value", "mixed", false),
        column("late_field", "Decimal128", false),
    ];
    let page = QueryResult {
        columns: page_columns.clone(),
        rows: vec![vec![
            Value::Uuid(Uuid::new_v4()),
            Value::Json(serde_json::json!({"$numberDecimal": "1.25"})),
            Value::Text("late".into()),
        ]],
        truncated: false,
    };

    let effective = columns_for_browse_page("mongodb", &loaded, Some(&page));
    assert_eq!(effective, page_columns);
    assert_eq!(effective[1].data_type, "mixed");
    assert_eq!(effective[2].name, "late_field");
    assert!(
        !column_layout_matches(&loaded, &effective),
        "new page metadata must rebuild cached factories and editability"
    );
    let text_value = Value::Text("ordinary text on the mixed page".into());
    assert!(crate::ui::grid::cell_allows_inline_edit(&loaded[1], &text_value));
    assert!(
        !crate::ui::grid::cell_allows_inline_edit(&effective[1], &text_value),
        "page-discovered mixed BSON types must make the same text cell read-only"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mongodb_collection_wide_mixed_metadata_refuses_edit() {
    use tablepro_core::OperationControl;

    let (_container, connection, collection, decimal) = mongodb_late_mixed_page_fixture().await;
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    let loaded_columns = connection
        .fetch_columns_controlled(None, "page_mixed_edit_contract", &control)
        .await
        .unwrap();
    let loaded_value_index = loaded_columns.iter().position(|column| column.name == "value").unwrap();
    assert_eq!(loaded_columns[loaded_value_index].data_type, "mixed");

    let page = connection
        .fetch_rows_controlled(None, "page_mixed_edit_contract", 0, 1, &control)
        .await
        .unwrap();
    let effective_columns = columns_for_browse_page("mongodb", &loaded_columns, Some(&page));
    let value_index = effective_columns
        .iter()
        .position(|column| column.name == "value")
        .unwrap();
    let id_index = effective_columns
        .iter()
        .position(|column| column.name == "_id")
        .unwrap();
    assert_eq!(page.rows.len(), 1);
    assert_eq!(page.rows[0][id_index], Value::Int(0));
    assert_eq!(effective_columns[value_index].data_type, "mixed");
    assert!(column_layout_matches(&loaded_columns, &effective_columns));
    assert_cell_read_only(&effective_columns[value_index], &page.rows[0][value_index]);

    let later_page = connection
        .fetch_rows_controlled(None, "page_mixed_edit_contract", 50, 1, &control)
        .await
        .unwrap();
    let later_columns = columns_for_browse_page("mongodb", &loaded_columns, Some(&later_page));
    let later_value_index = later_columns.iter().position(|column| column.name == "value").unwrap();
    let later_id_index = later_columns.iter().position(|column| column.name == "_id").unwrap();
    assert_eq!(later_page.rows[0][later_id_index], Value::Int(50));
    assert_eq!(
        later_page.rows[0][later_value_index],
        Value::Json(serde_json::json!({"$numberDecimal": decimal.to_string()}))
    );
    assert_eq!(later_columns[later_value_index].data_type, "mixed");
    assert!(column_layout_matches(&loaded_columns, &later_columns));
    assert_cell_read_only(
        &later_columns[later_value_index],
        &later_page.rows[0][later_value_index],
    );

    let persisted = collection
        .find_one(mongodb::bson::doc! { "_id": 50 })
        .await
        .unwrap()
        .unwrap();
    assert_eq!(persisted.get("_id"), Some(&mongodb::bson::Bson::Int32(50)));
    assert_eq!(persisted.get("value"), Some(&mongodb::bson::Bson::Decimal128(decimal)));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mongodb_off_page_type_change_during_census_refuses_edit() {
    use mongodb::bson::{Decimal128, doc};
    use tablepro_core::OperationControl;

    let (_container, native, collection, connection) = mongodb_census_race_fixture().await;

    native
        .database("admin")
        .run_command(doc! {
            "configureFailPoint": "failCommand",
            "mode": { "times": 1 },
            "data": {
                "failCommands": ["getMore"],
                "blockConnection": true,
                "blockTimeMS": 3_000
            }
        })
        .await
        .unwrap();
    let page_connection = connection.clone();
    let page_task = tokio::spawn(async move {
        let control = OperationControl::with_timeout(std::time::Duration::from_secs(10));
        page_connection
            .fetch_rows_controlled(None, "page_census_race", 0, 2, &control)
            .await
    });

    assert!(wait_for_mongodb_command(&native, "getMore").await);

    let decimal: Decimal128 = "12345678901234567890.1234567890123".parse().unwrap();
    collection
        .update_one(doc! { "_id": 127 }, doc! { "$set": { "value": decimal } })
        .await
        .unwrap();
    native
        .database("admin")
        .run_command(doc! { "configureFailPoint": "failCommand", "mode": "off" })
        .await
        .unwrap();
    let page = tokio::time::timeout(std::time::Duration::from_secs(6), page_task)
        .await
        .unwrap()
        .unwrap()
        .unwrap();

    assert_mongodb_census_race_page(&page);

    let changed = collection.find_one(doc! { "_id": 127 }).await.unwrap().unwrap();
    let sibling = collection.find_one(doc! { "_id": 1 }).await.unwrap().unwrap();
    assert_eq!(changed.get("value"), Some(&mongodb::bson::Bson::Decimal128(decimal)));
    assert_eq!(
        sibling.get("value"),
        Some(&mongodb::bson::Bson::String("sibling".into()))
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mongodb_census_is_not_a_snapshot_for_already_read_documents() {
    use mongodb::bson::{Decimal128, doc};
    use tablepro_core::OperationControl;

    let (_container, native, collection, connection) = mongodb_census_race_fixture().await;

    native
        .database("admin")
        .run_command(doc! {
            "configureFailPoint": "failCommand",
            "mode": { "times": 1 },
            "data": {
                "failCommands": ["getMore"],
                "blockConnection": true,
                "blockTimeMS": 3_000
            }
        })
        .await
        .unwrap();
    let page_connection = connection.clone();
    let page_task = tokio::spawn(async move {
        let control = OperationControl::with_timeout(std::time::Duration::from_secs(10));
        page_connection
            .fetch_rows_controlled(None, "page_census_race", 0, 2, &control)
            .await
    });

    assert!(wait_for_mongodb_command(&native, "getMore").await);
    let decimal: Decimal128 = "12345678901234567890.1234567890123".parse().unwrap();
    collection
        .update_one(doc! { "_id": 0 }, doc! { "$set": { "value": decimal } })
        .await
        .unwrap();
    native
        .database("admin")
        .run_command(doc! { "configureFailPoint": "failCommand", "mode": "off" })
        .await
        .unwrap();
    let page = tokio::time::timeout(std::time::Duration::from_secs(6), page_task)
        .await
        .unwrap()
        .unwrap()
        .unwrap();

    let value_index = page.columns.iter().position(|column| column.name == "value").unwrap();
    let id_index = page.columns.iter().position(|column| column.name == "_id").unwrap();
    let first_row = page.rows.iter().find(|row| row[id_index] == Value::Int(0)).unwrap();
    assert_eq!(page.columns[value_index].data_type, "string");
    assert_eq!(first_row[value_index], Value::Text("before".into()));
    let persisted = collection.find_one(doc! { "_id": 0 }).await.unwrap().unwrap();
    assert_eq!(persisted.get("value"), Some(&mongodb::bson::Bson::Decimal128(decimal)));
    // MongoDB does not give this collection scan snapshot semantics. The
    // cursor returns the value it read before the concurrent update.
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mongodb_browse_uses_a_bounded_sample_and_page_find() {
    use tablepro_core::OperationControl;

    let (_container, native, _collection, connection) = mongodb_census_race_fixture().await;
    let before = mongodb_find_command_count(&native).await;
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(10));
    let page = connection
        .fetch_rows_controlled(None, "page_census_race", 0, 1, &control)
        .await
        .unwrap();
    let after = mongodb_find_command_count(&native).await;
    assert_eq!(after - before, 2, "bounded schema sample and page use separate finds");
    let value_index = page.columns.iter().position(|column| column.name == "value").unwrap();
    assert_eq!(page.columns[value_index].data_type, "string");
    assert_eq!(page.rows[0][value_index], Value::Text("before".into()));
}

async fn mongodb_find_command_count(native: &mongodb::Client) -> i64 {
    native
        .database("admin")
        .run_command(mongodb::bson::doc! { "serverStatus": 1 })
        .await
        .unwrap()
        .get_document("metrics")
        .unwrap()
        .get_document("commands")
        .unwrap()
        .get_document("find")
        .unwrap()
        .get_i64("total")
        .unwrap()
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mongodb_run_find_merges_page_types_and_exports_materialized_values() {
    use mongodb::bson::{Decimal128, doc};
    use tablepro_core::OperationControl;

    let (_container, native, collection, connection) = mongodb_census_race_fixture().await;
    native
        .database("admin")
        .run_command(doc! {
            "configureFailPoint": "failCommand",
            "mode": { "skip": 1 },
            "data": {
                "failCommands": ["find"],
                "blockConnection": true,
                "blockTimeMS": 3_000
            }
        })
        .await
        .unwrap();
    let page_connection = connection.clone();
    let query_task = tokio::spawn(async move {
        let control = OperationControl::with_timeout(std::time::Duration::from_secs(10));
        page_connection
            .query_controlled("db.page_census_race.find({\"_id\":0})", &control)
            .await
    });

    assert!(wait_for_mongodb_command(&native, "find").await);
    let decimal: Decimal128 = "12345678901234567890.1234567890123".parse().unwrap();
    collection
        .update_one(doc! { "_id": 0 }, doc! { "$set": { "value": decimal } })
        .await
        .unwrap();
    native
        .database("admin")
        .run_command(doc! { "configureFailPoint": "failCommand", "mode": "off" })
        .await
        .unwrap();
    let result = tokio::time::timeout(std::time::Duration::from_secs(6), query_task)
        .await
        .unwrap()
        .unwrap()
        .unwrap();

    let value_index = result.columns.iter().position(|column| column.name == "value").unwrap();
    assert_eq!(result.columns[value_index].data_type, "mixed");
    assert_eq!(
        result.rows[0][value_index],
        Value::Json(serde_json::json!({ "$numberDecimal": decimal.to_string() }))
    );

    assert_decimal_export_formats(&result, &decimal.to_string());
}

fn assert_decimal_export_formats(result: &QueryResult, decimal: &str) {
    let temp = tempfile::tempdir().unwrap();
    for (format, extension) in [
        (tablepro_core::export::ResultFormat::Csv, "csv"),
        (tablepro_core::export::ResultFormat::Json, "json"),
    ] {
        let path = temp.path().join(format!("result.{extension}"));
        let csv = tablepro_core::export::CsvOptions::default();
        let export = tablepro_core::export::ResultExport {
            format,
            csv: &csv,
            sql: None,
        };
        tablepro_core::export::write_result_file(&path, result, &export, || false, |_| {}).unwrap();
        let contents = std::fs::read_to_string(path).unwrap();
        assert!(contents.contains("$numberDecimal"), "{extension}: {contents}");
        assert!(contents.contains(decimal), "{extension}: {contents}");
    }
}

async fn mongodb_census_race_fixture() -> (
    testcontainers::ContainerAsync<testcontainers_modules::mongo::Mongo>,
    mongodb::Client,
    mongodb::Collection<mongodb::bson::Document>,
    std::sync::Arc<dyn tablepro_core::Connection>,
) {
    use mongodb::bson::{Document, doc};
    use tablepro_core::DatabaseDriver;
    use testcontainers::ImageExt;
    use testcontainers::runners::AsyncRunner;
    use testcontainers_modules::mongo::Mongo;

    let container = Mongo::default()
        .with_tag("7")
        .with_cmd(["mongod", "--setParameter", "enableTestCommands=1", "--bind_ip_all"])
        .start()
        .await
        .unwrap();
    let host = container.get_host().await.unwrap().to_string();
    let port = container.get_host_port_ipv4(27017).await.unwrap();
    let native = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .unwrap();
    let collection = native.database("appdb").collection::<Document>("page_census_race");
    let documents = (0..150)
        .map(|id| doc! { "_id": id, "value": if id == 0 { "before" } else { "sibling" } })
        .collect::<Vec<_>>();
    collection.insert_many(documents).await.unwrap();
    let connection = drivers_mongodb::MongodbDriver
        .connect(tablepro_core::ConnectOptions {
            host,
            port,
            database: "appdb".into(),
            tls: tablepro_core::TlsConfig::disabled(),
            ..Default::default()
        })
        .await
        .unwrap()
        .into();
    (container, native, collection, connection)
}

async fn wait_for_mongodb_command(native: &mongodb::Client, name: &str) -> bool {
    use mongodb::bson::doc;

    for _ in 0..40 {
        let current = native
            .database("admin")
            .run_command(doc! { "currentOp": 1, "$all": true })
            .await
            .unwrap();
        let command_blocked = current
            .get_array("inprog")
            .unwrap()
            .iter()
            .filter_map(|operation| operation.as_document())
            .filter_map(|operation| operation.get_document("command").ok())
            .any(|command| {
                if name == "find" {
                    command.get_str(name).ok() == Some("page_census_race")
                } else {
                    command.contains_key(name) && command.get_str("collection").ok() == Some("page_census_race")
                }
            });
        if command_blocked {
            return true;
        }
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
    }
    false
}

fn assert_mongodb_census_race_page(page: &QueryResult) {
    let value_index = page.columns.iter().position(|column| column.name == "value").unwrap();
    let id_index = page.columns.iter().position(|column| column.name == "_id").unwrap();
    assert_eq!(page.rows.len(), 2);
    let first_row = page.rows.iter().find(|row| row[id_index] == Value::Int(0)).unwrap();
    let sibling_row = page.rows.iter().find(|row| row[id_index] == Value::Int(1)).unwrap();
    assert_eq!(
        first_row[value_index],
        Value::Json(serde_json::json!("before")),
        "the page row must retain the value read from the cursor"
    );
    assert_eq!(sibling_row[value_index], Value::Json(serde_json::json!("sibling")));
    assert_eq!(page.columns[value_index].data_type, "mixed");
    assert_cell_read_only(&page.columns[value_index], &first_row[value_index]);
}

async fn mongodb_late_mixed_page_fixture() -> (
    testcontainers::ContainerAsync<testcontainers_modules::mongo::Mongo>,
    Box<dyn tablepro_core::Connection>,
    mongodb::Collection<mongodb::bson::Document>,
    mongodb::bson::Decimal128,
) {
    use mongodb::bson::{Decimal128, doc};
    use tablepro_core::DatabaseDriver;
    use testcontainers::ImageExt;
    use testcontainers::runners::AsyncRunner;
    use testcontainers_modules::mongo::Mongo;

    let container = Mongo::default().with_tag("7").start().await.unwrap();
    let host = container.get_host().await.unwrap().to_string();
    let port = container.get_host_port_ipv4(27017).await.unwrap();
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .unwrap();
    let collection = client
        .database("appdb")
        .collection::<mongodb::bson::Document>("page_mixed_edit_contract");
    let decimal_text = "12345678901234567890.1234567890123";
    let decimal = decimal_text.parse::<Decimal128>().unwrap();
    let mut docs = (0..50)
        .map(|index| doc! { "_id": index, "value": "ordinary text" })
        .collect::<Vec<_>>();
    docs.push(doc! { "_id": 50, "value": decimal });
    collection.insert_many(docs).await.unwrap();

    let connection = drivers_mongodb::MongodbDriver
        .connect(tablepro_core::ConnectOptions {
            host,
            port,
            database: "appdb".into(),
            tls: tablepro_core::TlsConfig::disabled(),
            ..Default::default()
        })
        .await
        .unwrap();
    (container, connection, collection, decimal)
}

#[test]
fn page_metadata_does_not_replace_schema_for_other_drivers() {
    let loaded = vec![column("value", "numeric", false)];
    let page = QueryResult {
        columns: vec![column("value", "text", false)],
        rows: Vec::new(),
        truncated: false,
    };
    assert_eq!(columns_for_browse_page("postgres", &loaded, Some(&page)), loaded);
}

#[test]
fn same_count_type_change_invalidates_cached_grid_factories() {
    let rendered = vec![column("value", "string", false)];
    let current = vec![column("value", "mixed", false)];
    assert!(!column_layout_matches(&rendered, &current));
    assert!(column_layout_matches(&current, &current));
}

#[test]
fn a_page_sql_export_leaves_out_columns_the_server_fills() {
    let plain = |name: &str| ColumnInfo {
        name: name.into(),
        data_type: "int".into(),
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: None,
        domain_type: None,
    };
    let mut table = vec![plain("id"), plain("qty"), plain("total"), plain("version")];
    table[0].primary_key = true;
    table[0].is_auto_increment = true;
    table[2].is_generated = true;
    table[3].is_generated = true;
    let mut page = vec![plain("id"), plain("qty"), plain("total"), plain("version")];

    super::with_table_ownership(&mut page, &table);

    let row = [Value::Int(1), Value::Int(2), Value::Int(4), Value::Int(9)];
    assert_eq!(
        tablepro_core::sql_literal::build_insert_literal("mssql", Some("dbo"), "orders", &page, &row).unwrap(),
        "INSERT INTO [dbo].[orders] ([qty]) VALUES (2);"
    );
    assert!(page[0].primary_key);
}

#[test]
#[ignore = "requires isolated GTK display"]
fn a_closed_browse_tab_releases_its_root_widget() {
    use relm4::gtk::prelude::ObjectExt;
    relm4::gtk::init().unwrap();
    let controller = BrowseTab::builder()
        .launch(BrowseTabInit {
            tab_id: Uuid::new_v4(),
            schema: Some("public".into()),
            table: "customers".into(),
            driver_id: "postgres".into(),
            connection_id: None,
            read_only: true,
            page_size: 100,
            initial_offset: 0,
            initial_sort: None,
            persistence: crate::services::persistence_stores::PersistenceStores {
                column_widths: None,
                filter_settings: None,
                csv_import_mappings: None,
                named_filter_presets: None,
            },
            database: std::sync::Arc::new(crate::services::database_service::DatabaseService::new_isolated()),
        })
        .detach();
    let root = controller.widget().downgrade();
    drop(controller);
    spin_for(
        &relm4::gtk::glib::MainContext::default(),
        std::time::Duration::from_millis(100),
    );
    assert!(root.upgrade().is_none(), "the closed browse tab root is still alive");
}
