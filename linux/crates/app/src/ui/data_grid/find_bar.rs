use std::cell::{Cell, RefCell};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, gdk, glib};

use super::{DataGrid, GridRow, PinnedRow, grid_actions};
use crate::i18n::{gettext, gettext_f};
use crate::services::grid::{FindMatch, RowSnapshot, find_matches};

/// The find bar's search over the rows the grid holds.
#[derive(Debug, Default)]
pub struct FindState {
    found: RefCell<Found>,
    /// Set to stop the search that is running once a newer one starts.
    running: RefCell<Option<Arc<AtomicBool>>>,
    /// Counts searches, so an answer to an older one is dropped.
    searches: Cell<u64>,
    /// The search running was typed, so its answer moves to a match.
    moving: Cell<bool>,
    /// Where the search stands: the cell focused when the bar opened, then
    /// each match it moved to. Escape puts the focus there.
    cursor: RefCell<Option<(PinnedRow, Option<usize>)>>,
    rerun_queued: Cell<bool>,
}

#[derive(Debug, Default)]
struct Found {
    /// The rows searched, in the order the grid showed them.
    rows: Vec<PinnedRow>,
    matches: Vec<FindMatch>,
    current: Option<usize>,
    /// A search for the entry's text has answered.
    answered: bool,
}

impl Found {
    fn label(&self) -> String {
        if !self.answered {
            return String::new();
        }
        match self.matches.len() {
            0 => gettext("No results"),
            count => gettext_f(
                "{position} of {count}",
                &[
                    ("position", &self.current.map_or(0, |index| index + 1).to_string()),
                    ("count", &count.to_string()),
                ],
            ),
        }
    }

    /// The cursor's row among the rows searched, and its column.
    fn locate(&self, cursor: Option<&(PinnedRow, Option<usize>)>) -> Option<(usize, Option<usize>)> {
        let (pin, column) = cursor?;
        let row = pin.get()?;
        let at = self.rows.iter().position(|searched| searched.get() == Some(row))?;
        Some((at, *column))
    }
}

/// The first match in `row` or below it, wrapping to the first of all.
fn first_from(matches: &[FindMatch], row: usize) -> usize {
    matches.iter().position(|found| found.row >= row).unwrap_or(0)
}

pub fn install(grid: &DataGrid) {
    let imp = grid.imp();
    let finds = grid.config().is_some_and(|config| config.find);
    // The table tab keeps Ctrl+F for its filter, so its grid has no bar.
    imp.search_bar.set_visible(finds);
    if !finds {
        return;
    }
    let entry = imp.search_entry.get();
    imp.search_bar.connect_entry(&entry);
    for button in [imp.find_previous.get(), imp.find_next.get()] {
        if let Some(action) = button.action_name() {
            crate::ui::a11y::announce_key_shortcuts(&button, &action);
        }
    }
    entry.connect_search_changed(glib::clone!(
        #[weak]
        grid,
        move |entry| grid.start_search(entry.text().to_string(), true)
    ));
    entry.connect_activate(glib::clone!(
        #[weak]
        grid,
        move |_| grid.find_step(true)
    ));
    entry.connect_next_match(glib::clone!(
        #[weak]
        grid,
        move |_| grid.find_step(true)
    ));
    entry.connect_previous_match(glib::clone!(
        #[weak]
        grid,
        move |_| grid.find_step(false)
    ));
    entry.add_controller(shift_enter(grid));
    imp.search_bar.connect_search_mode_enabled_notify(glib::clone!(
        #[weak]
        grid,
        move |bar| {
            if !bar.is_search_mode() {
                grid.find_closed();
            }
        }
    ));
    // A client sort reorders the rows without writing them.
    grid.selection().connect_items_changed(glib::clone!(
        #[weak]
        grid,
        move |_, _, _, _| grid.find_rows_changed()
    ));
}

pub fn install_actions(grid: &DataGrid) {
    grid_actions::add(grid, "find", DataGrid::open_find);
    grid_actions::add(grid, "find-next", |grid| grid.find_step(true));
    grid_actions::add(grid, "find-previous", |grid| grid.find_step(false));
}

pub fn refresh_actions(grid: &DataGrid) {
    let finds = grid.config().is_some_and(|config| config.find);
    let matches = finds && !grid.imp().find.found.borrow().matches.is_empty();
    grid_actions::enable(grid, "find", finds);
    grid_actions::enable(grid, "find-next", matches);
    grid_actions::enable(grid, "find-previous", matches);
}

