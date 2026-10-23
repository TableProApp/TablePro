mod pager;
pub(super) use pager::build as build_pager;

use relm4::gtk;
use relm4::gtk::prelude::*;

use super::StatementOutcome;
use super::outcomes::{build_stream_page_widget, result_view_key, stream_page_label, stream_progress_text};
use super::stream_pages::StreamedResult;
use crate::ui::grid::GridMsg;
use crate::ui::grid::local_filter::LocalResultSettingsStore;

pub(super) const LIVE_PAGES: &str = "tp-live-stream-pages";
pub(super) const LIVE_PROGRESS: &str = "tp-live-stream-progress";
const PAGE_PREFIX: &str = "tp-stream-page-";

pub(super) fn page_widget_name(page_index: u64) -> String {
    format!("{PAGE_PREFIX}{page_index}")
}

fn named<T: IsA<gtk::Widget>>(root: &gtk::Widget, name: &str) -> Option<T> {
    let mut pending = vec![root.clone()];
    while let Some(widget) = pending.pop() {
        if widget.widget_name() == name
            && let Ok(found) = widget.clone().downcast::<T>()
        {
            return Some(found);
        }
        let mut child = widget.first_child();
        while let Some(next) = child {
            child = next.next_sibling();
            pending.push(next);
        }
    }
    None
}

pub(super) struct LiveStreamTarget<'a> {
    pub(super) grid_sender: &'a relm4::Sender<GridMsg>,
    pub(super) connection_id: Option<uuid::Uuid>,
    pub(super) database: std::sync::Arc<crate::services::database_service::DatabaseService>,
    pub(super) settings_store: LocalResultSettingsStore,
}

