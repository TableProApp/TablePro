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
use crate::test_support::{finish_on_main, test_runtime, wait_until};
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
                sanitize_formulas: false,
                ..CsvOptions::default()
            },
        ),
        (
            CopyKind::CsvWithHeaders,
            CsvOptions {
                sanitize_formulas: false,
                ..CsvOptions::default()
            },
        ),
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
fn a_copy_keeps_text_that_starts_like_a_formula_as_it_is() {
    let rows = vec![vec![Value::Text("-".into()), Value::Text("@alice".into())]];

    let tsv = render(rows_request(&rows, CopyKind::Rows)).expect("the copy");
    let csv = render(rows_request(&rows, CopyKind::Csv)).expect("the copy");

    assert_eq!(tsv.text, "-\t@alice\n");
    assert_eq!(csv.text, "-,@alice\n");
}

#[test]
fn copy_insert_uses_visible_columns_only() {
    let request = CopyRequest::Insert(InsertCopy {
        dialect: Arc::new(FakeDialect),
        table: TableRef::new(None, "users"),
        columns: vec![column_info("id", true), column_info("name", false)].into(),
        rows: vec![
            // A row read with its engine row id after the visible cells.
            InsertRow::Saved(RowSnapshot::new(
                vec![Value::Int(1), Value::Text("Ada".into()), Value::Text("(0,1)".into())].into(),
                Vec::new(),
            )),
            InsertRow::Draft(vec![CellInput::Default, CellInput::Value(Value::Text("Grace".into()))]),
        ],
    });

    let payload = render(request).expect("the copy");

    assert_eq!(
        payload.text,
        "INSERT INTO \"users\" (\"id\", \"name\") VALUES (1, 'Ada');\n\
         INSERT INTO \"users\" (\"name\") VALUES ('Grace');"
    );
    assert_eq!(payload.format, ClipboardFormat::Sql);
    assert_eq!(payload.rows, 2);
}

/// MySQL reads a backslash in a string as an escape, so a value ending
/// in one would close the string and run the rest as SQL.
#[test]
fn an_in_clause_copy_is_written_in_the_engines_literals() {
    let dialect = Arc::new(drivers_mysql::MySqlDialect::new(
        drivers_mysql::MySqlFlavour::MySql,
        &tablepro_core::ServerInfo::new("MySQL", "8.4.3", 8, 4, 3),
    ));
    let injected = "\\') OR 1=1 -- ";
    let rows = vec![
        vec![Value::Int(1), Value::Text(injected.into())],
        vec![Value::Int(2), Value::Null],
    ];

    let payload = render(CopyRequest::InClause {
        dialect,
        values: InClauseRows {
            columns: columns(&["id", "name"]),
            rows: snapshots(&rows),
            column: 1,
        },
    })
    .expect("the copy");

    assert_eq!(
        payload.text,
        format!(
            "(_utf8mb4 X'{}')",
            tablepro_core::hex::encode_lower(injected.as_bytes())
        )
    );
    assert_eq!(
        (payload.format, payload.rows, payload.skipped),
        (ClipboardFormat::Sql, 1, 1)
    );
}

#[test]
fn a_copy_holding_a_nul_is_refused_off_the_gtk_thread() {
    let rows = vec![vec![Value::Int(1), Value::Text("a\0b".into())]];

    let refused = render(rows_request(&rows, CopyKind::Rows)).expect_err("a NUL");

    assert!(matches!(refused, CopyError::ContainsNul), "{refused:?}");
}