/// Shift+Enter goes back, as Shift+Ctrl+G does; GtkText binds Enter alone.
fn shift_enter(grid: &DataGrid) -> gtk::EventControllerKey {
    let keys = gtk::EventControllerKey::new();
    keys.set_propagation_phase(gtk::PropagationPhase::Capture);
    let weak = grid.downgrade();
    keys.connect_key_pressed(move |_, keyval, _, state| {
        let enter = matches!(keyval, gdk::Key::Return | gdk::Key::KP_Enter | gdk::Key::ISO_Enter);
        let shift_only = state & gtk::accelerator_get_default_mod_mask() == gdk::ModifierType::SHIFT_MASK;
        match (enter && shift_only, weak.upgrade()) {
            (true, Some(grid)) => {
                grid.find_step(false);
                glib::Propagation::Stop
            }
            _ => glib::Propagation::Proceed,
        }
    });
    keys
}

impl DataGrid {
    fn open_find(&self) {
        let imp = self.imp();
        if !imp.search_bar.is_search_mode() {
            imp.find.cursor.replace(self.find_start());
            imp.search_bar.set_search_mode(true);
        }
        imp.search_entry.grab_focus();
        imp.search_entry.select_region(0, -1);
    }

    /// Where a new search counts from: the focused cell, else the first
    /// selected row.
    fn find_start(&self) -> Option<(PinnedRow, Option<usize>)> {
        if let Some(cell) = self.focused_cell()
            && let Some(row) = cell.row()
        {
            return Some((row.pin(), Some(cell.column())));
        }
        self.selected_rows().first().map(|row| (row.pin(), None))
    }

    /// Search the rows as they are shown now, off the GTK thread. A newer
    /// search stops this one; `moving` goes to its first match once it
    /// answers.
    fn start_search(&self, query: String, moving: bool) {
        let state = &self.imp().find;
        if let Some(running) = state.running.take() {
            running.store(true, Ordering::Relaxed);
        }
        let search = state.searches.get().wrapping_add(1);
        state.searches.set(search);
        state.moving.set(moving);
        let Some(tasks) = self
            .config()
            .map(|config| config.tasks.clone())
            .filter(|_| !query.is_empty())
        else {
            state.found.replace(Found::default());
            self.show_find_status();
            refresh_actions(self);
            return;
        };
        let shown = self.shown_rows();
        let tracked = self.tracked();
        let snapshots: Vec<RowSnapshot> = shown.iter().map(|row| tracked.snapshot(row)).collect();
        let rows: Vec<PinnedRow> = shown.iter().map(GridRow::pin).collect();
        let columns = self.grid_columns();
        let order = self.shown_columns();
        let cancelled = Arc::new(AtomicBool::new(false));
        state.running.replace(Some(cancelled.clone()));
        let grid = self.downgrade();
        glib::spawn_future_local(async move {
            let answer = tasks
                .spawn_blocking_task(move || {
                    find_matches(&query, &snapshots, &columns, &order, &|| {
                        cancelled.load(Ordering::Relaxed)
                    })
                })
                .await;
            let Some(grid) = grid.upgrade() else {
                return;
            };
            let state = &grid.imp().find;
            if state.searches.get() != search {
                return;
            }
            state.running.take();
            let moving = state.moving.replace(false);
            match answer {
                Ok(matches) => grid.take_matches(rows, matches, moving),
                Err(failure) => tracing::warn!(%failure, "the rows could not be searched"),
            }
        });
    }

    /// A typed search goes to the first match from the cursor's row down;
    /// a search again over changed rows stays on the match it was on.
    fn take_matches(&self, rows: Vec<PinnedRow>, matches: Vec<FindMatch>, moving: bool) {
        let state = &self.imp().find;
        let mut found = Found {
            rows,
            matches,
            current: None,
            answered: true,
        };
        let cursor = found.locate(state.cursor.borrow().as_ref());
        found.current = match moving {
            true => (!found.matches.is_empty()).then(|| first_from(&found.matches, cursor.map_or(0, |(row, _)| row))),
            false => cursor.and_then(|(row, column)| {
                found
                    .matches
                    .iter()
                    .position(|hit| hit.row == row && Some(hit.column) == column)
            }),
        };
        let current = found.current;
        state.found.replace(found);
        if moving && let Some(index) = current {
            self.visit_match(index);
        }
        self.show_find_status();
        refresh_actions(self);
    }

