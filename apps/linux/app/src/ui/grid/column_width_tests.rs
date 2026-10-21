use std::sync::Arc;
use std::time::{Duration, Instant};

use gtk4::prelude::*;
use tablepro_core::{ColumnInfo, QueryResult, Value};

use crate::services::column_widths::ColumnWidthStore;
use crate::services::database_service::DatabaseService;

use super::{TabGridContext, build_column_view};

fn column(name: &str) -> ColumnInfo {
    ColumnInfo {
        name: name.into(),
        data_type: "TEXT".into(),
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: None,
        domain_type: None,
    }
}

fn settle() {
    let context = gtk4::glib::MainContext::default();
    let deadline = Instant::now() + Duration::from_millis(150);
    while Instant::now() < deadline {
        while context.iteration(false) {}
        std::thread::sleep(Duration::from_millis(2));
    }
}

fn cell(widget: &gtk4::Widget, text: &str) -> Option<gtk4::Widget> {
    if widget
        .clone()
        .downcast::<gtk4::Label>()
        .is_ok_and(|label| label.text() == text)
    {
        return Some(widget.clone());
    }
    let mut child = widget.first_child();
    while let Some(current) = child {
        if let Some(found) = cell(&current, text) {
            return Some(found);
        }
        child = current.next_sibling();
    }
    None
}

fn verify_fixed_width(saved: bool, persistent: bool) {
    gtk4::init().unwrap();
    let directory = tempfile::tempdir().unwrap();
    let store = ColumnWidthStore::load_in(directory.path());
    let id = uuid::Uuid::new_v4();
    if saved {
        store.save(id, "items", "first", 140).unwrap();
    }
    let columns = vec![column("first"), column("second")];
    let result = Arc::new(QueryResult {
        columns: columns.clone(),
        rows: vec![vec![
            Value::Text("first-value".into()),
            Value::Text("second-value".into()),
        ]],
        truncated: false,
    });
    let (view, _) = build_column_view(
        &result,
        &columns,
        "items",
        None,
        None,
        None,
        None,
        persistent.then_some(id),
        TabGridContext::default(),
        persistent.then_some(store.clone()),
        Arc::new(DatabaseService::new()),
    );
    let window = gtk4::Window::builder()
        .default_width(500)
        .default_height(300)
        .child(&gtk4::ScrolledWindow::builder().child(&view).build())
        .build();
    window.present();
    settle();
    let first = view
        .columns()
        .item(0)
        .unwrap()
        .downcast::<gtk4::ColumnViewColumn>()
        .unwrap();
    if !saved {
        first.set_fixed_width(140);
        settle();
    }
    let fixed_cell = cell(view.upcast_ref(), "first-value").unwrap();
    let expanding_cell = cell(view.upcast_ref(), "second-value").unwrap();
    let before = (fixed_cell.width(), expanding_cell.width());
    window.set_size_request(800, 300);
    settle();
    assert!(
        view.width() >= 750,
        "the view did not resize: view={} window={} default={}",
        view.width(),
        window.width(),
        window.default_width()
    );
    assert_eq!(fixed_cell.width(), before.0, "the manual width changed with the window");
    assert!(
        expanding_cell.width() > before.1,
        "the unsized column must still fill available space"
    );
    if persistent {
        assert_eq!(store.load(id, "items", "first"), Some(140));
    }
    window.close();
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn saved_grid_width_stays_fixed_when_the_window_grows() {
    verify_fixed_width(true, true);
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn resized_grid_width_stays_fixed_when_the_window_grows() {
    verify_fixed_width(false, true);
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn unsaved_result_grid_width_stays_fixed_when_the_window_grows() {
    verify_fixed_width(false, false);
}
