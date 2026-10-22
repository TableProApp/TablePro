use std::sync::Arc;
use std::time::{Duration, Instant};

use gtk4::prelude::*;
use tablepro_core::{ColumnInfo, QueryResult, Value};

use super::{TabGridContext, build_column_view};
use crate::services::database_service::DatabaseService;

fn drain() {
    let context = gtk4::glib::MainContext::default();
    let until = Instant::now() + Duration::from_millis(100);
    while Instant::now() < until {
        while context.iteration(false) {}
        std::thread::sleep(Duration::from_millis(1));
    }
}

fn cells(widget: &gtk4::Widget, found: &mut Vec<gtk4::glib::WeakRef<gtk4::Widget>>) {
    if widget.is::<crate::ui::cell_editor::CellEditor>()
        || widget
            .downcast_ref::<gtk4::Label>()
            .is_some_and(|label| label.text().starts_with("value-"))
    {
        found.push(widget.downgrade());
    }
    let mut child = widget.first_child();
    while let Some(current) = child {
        cells(&current, found);
        child = current.next_sibling();
    }
}

struct RetiredGrid {
    view: gtk4::glib::WeakRef<gtk4::ColumnView>,
    selection: gtk4::glib::WeakRef<gtk4::MultiSelection>,
    result: std::sync::Weak<QueryResult>,
    cells: Vec<gtk4::glib::WeakRef<gtk4::Widget>>,
}

impl RetiredGrid {
    fn assert_released(&self) {
        assert!(
            self.cells.iter().all(|cell| cell.upgrade().is_none()),
            "detached grid cells are still alive"
        );
        assert!(self.view.upgrade().is_none(), "the detached grid is still alive");
        assert!(
            self.selection.upgrade().is_none(),
            "the detached selection is still alive"
        );
        assert!(
            self.result.upgrade().is_none(),
            "the detached grid still retains its result page"
        );
    }
}

fn retire_grid(with_menus: bool, editable: bool, rendered: bool) -> RetiredGrid {
    let column = ColumnInfo {
        name: "value".into(),
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
    };
    let result = Arc::new(QueryResult {
        columns: vec![column],
        rows: (0..1_000)
            .map(|index| vec![Value::Text(format!("value-{index}"))])
            .collect(),
        truncated: false,
    });
    let result_weak = Arc::downgrade(&result);
    let (sender, _receiver) = relm4::channel();
    let tab_ctx = if with_menus && !editable {
        let local = super::local_filter::LocalResultView::new(
            result.clone(),
            super::local_filter::LocalResultSettingsStore::default(),
            super::local_filter::ResultViewKey {
                statement_identity: crate::ui::editor::StatementIdentity {
                    statement_index: 0,
                    digest: [0; 32],
                },
                result_set_index: 0,
            },
        );
        TabGridContext {
            local_result_view: Some(local),
            preview_result_values: true,
            local_result_sort: true,
            sortable_result_columns: super::sortable_result_columns(&result),
            ..Default::default()
        }
    } else {
        TabGridContext::default()
    };
    let (view, selection) = build_column_view(
        &result,
        &result.columns,
        "items",
        editable.then_some(sender.clone()),
        with_menus.then_some(sender),
        None,
        None,
        None,
        tab_ctx,
        None,
        Arc::new(DatabaseService::new()),
    );
    let view_weak = view.downgrade();
    let selection_weak = selection.downgrade();
    let mut cell_refs = Vec::new();
    if rendered {
        let window = gtk4::Window::builder()
            .default_width(640)
            .default_height(300)
            .child(&gtk4::ScrolledWindow::builder().child(&view).build())
            .build();
        window.present();
        drain();
        cells(view.upcast_ref(), &mut cell_refs);
        assert!(!cell_refs.is_empty(), "no cells were rendered");
        window.set_child(None::<&gtk4::Widget>);
        window.destroy();
        drop(window);
    }
    drop(view);
    drop(selection);
    drop(result);
    drain();
    RetiredGrid {
        view: view_weak,
        selection: selection_weak,
        result: result_weak,
        cells: cell_refs,
    }
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn a_dropped_result_grid_releases_its_page() {
    gtk4::init().unwrap();
    retire_grid(false, false, false).assert_released();
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn a_rendered_result_grid_with_menus_releases_its_page() {
    gtk4::init().unwrap();
    retire_grid(true, false, true).assert_released();
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn a_rendered_editable_grid_releases_its_page() {
    gtk4::init().unwrap();
    retire_grid(true, true, true).assert_released();
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn repeated_result_grid_replacement_releases_every_retired_page() {
    gtk4::init().unwrap();
    let retired: Vec<_> = (0..8).map(|_| retire_grid(true, false, true)).collect();
    for grid in retired {
        grid.assert_released();
    }
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn a_menu_context_does_not_keep_a_removed_cell_alive() {
    gtk4::init().unwrap();
    let widget: gtk4::Widget = gtk4::Label::new(Some("value")).upcast();
    let weak = widget.downgrade();
    let context = super::cell_context::CellContextStore::default();
    context.set(&widget, 2, "value".into());
    {
        let snapshot = context.snapshot().unwrap();
        assert_eq!(snapshot.widget, widget);
        assert_eq!(snapshot.col_index, 2);
        assert_eq!(snapshot.column_name, "value");
    }
    drop(widget);
    assert!(weak.upgrade().is_none());
    assert!(context.snapshot().is_none());
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn a_retired_grid_does_not_retain_its_inspector_through_selection_callback() {
    gtk4::init().unwrap();
    let column = ColumnInfo {
        name: "value".into(),
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
    };
    let result = Arc::new(QueryResult {
        columns: vec![column.clone()],
        rows: vec![vec![Value::Text("value".into())]],
        truncated: false,
    });
    let weak_result = Arc::downgrade(&result);
    let (view, selection) = build_column_view(
        &result,
        &[column],
        "items",
        None,
        None,
        None,
        None,
        None,
        TabGridContext::default(),
        None,
        Arc::new(DatabaseService::new()),
    );
    let inspector = crate::ui::row_inspector::RowInspector::new(&view);
    let weak_view = view.downgrade();
    let weak_selection = selection.downgrade();
    let weak_inspector = inspector.widget().downgrade();
    selection.connect_selection_changed({
        let inspector = inspector.downgrade();
        move |_, _, _| inspector.show_row(None)
    });
    drop(inspector);
    drop(view);
    drop(selection);
    drop(result);
    drain();
    assert!(weak_view.upgrade().is_none(), "retired grid remains alive");
    assert!(weak_selection.upgrade().is_none(), "retired selection remains alive");
    assert!(weak_inspector.upgrade().is_none(), "retired inspector remains alive");
    assert!(weak_result.upgrade().is_none(), "retired result page remains alive");
}