#[gtk4::test]
fn a_slower_earlier_copy_gives_way_to_a_later_one() {
    let widget = gtk::Label::new(None);
    let clipboard = widget.clipboard();
    let runtime = test_runtime();
    let toasts = Rc::new(RefCell::new(Vec::new()));
    let copy = |request| {
        let sink = toasts.clone();
        copy_rows(&widget, &runtime.tasks(), request, move |text| {
            sink.borrow_mut().push(text.to_owned());
        })
    };
    let slow = copy(rows_request(&many_rows(), CopyKind::Json));
    let fast = copy(rows_request(&people()[..1], CopyKind::Rows));
    finish_on_main(WAIT, fast)
        .expect("the later copy to end")
        .expect("the later copy");
    assert_eq!(local_text(&clipboard).as_deref(), Some("-5\t=cmd\n"));
    let landed = clipboard.content();
    finish_on_main(WAIT, slow)
        .expect("the earlier copy to end")
        .expect("the earlier copy");

    assert_eq!(toasts.take(), ["Copied 1 row"]);
    // Other test processes share the X server and can take the
    // clipboard meanwhile, which leaves it with no local content.
    let now = clipboard.content();
    assert!(
        now.is_none() || now == landed,
        "the earlier copy replaced the later one"
    );
    runtime.shutdown();
}

fn many_rows() -> Vec<Vec<Value>> {
    (0..100_000)
        .map(|row| vec![Value::Int(row), Value::Text(format!("name {row}"))])
        .collect()
}

/// A copy written at once, as Copy Query in the history does, while a
/// large copy still renders.
#[gtk4::test]
fn a_copy_still_rendering_gives_way_to_one_written_at_once() {
    let widget = gtk::Label::new(None);
    let clipboard = widget.clipboard();
    let runtime = test_runtime();
    let toasts = Rc::new(RefCell::new(Vec::new()));
    let sink = toasts.clone();

    let slow = copy_rows(
        &widget,
        &runtime.tasks(),
        rows_request(&many_rows(), CopyKind::Json),
        move |text| sink.borrow_mut().push(text.to_owned()),
    );
    copy_text(&widget, "SELECT 1".to_owned(), |text| {
        toasts.borrow_mut().push(text.to_owned())
    });
    let landed = clipboard.content();
    finish_on_main(WAIT, slow)
        .expect("the earlier copy to end")
        .expect("the earlier copy");

    assert_eq!(toasts.take(), ["Copied to clipboard"]);
    let now = clipboard.content();
    assert!(
        now.is_none() || now == landed,
        "the earlier copy replaced the later one"
    );
    runtime.shutdown();
}

/// A text field copies through GTK, past every ticket.
#[gtk4::test]
fn a_copy_still_rendering_gives_way_to_a_text_field_copy() {
    let widget = gtk::Label::new(None);
    let clipboard = widget.clipboard();
    let runtime = test_runtime();
    let toasts = Rc::new(RefCell::new(Vec::new()));
    let sink = toasts.clone();
    let field = gtk::Text::new();
    field.set_text("typed");
    field.select_region(0, -1);

    let slow = copy_rows(
        &widget,
        &runtime.tasks(),
        rows_request(&many_rows(), CopyKind::Json),
        move |text| sink.borrow_mut().push(text.to_owned()),
    );
    field.emit_by_name::<()>("copy-clipboard", &[]);
    assert_eq!(local_text(&clipboard).as_deref(), Some("typed"));
    let landed = clipboard.content();
    finish_on_main(WAIT, slow)
        .expect("the earlier copy to end")
        .expect("the earlier copy");

    assert!(toasts.borrow().is_empty(), "{:?}", toasts.borrow());
    let now = clipboard.content();
    assert!(
        now.is_none() || now == landed,
        "the earlier copy replaced the text field's"
    );
    runtime.shutdown();
}

#[gtk4::test]
fn copy_as_csv_offers_text_csv_and_plain_text() {
    let (clipboard, toasts) = copied(rows_request(&people(), CopyKind::CsvWithHeaders));

    let formats = clipboard.formats();
    assert!(formats.contain_mime_type("text/csv"), "{}", formats.to_str());
    assert!(formats.contains_type(String::static_type()), "{}", formats.to_str());
    assert_eq!(
        local_text(&clipboard).as_deref(),
        Some("id,name\n-5,=cmd\n7,\"Ada, \"\"the first\"\"\"\n")
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