    fn find_step(&self, forward: bool) {
        let next = {
            let state = &self.imp().find;
            let found = state.found.borrow();
            let count = found.matches.len();
            if count == 0 {
                return;
            }
            let from = match found.current {
                Some(index) => index,
                // Off every match: the first one from the cursor's row down
                // is the next, the one before it the previous.
                None => {
                    let row = found.locate(state.cursor.borrow().as_ref()).map_or(0, |(row, _)| row);
                    let first = first_from(&found.matches, row);
                    match forward {
                        true => (first + count - 1) % count,
                        false => first,
                    }
                }
            };
            match forward {
                true => (from + 1) % count,
                false => (from + count - 1) % count,
            }
        };
        self.visit_match(next);
        self.show_find_status();
    }

    /// Select the match's row and mark its cell as the one the grid
    /// focuses next, leaving the focus where it is.
    fn visit_match(&self, index: usize) {
        let state = &self.imp().find;
        let target = {
            let found = state.found.borrow();
            found
                .matches
                .get(index)
                .and_then(|hit| Some((found.rows.get(hit.row)?.clone(), hit.row, hit.column)))
        };
        let Some((pin, searched_at, column)) = target else {
            return;
        };
        // A slot that holds another row now has a search again on its way.
        let Some(row) = pin.get().cloned() else {
            return;
        };
        let model = self.selection();
        let position = u32::try_from(searched_at)
            .ok()
            .filter(|at| model.item(*at).as_ref() == Some(row.upcast_ref()))
            .or_else(|| self.view_position(&row));
        let Some(position) = position else {
            return;
        };
        state.found.borrow_mut().current = Some(index);
        state.cursor.replace(Some((pin, Some(column))));
        let view_column = self.data_view_column(column).filter(|column| column.is_visible());
        self.column_view().scroll_to(
            position,
            view_column.as_ref(),
            gtk::ListScrollFlags::FOCUS | gtk::ListScrollFlags::SELECT,
            None,
        );
    }

    fn show_find_status(&self) {
        let imp = self.imp();
        let text = imp.find.found.borrow().label();
        crate::ui::a11y::show_status(&imp.match_label, &text);
    }

    /// Only Escape and the bar's close button hide it, both from inside
    /// the bar, so the focus goes back to the rows, on the match.
    fn find_closed(&self) {
        let cursor = self.imp().find.cursor.take();
        if !self.is_mapped() {
            return;
        }
        let at = cursor.and_then(|(pin, column)| {
            let row = pin.get()?.clone();
            Some((self.view_position(&row)?, column))
        });
        match at {
            Some((position, Some(column))) if self.focus_cell(position, column).is_some() => {}
            Some((position, _)) => {
                self.column_view()
                    .scroll_to(position, None, gtk::ListScrollFlags::FOCUS, None);
                self.focus_rows();
            }
            None => {
                self.focus_rows();
            }
        }
    }

