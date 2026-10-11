use std::rc::Rc;

use gtk4 as gtk;
use libadwaita::{self as adw, prelude::*};
use tablepro_core::Value;

use super::display::value_to_display_text;
use crate::ui::row_object::RowObject;

const MAX_MATCHES: usize = 200;
const PREVIEW_CHARS: usize = 80;

pub(super) struct RowMatch {
    pub position: u32,
    pub column: usize,
    pub text: String,
}

pub(super) fn first_matching_cell(cells: &[Option<Value>], needle: &str) -> Option<(usize, String)> {
    cells
        .iter()
        .enumerate()
        .filter_map(|(column, value)| value.as_ref().map(|value| (column, value)))
        .find_map(|(column, value)| {
            let text = value_to_display_text(value);
            text.to_lowercase().contains(needle).then_some((column, text))
        })
}

pub(super) fn matching_rows(
    count: u32,
    row_at: impl Fn(u32) -> Option<Vec<Option<Value>>>,
    query: &str,
    limit: usize,
) -> Vec<RowMatch> {
    let needle = query.trim().to_lowercase();
    if needle.is_empty() {
        return Vec::new();
    }
    let mut found = Vec::new();
    for position in 0..count {
        let Some(cells) = row_at(position) else {
            continue;
        };
        if let Some((column, text)) = first_matching_cell(&cells, &needle) {
            found.push(RowMatch { position, column, text });
            if found.len() == limit {
                break;
            }
        }
    }
    found
}

fn preview(text: &str) -> String {
    let single_line: String = text.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
    if single_line.chars().count() <= PREVIEW_CHARS {
        return single_line;
    }
    let cut: String = single_line.chars().take(PREVIEW_CHARS).collect();
    format!("{cut}…")
}

pub(super) fn install(view: &gtk::ColumnView, actions: &gtk::gio::SimpleActionGroup, names: Vec<String>) {
    let action = gtk::gio::SimpleAction::new("find-row", None);
    let weak_view = view.downgrade();
    let names = Rc::new(names);
    action.connect_activate(move |_, _| {
        if let Some(view) = weak_view.upgrade().filter(|view| view.is_mapped()) {
            present(&view, names.clone());
        }
    });
    actions.add_action(&action);
    let controller = gtk::ShortcutController::new();
    controller.set_propagation_phase(gtk::PropagationPhase::Capture);
    controller.add_shortcut(
        gtk::Shortcut::builder()
            .trigger(&crate::ui::shortcut::parse("<Primary><Alt>f"))
            .action(&gtk::NamedAction::new("grid.find-row"))
            .build(),
    );
    view.add_controller(controller);
}

struct FindWidgets {
    content: gtk::Box,
    search: gtk::SearchEntry,
    status: gtk::Label,
    list: gtk::ListBox,
}

fn build_widgets() -> FindWidgets {
    let content = gtk::Box::new(gtk::Orientation::Vertical, 8);
    content.append(&adw::HeaderBar::new());
    let search = gtk::SearchEntry::builder()
        .placeholder_text(crate::tr!("Search the loaded rows"))
        .margin_start(12)
        .margin_end(12)
        .build();
    search.update_property(&[gtk::accessible::Property::Label(&crate::tr!("Search the loaded rows"))]);
    content.append(&search);
    let status = gtk::Label::builder()
        .xalign(0.0)
        .margin_start(12)
        .margin_end(12)
        .build();
    status.add_css_class("dim-label");
    content.append(&status);
    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::Single)
        .activate_on_single_click(true)
        .build();
    list.add_css_class("boxed-list");
    content.append(
        &gtk::ScrolledWindow::builder()
            .child(&list)
            .vexpand(true)
            .margin_start(12)
            .margin_end(12)
            .margin_bottom(12)
            .build(),
    );
    FindWidgets {
        content,
        search,
        status,
        list,
    }
}

fn result_row(label: &str) -> gtk::ListBoxRow {
    let row = gtk::ListBoxRow::new();
    row.set_child(Some(
        &gtk::Label::builder()
            .label(label)
            .xalign(0.0)
            .margin_start(12)
            .margin_end(12)
            .margin_top(8)
            .margin_bottom(8)
            .build(),
    ));
    row.update_property(&[gtk::accessible::Property::Label(label)]);
    row
}

fn status_text(query: &str, shown: usize) -> String {
    if query.trim().is_empty() {
        String::new()
    } else if shown == 0 {
        crate::tr!("No matching rows")
    } else if shown >= MAX_MATCHES {
        crate::tr!("The first {count} matches").replace("{count}", &MAX_MATCHES.to_string())
    } else {
        crate::tr!("{count} matching rows").replace("{count}", &shown.to_string())
    }
}

fn show_matches(widgets: &FindWidgets, model: &gtk::SelectionModel, names: &[String]) -> Vec<u32> {
    let query = widgets.search.text();
    let row_store = model
        .downcast_ref::<gtk::MultiSelection>()
        .and_then(|selection| selection.model())
        .and_then(|model| model.downcast::<crate::ui::row_store::RowStore>().ok());
    let found = matching_rows(
        model.n_items(),
        |position| {
            let item = model.item(position)?.downcast::<RowObject>().ok()?;
            Some(
                row_store
                    .as_ref()
                    .and_then(|store| store.cells_for_search(position))
                    .unwrap_or_else(|| item.loaded_cells()),
            )
        },
        &query,
        MAX_MATCHES,
    );
    while let Some(row) = widgets.list.row_at_index(0) {
        widgets.list.remove(&row);
    }
    for hit in &found {
        let column = names.get(hit.column).map_or("", String::as_str);
        let label = format!("{} · {}: {}", hit.position + 1, column, preview(&hit.text));
        widgets.list.append(&result_row(&label));
    }
    widgets.list.select_row(widgets.list.row_at_index(0).as_ref());
    widgets.status.set_text(&status_text(&query, found.len()));
    found.iter().map(|found| found.position).collect()
}