pub(super) fn update_live_stream(
    holder: &gtk::Box,
    outcome: &StatementOutcome,
    result: &StreamedResult,
    target: &LiveStreamTarget<'_>,
) -> bool {
    let root = holder.clone().upcast::<gtk::Widget>();
    let (Some(pages), Some(progress)) = (
        named::<gtk::Stack>(&root, LIVE_PAGES),
        named::<gtk::Label>(&root, LIVE_PROGRESS),
    ) else {
        return false;
    };
    let shown_index = |widget: &gtk::Widget| {
        widget
            .widget_name()
            .strip_prefix(PAGE_PREFIX)
            .and_then(|index| index.parse::<u64>().ok())
    };
    let mut child = pages.first_child();
    while let Some(page) = child {
        child = page.next_sibling();
        if shown_index(&page).is_some_and(|index| !result.page_indices.contains(&index)) {
            pages.remove(&page);
        }
    }
    for (position, (page_index, page)) in result.page_indices.iter().copied().zip(&result.pages).enumerate() {
        if pages.child_by_name(&page_widget_name(page_index)).is_some() {
            continue;
        }
        let widget = build_stream_page_widget(
            page,
            target.grid_sender,
            target.connection_id,
            target.database.clone(),
            target.settings_store.clone(),
            result_view_key(outcome.identity, page_index as usize),
        );
        widget.set_widget_name(&page_widget_name(page_index));
        pages.add_titled(
            &widget,
            Some(widget.widget_name().as_str()),
            &stream_page_label(result, position),
        );
    }
    pages.notify("visible-child");
    progress.set_text(&stream_progress_text(result));
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ui::editor::stream_pages::StreamTerminal;
    use crate::ui::editor::{StatementIdentity, StatementOutcomeKind};
    use std::sync::Arc;
    use tablepro_core::{ColumnInfo, QueryResult, Value};

    fn wait_for_grid(root: &gtk::Widget) -> gtk::ColumnView {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            if let Some(grid) = named::<gtk::ColumnView>(root, "GtkColumnView") {
                return grid;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "selected page did not build its grid"
            );
            gtk::glib::MainContext::default().iteration(false);
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
    }

    fn label_references(root: &gtk::Widget) -> Vec<gtk::glib::WeakRef<gtk::Widget>> {
        let mut pending = vec![root.clone()];
        let mut labels = Vec::new();
        while let Some(widget) = pending.pop() {
            if widget.is::<gtk::Label>() {
                labels.push(widget.downgrade());
            }
            let mut child = widget.first_child();
            while let Some(next) = child {
                child = next.next_sibling();
                pending.push(next);
            }
        }
        labels
    }

    fn page(values: &[i64]) -> Arc<QueryResult> {
        Arc::new(QueryResult {
            columns: vec![ColumnInfo {
                name: "id".into(),
                data_type: "int8".into(),
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
            rows: values.iter().map(|value| vec![Value::Int(*value)]).collect(),
            truncated: false,
        })
    }

    fn streamed(
        indices: &[u64],
        pages: Vec<Arc<QueryResult>>,
        total_rows: usize,
    ) -> (StatementOutcome, StreamedResult) {
        let result = StreamedResult {
            pages,
            page_indices: indices.to_vec(),
            total_pages: indices.last().map_or(0, |last| last + 1),
            total_rows,
            terminal: StreamTerminal::Loading,
            export: None,
        };
        let outcome = StatementOutcome {
            identity: StatementIdentity::default(),
            sql_preview: "SELECT id FROM items".into(),
            elapsed_ms: 0,
            kind: StatementOutcomeKind::Streamed(Box::new(result.clone())),
            pinned: false,
        };
        (outcome, result)
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn a_new_stream_page_is_appended_without_rebuilding_the_pages_already_shown() {
        relm4::adw::init().unwrap();
        let (grid_sender, _) = relm4::channel::<GridMsg>();
        let database = Arc::new(crate::services::database_service::DatabaseService::new_isolated());
        let target = LiveStreamTarget {
            grid_sender: &grid_sender,
            connection_id: None,
            database: database.clone(),
            settings_store: LocalResultSettingsStore::default(),
        };
        let holder = gtk::Box::new(gtk::Orientation::Vertical, 0);
        let (first, _) = streamed(&[0], vec![page(&[1, 2])], 2);
        super::super::outcomes::render_outcomes(
            &holder,
            std::slice::from_ref(&first),
            &grid_sender,
            None,
            database,
            LocalResultSettingsStore::default(),
        );
        let root = holder.clone().upcast::<gtk::Widget>();
        let pages = named::<gtk::Stack>(&root, LIVE_PAGES).expect("live stream pages");
        let labels = label_references(&root);
        assert!(!labels.is_empty());
        let first_grid = pages.first_child().unwrap();
        pages.set_visible_child(&pages.first_child().unwrap());

        let (second, result) = streamed(&[0, 1], vec![page(&[1, 2]), page(&[3])], 3);
        assert!(update_live_stream(&holder, &second, &result, &target));

        assert_eq!(named::<gtk::Stack>(&root, LIVE_PAGES).as_ref(), Some(&pages));
        assert_eq!(pages.pages().n_items(), 2);
        assert_eq!(pages.first_child().as_ref(), Some(&first_grid));
        assert_eq!(
            pages.visible_child().as_ref(),
            Some(&first_grid),
            "the page the user is reading stays selected"
        );
        let progress = named::<gtk::Label>(&root, LIVE_PROGRESS).unwrap();
        assert_eq!(progress.text(), stream_progress_text(&result));

        let (third, evicted) = streamed(&[1, 2], vec![page(&[3]), page(&[4])], 4);
        assert!(update_live_stream(&holder, &third, &evicted, &target));
        assert_eq!(pages.pages().n_items(), 2);
        assert!(pages.child_by_name(&first_grid.widget_name()).is_none());
        drop((holder, root, pages, first_grid, progress));
        while gtk::glib::MainContext::default().iteration(false) {}
        assert!(
            labels.iter().all(|label| label.upgrade().is_none()),
            "retired result labels remain alive"
        );
    }
    #[test]
    fn short_retained_pages_use_received_row_positions_after_eviction() {
        let (_, result) = streamed(&[8, 9], vec![page(&[105, 106]), page(&[107])], 7);
        assert_eq!(stream_page_label(&result, 0), "Rows 5-6");
        assert_eq!(stream_page_label(&result, 1), "Rows 7-7");
        assert_eq!(
            stream_progress_text(&result),
            "Received 7 rows · 10 pages\nRetained rows 5-7. Earlier rows are no longer available."
        );
    }
    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn a_stream_page_retired_before_a_frame_does_not_build_a_grid() {
        relm4::adw::init().unwrap();
        let (sender, _receiver) = relm4::channel::<GridMsg>();
        let result = page(&[1, 2]);
        let retired = Arc::downgrade(&result);
        let widget = build_stream_page_widget(
            &result,
            &sender,
            None,
            Arc::new(crate::services::database_service::DatabaseService::new_isolated()),
            LocalResultSettingsStore::default(),
            result_view_key(StatementIdentity::default(), 0),
        );
        let holder = widget.clone().downcast::<gtk::Box>().unwrap();
        let window = gtk::Window::builder().default_width(900).default_height(600).build();
        window.present();
        let context = gtk::glib::MainContext::default();
        while context.iteration(false) {}
        window.set_child(Some(&holder));
        assert!(holder.is_mapped());
        window.set_child(gtk::Widget::NONE);
        assert!(holder.first_child().is_none());
        while context.iteration(false) {}
        assert!(holder.first_child().is_none());
        drop(result);
        drop(widget);
        drop(holder);
        assert!(retired.upgrade().is_none());
        let deadline = std::time::Instant::now() + std::time::Duration::from_millis(100);
        while std::time::Instant::now() < deadline {
            context.iteration(false);
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        assert!(retired.upgrade().is_none());
        window.destroy();
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn hidden_stream_pages_build_their_grid_only_when_selected() {
        relm4::adw::init().unwrap();
        let holder = gtk::Box::new(gtk::Orientation::Vertical, 0);
        let (outcome, _) = streamed(&[0, 1], vec![page(&[1, 2]), page(&[3, 4])], 4);
        let (sender, _receiver) = relm4::channel::<GridMsg>();
        super::super::outcomes::render_outcomes(
            &holder,
            &[outcome],
            &sender,
            None,
            Arc::new(crate::services::database_service::DatabaseService::new_isolated()),
            LocalResultSettingsStore::default(),
        );
        let root = holder.clone().upcast::<gtk::Widget>();
        let pages = named::<gtk::Stack>(&root, LIVE_PAGES).unwrap();
        let first = pages.first_child().unwrap();
        assert!(named::<gtk::ColumnView>(&first, "GtkColumnView").is_none());
        let window = gtk::Window::builder()
            .default_width(900)
            .default_height(600)
            .child(&holder)
            .build();
        window.present();
        let context = gtk::glib::MainContext::default();
        while context.iteration(false) {}
        assert!(named::<gtk::ColumnView>(&first, "GtkColumnView").is_none());
        pages.set_visible_child(&pages.first_child().unwrap());
        while context.iteration(false) {}
        let grid = wait_for_grid(&first);
        pages.set_visible_child(&pages.last_child().unwrap());
        pages.set_visible_child(&pages.first_child().unwrap());
        while context.iteration(false) {}
        assert_eq!(named::<gtk::ColumnView>(&first, "GtkColumnView"), Some(grid));
        window.destroy();
    }
    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn a_terminal_status_keeps_retained_grids_unbuilt_until_selected() {
        relm4::adw::init().unwrap();
        let holder = gtk::Box::new(gtk::Orientation::Vertical, 0);
        let (mut outcome, mut result) = streamed(&[0], vec![page(&[1, 2])], 2);
        result.terminal = StreamTerminal::Cancelled;
        outcome.kind = StatementOutcomeKind::Streamed(Box::new(result));
        let (sender, _receiver) = relm4::channel::<GridMsg>();
        super::super::outcomes::render_outcomes(
            &holder,
            &[outcome],
            &sender,
            None,
            Arc::new(crate::services::database_service::DatabaseService::new_isolated()),
            LocalResultSettingsStore::default(),
        );
        let root = holder.clone().upcast::<gtk::Widget>();
        let pages = named::<gtk::Stack>(&root, "GtkStack").unwrap();
        let data = pages.first_child().unwrap();
        let window = gtk::Window::builder()
            .default_width(900)
            .default_height(600)
            .child(&holder)
            .build();
        window.present();
        let context = gtk::glib::MainContext::default();
        while context.iteration(false) {}
        assert_eq!(pages.visible_child(), pages.last_child());
        assert!(named::<gtk::ColumnView>(&data, "GtkColumnView").is_none());
        pages.set_visible_child(&pages.first_child().unwrap());
        while context.iteration(false) {}
        let grid = wait_for_grid(&data);
        assert_eq!(named::<gtk::ColumnView>(&data, "GtkColumnView"), Some(grid));
        window.destroy();
    }
}
