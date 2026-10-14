use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gdk, glib};
use tablepro_core::Value;
use tablepro_core::column::{ColumnDefault, ColumnInfo, ColumnType, ResultColumn};
use tablepro_core::edit::CellInput;
use tablepro_core::export::{CsvOptions, render_csv};
use tablepro_core::meta::TableRef;
use tablepro_test_support::FakeDialect;

use super::*;
use crate::test_support::{test_runtime, wait_until};
use crate::ui::grid::RowSnapshot;

const WAIT: Duration = Duration::from_secs(30);

fn columns(names: &[&str]) -> Arc<[ResultColumn]> {
    names
        .iter()
        .map(|name| ResultColumn::new(*name, ColumnType::untyped_text("text")))
        .collect()
}

fn snapshots(rows: &[Vec<Value>]) -> Vec<RowSnapshot> {
    rows.iter()
        .map(|row| RowSnapshot::new(row.clone().into(), Vec::new()))
        .collect()
}

fn people() -> Vec<Vec<Value>> {
    vec![
        vec![Value::Int(-5), Value::Text("=cmd".into())],
        vec![Value::Int(7), Value::Text("Ada, \"the first\"".into())],
    ]
}

fn rows_request(rows: &[Vec<Value>], kind: CopyKind) -> CopyRequest {
    CopyRequest::Rows {
        columns: columns(&["id", "name"]),
        rows: snapshots(rows),
        kind,
    }
}

fn local_text(clipboard: &gdk::Clipboard) -> Option<String> {
    clipboard.content()?.value(String::static_type()).ok()?.get().ok()
}

/// Copy through a widget the way a tab does, and wait for the toast
/// that says it landed.
fn copied(request: CopyRequest) -> (gdk::Clipboard, Vec<String>) {
    let widget = gtk::Label::new(None);
    let clipboard = widget.clipboard();
    clipboard.set_text("before");
    let runtime = test_runtime();
    let toasts = Rc::new(RefCell::new(Vec::new()));
    let sink = toasts.clone();

    copy_rows(&widget, &runtime.tasks(), request, move |text| {
        sink.borrow_mut().push(text.to_owned());
    });
    wait_until(WAIT, || !toasts.borrow().is_empty()).expect("the copy to land");

    runtime.shutdown();
    (clipboard, toasts.take())
}

fn column_info(name: &str, primary_key: bool) -> ColumnInfo {
    ColumnInfo {
        name: name.to_owned(),
        column_type: ColumnType::untyped_text("text"),
        nullable: !primary_key,
        primary_key,
        is_auto_increment: false,
        is_generated: false,
        default: ColumnDefault::None,
        comment: None,
    }
}

#[test]
fn copy_renderer_csv_matches_render_csv() {
    let rows = people();
    let cases = [
        (
            CopyKind::Csv,
            CsvOptions {
                header_row: false,
                ..CsvOptions::default()
            },
        ),
        (CopyKind::CsvWithHeaders, CsvOptions::default()),
    ];
    for (kind, options) in cases {
        let payload = render(rows_request(&rows, kind)).expect("the copy");

        let expected = render_csv(&columns(&["id", "name"]), &rows, &options).expect("the csv");
        assert_eq!(payload.text, expected, "{kind:?}");
        assert_eq!(payload.format, ClipboardFormat::Csv);
        assert_eq!(payload.rows, 2);
    }
}

#[test]
fn copy_insert_uses_visible_columns_only() {
    let request = CopyRequest::Insert(InsertCopy {
        dialect: Arc::new(FakeDialect),
        table: TableRef::new(None, "users"),
        columns: vec![column_info("id", true), column_info("name", false)].into(),
        // A row read with its engine row id after the visible cells.
        rows: vec![vec![
            CellInput::Value(Value::Int(1)),
            CellInput::Value(Value::Text("Ada".into())),
            CellInput::Value(Value::Text("(0,1)".into())),
        ]],
    });

    let payload = render(request).expect("the copy");

    assert_eq!(
        payload.text,
        "INSERT INTO \"users\" (\"id\", \"name\") VALUES (1, 'Ada');"
    );
    assert_eq!(payload.format, ClipboardFormat::Sql);
}

#[gtk4::test]
fn copy_as_csv_offers_text_csv_and_plain_text() {
    let (clipboard, toasts) = copied(rows_request(&people(), CopyKind::CsvWithHeaders));

    let formats = clipboard.formats();
    assert!(formats.contain_mime_type("text/csv"), "{}", formats.to_str());
    assert!(formats.contains_type(String::static_type()), "{}", formats.to_str());
    assert_eq!(
        local_text(&clipboard).as_deref(),
        Some("\"id\",\"name\"\n\"-5\",\"'=cmd\"\n\"7\",\"Ada, \"\"the first\"\"\"\n")
    );
    assert_eq!(toasts, ["Copied 2 rows"]);
}

#[gtk4::test]
fn copy_rows_offers_tab_separated_values() {
    let (clipboard, toasts) = copied(rows_request(&people(), CopyKind::Rows));

    let formats = clipboard.formats();
    assert!(
        formats.contain_mime_type("text/tab-separated-values"),
        "{}",
        formats.to_str()
    );
    assert_eq!(
        local_text(&clipboard).as_deref(),
        Some("-5\t=cmd\n7\t\"Ada, \"\"the first\"\"\"\n")
    );
    assert_eq!(toasts, ["Copied 2 rows"]);
}

#[gtk4::test]
fn copy_as_json_offers_application_json() {
    let (clipboard, _) = copied(rows_request(&people(), CopyKind::Json));

    let formats = clipboard.formats();
    assert!(formats.contain_mime_type("application/json"), "{}", formats.to_str());
    let text = local_text(&clipboard).expect("the copy");
    let parsed: serde_json::Value = serde_json::from_str(&text).expect("JSON");
    assert_eq!(parsed[1]["name"], serde_json::json!("Ada, \"the first\""));
}

#[gtk4::test]
fn large_copy_renders_on_blocking_pool() {
    let rows: Vec<Vec<Value>> = (0..200_000)
        .map(|row| vec![Value::Int(row), Value::Text(format!("name {row}"))])
        .collect();
    let ticks = Rc::new(Cell::new(0_u32));
    let counted = ticks.clone();
    let ticking = glib::timeout_add_local(Duration::from_millis(1), move || {
        counted.set(counted.get() + 1);
        glib::ControlFlow::Continue
    });

    let (clipboard, toasts) = copied(rows_request(&rows, CopyKind::Json));
    ticking.remove();

    assert!(
        ticks.get() >= 5,
        "the main loop stood still while the copy rendered: {} ticks",
        ticks.get()
    );
    assert_eq!(toasts, ["Copied 200,000 rows"]);
    let parsed: Vec<serde_json::Value> =
        serde_json::from_str(&local_text(&clipboard).expect("the copy")).expect("JSON");
    assert_eq!(parsed.len(), 200_000);
}