    /// Search the rows again for the text in the bar, once the rows the
    /// last search read are no longer the ones shown.
    pub(crate) fn find_rows_changed(&self) {
        let imp = self.imp();
        if !imp.search_bar.is_search_mode() || imp.search_entry.text().is_empty() || imp.find.rerun_queued.replace(true)
        {
            return;
        }
        let grid = self.downgrade();
        glib::idle_add_local_once(move || {
            let Some(grid) = grid.upgrade() else {
                return;
            };
            let imp = grid.imp();
            imp.find.rerun_queued.set(false);
            grid.start_search(imp.search_entry.text().to_string(), imp.find.moving.get());
        });
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::rc::Rc;

    use gtk4::prelude::*;
    use gtk4::subclass::prelude::*;
    use gtk4::{self as gtk, gdk};
    use tablepro_core::Value;

    use super::super::test_grid::{Grid, GridSpec, WAIT, focus_in_grid, named, results};
    use crate::test_support::{KeyInjector, wait_until};

    fn text(value: &str) -> Value {
        Value::Text(value.to_owned())
    }

    fn row(id: i64, fruit: &str, note: &str) -> Vec<Value> {
        vec![Value::Int(id), text(fruit), text(note)]
    }

    fn spec(find: bool) -> GridSpec {
        GridSpec {
            find,
            ..GridSpec::results(vec![
                named("id", "integer", false),
                named("fruit", "text", false),
                named("note", "text", false),
            ])
        }
    }

    /// "apple" is in row 1's fruit, row 2's note, and both of row 3's.
    fn orchard() -> Grid {
        Grid::build(
            spec(true),
            results(&[
                row(1, "apple", "-"),
                row(2, "pear", "apple tart"),
                row(3, "apple pie", "green apple"),
            ]),
        )
    }

    fn label(grid: &Grid) -> String {
        grid.grid.imp().match_label.label().to_string()
    }

    fn wait_for_label(grid: &Grid, expected: &str) {
        wait_until(WAIT, || label(grid) == expected)
            .unwrap_or_else(|_| panic!("the count reads {expected:?}, not {:?}", label(grid)));
    }

    fn id_of(cells: &[Value]) -> Option<i64> {
        match cells.first()? {
            Value::Int(id) => Some(*id),
            _ => None,
        }
    }

    /// The row id and the column of the match the grid is on.
    fn on_match(grid: &Grid) -> Option<(i64, usize)> {
        let cursor = grid.grid.imp().find.cursor.borrow();
        let (pin, column) = cursor.as_ref()?;
        Some((id_of(&pin.get()?.cells()?)?, (*column)?))
    }

    fn selected_ids(grid: &Grid) -> Vec<i64> {
        grid.grid
            .selected_rows()
            .iter()
            .filter_map(|row| id_of(&row.cells()?))
            .collect()
    }

    fn search(grid: &Grid, query: &str) {
        grid.activate("find");
        grid.grid.imp().search_entry.set_text(query);
    }

    #[gtk4::test]
    fn hiding_a_column_takes_its_matches_out_of_the_count() {
        let grid = orchard();
        search(&grid, "apple");
        wait_for_label(&grid, "1 of 4");

        grid.grid.set_column_visible(2, false);

        wait_for_label(&grid, "1 of 2");
    }

    #[gtk4::test]
    fn matches_go_along_the_columns_on_screen_and_next_and_previous_wrap() {
        let grid = orchard();
        let note = grid.grid.data_view_column(2).expect("the note column");
        grid.grid.column_view().insert_column(1, &note);

        search(&grid, "apple");

        wait_for_label(&grid, "1 of 4");
        assert_eq!(on_match(&grid), Some((1, 1)));
        assert_eq!(selected_ids(&grid), [1], "the match's row is selected");
        assert!(
            crate::ui::a11y::holds_focus(&grid.grid.imp().search_entry.get()),
            "the entry keeps the focus"
        );
        let mut visited = Vec::new();
        for _ in 0..4 {
            grid.activate("find-next");
            visited.push((on_match(&grid), label(&grid)));
        }
        assert_eq!(
            visited,
            [
                (Some((2, 2)), "2 of 4".to_owned()),
                (Some((3, 2)), "3 of 4".to_owned()),
                (Some((3, 1)), "4 of 4".to_owned()),
                (Some((1, 1)), "1 of 4".to_owned()),
            ],
            "the note column comes first on screen, and Next wraps"
        );
        grid.activate("find-previous");
        assert_eq!((on_match(&grid), label(&grid)), (Some((3, 1)), "4 of 4".to_owned()));
        assert_eq!(selected_ids(&grid), [3]);
    }

    #[gtk4::test]
    fn the_entrys_keys_move_between_matches() {
        let grid = orchard();
        search(&grid, "apple");
        wait_for_label(&grid, "1 of 4");
        let entry = grid.grid.imp().search_entry.get();

        entry.emit_by_name::<()>("activate", &[]);
        assert_eq!(on_match(&grid), Some((2, 2)), "Enter goes to the next match");
        entry.emit_by_name::<()>("next-match", &[]);
        assert_eq!(on_match(&grid), Some((3, 1)), "Ctrl+G goes to the next match");
        entry.emit_by_name::<()>("previous-match", &[]);
        assert_eq!(on_match(&grid), Some((2, 2)), "Shift+Ctrl+G goes back");
    }

    #[gtk4::test]
    fn the_first_match_is_at_or_below_the_focused_row() {
        let grid = orchard();
        grid.focus(1, 1);

        search(&grid, "apple");

        wait_for_label(&grid, "2 of 4");
        assert_eq!(on_match(&grid), Some((2, 2)));
        grid.grid.imp().search_entry.set_text("nothing like it");
        wait_for_label(&grid, "No results");
        assert!(!grid.is_enabled("find-next") && !grid.is_enabled("find-previous"));
    }

    #[gtk4::test]
    fn a_new_query_stops_the_search_still_running() {
        let rows: Vec<Vec<Value>> = (0..5_000).map(|id| row(id, &format!("row {id}"), "")).collect();
        let grid = orchard();
        grid.grid.replace_rows(results(&rows), 0);
        grid.activate("find");

        grid.grid.start_search("row".to_owned(), true);
        let first = grid
            .grid
            .imp()
            .find
            .running
            .borrow()
            .clone()
            .expect("the first search runs");
        grid.grid.start_search("row 42".to_owned(), true);

        assert!(
            first.load(std::sync::atomic::Ordering::Relaxed),
            "the older search was told to stop"
        );
        // row 42, rows 420 to 429 and rows 4200 to 4299.
        wait_for_label(&grid, "1 of 111");
        assert_eq!(grid.grid.imp().find.found.borrow().matches.len(), 111);
        assert_eq!(on_match(&grid), Some((42, 1)));
    }

    #[gtk4::test]
    fn rows_that_change_are_searched_again() {
        let grid = orchard();
        search(&grid, "apple");
        wait_for_label(&grid, "1 of 4");

        grid.grid.append_rows(results(&[row(4, "crab apple", "-")]));

        wait_for_label(&grid, "1 of 5");
        assert_eq!(on_match(&grid), Some((1, 1)), "the search stays on its match");
        grid.grid
            .replace_rows(results(&[row(5, "apple", "-"), row(6, "apple", "-")]), 0);
        wait_for_label(&grid, "0 of 2");
        grid.activate("find-next");
        assert_eq!((on_match(&grid), label(&grid)), (Some((5, 1)), "1 of 2".to_owned()));
    }

    #[gtk4::test]
    fn without_find_the_bar_never_shows_and_ctrl_f_goes_on() {
        let grid = Grid::build(spec(false), results(&[row(1, "apple", "-")]));
        let heard = Rc::new(Cell::new(false));
        let outer = gtk::ShortcutController::new();
        let flag = heard.clone();
        outer.add_shortcut(gtk::Shortcut::new(
            gtk::ShortcutTrigger::parse_string("<Primary>f"),
            Some(gtk::CallbackAction::new(move |_, _| {
                flag.set(true);
                gtk::glib::Propagation::Stop
            })),
        ));
        grid.window.add_controller(outer);
        KeyInjector::focus_only(&grid.window);
        grid.focus(0, 1);
        let keys = KeyInjector::connect().expect("an X11 display");

        keys.press(gdk::Key::f, gdk::ModifierType::CONTROL_MASK)
            .expect("the key press");

        wait_until(WAIT, || heard.get()).expect("Ctrl+F reaches the host");
        let bar = grid.grid.imp().search_bar.get();
        assert!(!bar.is_visible() && !bar.is_search_mode());
        assert!(!grid.is_enabled("find") && !grid.is_enabled("find-next") && !grid.is_enabled("find-previous"));
    }

    #[gtk4::test]
    fn the_keys_search_and_escape_returns_the_focus_to_the_match() {
        let grid = orchard();
        KeyInjector::focus_only(&grid.window);
        grid.focus(0, 1);
        let keys = KeyInjector::connect().expect("an X11 display");
        let entry = grid.grid.imp().search_entry.get();

        keys.press(gdk::Key::f, gdk::ModifierType::CONTROL_MASK)
            .expect("the key press");
        wait_until(WAIT, || crate::ui::a11y::holds_focus(&entry)).expect("Ctrl+F focuses the entry");
        entry.set_text("apple");
        wait_for_label(&grid, "1 of 4");
        keys.press(gdk::Key::Return, gdk::ModifierType::empty())
            .expect("the key press");
        wait_for_label(&grid, "2 of 4");
        keys.press(gdk::Key::Return, gdk::ModifierType::SHIFT_MASK)
            .expect("the key press");
        wait_for_label(&grid, "1 of 4");
        keys.press(gdk::Key::g, gdk::ModifierType::CONTROL_MASK)
            .expect("the key press");
        wait_for_label(&grid, "2 of 4");

        keys.press(gdk::Key::Escape, gdk::ModifierType::empty())
            .expect("the key press");

        wait_until(WAIT, || !grid.grid.imp().search_bar.is_search_mode()).expect("Escape hides the bar");
        wait_until(WAIT, || focus_in_grid(&grid)).expect("the focus is back in the rows");
        let focused = grid.focused_cell().expect("a focused cell");
        assert_eq!((focused.position(), focused.column()), (Some(1), 2), "on row 2's note");
    }
}