fn close_on(dialog: &adw::Dialog) -> impl Fn() + 'static {
    let dialog = dialog.downgrade();
    move || {
        if let Some(dialog) = dialog.upgrade() {
            dialog.close();
        }
    }
}

fn present(view: &gtk::ColumnView, names: Rc<Vec<String>>) {
    let dialog = adw::Dialog::builder()
        .title(crate::tr!("Find in Loaded Rows"))
        .content_width(520)
        .content_height(460)
        .build();
    let widgets = Rc::new(build_widgets());
    let positions: Rc<std::cell::RefCell<Vec<u32>>> = Rc::default();
    widgets.search.connect_search_changed({
        let (view, widgets, positions) = (view.downgrade(), widgets.clone(), positions.clone());
        move |_| {
            if let Some(model) = view.upgrade().and_then(|view| view.model()) {
                *positions.borrow_mut() = show_matches(&widgets, &model, &names);
            }
        }
    });
    let close = close_on(&dialog);
    widgets.search.connect_stop_search(move |_| close());
    widgets.search.connect_activate({
        let list = widgets.list.clone();
        move |_| {
            if let Some(row) = list.selected_row() {
                row.activate();
            }
        }
    });
    let close = close_on(&dialog);
    let view_for_select = view.downgrade();
    widgets.list.connect_row_activated(move |_, row| {
        let position = usize::try_from(row.index())
            .ok()
            .and_then(|index| positions.borrow().get(index).copied());
        if let (Some(view), Some(position)) = (view_for_select.upgrade(), position) {
            select_and_scroll(&view, position);
        }
        close();
    });
    dialog.set_child(Some(&widgets.content));
    dialog.present(Some(view));
    widgets.search.grab_focus();
}

fn select_and_scroll(view: &gtk::ColumnView, position: u32) {
    let Some(model) = view.model().filter(|model| position < model.n_items()) else {
        return;
    };
    model.select_item(position, true);
    view.scroll_to(
        position,
        None::<&gtk::ColumnViewColumn>,
        gtk::ListScrollFlags::FOCUS | gtk::ListScrollFlags::SELECT,
        None,
    );
    view.grab_focus();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rows() -> Vec<Vec<Value>> {
        vec![
            vec![Value::Int(1), Value::Text("Alice Smith".into())],
            vec![Value::Int(2), Value::Null],
            vec![Value::Int(3), Value::Text("bob alice".into())],
            vec![Value::Int(4), Value::Text("carol".into())],
        ]
    }

    fn find(query: &str, limit: usize) -> Vec<(u32, usize)> {
        let rows = rows();
        matching_rows(
            rows.len() as u32,
            |p| {
                rows.get(p as usize)
                    .map(|cells| cells.iter().cloned().map(Some).collect())
            },
            query,
            limit,
        )
        .into_iter()
        .map(|hit| (hit.position, hit.column))
        .collect()
    }

    #[test]
    fn a_match_is_case_insensitive_and_reports_the_first_matching_column() {
        assert_eq!(find("ALICE", 10), vec![(0, 1), (2, 1)]);
        assert_eq!(find("3", 10), vec![(2, 0)]);
    }

    #[test]
    fn an_empty_query_matches_nothing() {
        assert!(find("", 10).is_empty());
        assert!(find("   ", 10).is_empty());
    }

    #[test]
    fn a_missing_projected_cell_is_not_a_search_match() {
        let found = matching_rows(1, |_| Some(vec![Some(Value::Int(1)), None]), "not fetched", 10);
        assert!(found.is_empty());
    }

    #[test]
    fn a_long_cell_remains_searchable_beyond_its_visible_preview() {
        let text = format!("{}needle", "x".repeat(9000));
        let result = std::sync::Arc::new(tablepro_core::QueryResult {
            columns: Vec::new(),
            rows: vec![vec![Value::Int(1), Value::Text(text)]],
            truncated: false,
        });
        let store = crate::ui::row_store::RowStore::from_shared_with_previews(result, vec![0]);

        let found = matching_rows(1, |position| store.cells_for_search(position), "needle", 10);
        assert_eq!(
            found.iter().map(|hit| (hit.position, hit.column)).collect::<Vec<_>>(),
            vec![(0, 1)]
        );
    }

    #[test]
    fn the_scan_stops_at_the_limit() {
        assert_eq!(find("a", 2), vec![(0, 1), (2, 1)]);
        assert_eq!(find("a", 1), vec![(0, 1)]);
    }

    #[test]
    fn a_long_cell_is_shown_as_one_short_line() {
        let shown = preview(&format!("first\nsecond {}", "x".repeat(200)));
        assert!(!shown.contains('\n'));
        assert_eq!(shown.chars().count(), PREVIEW_CHARS + 1);
        assert!(shown.ends_with('…'));
    }
}
