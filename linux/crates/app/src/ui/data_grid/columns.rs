use std::cell::Cell;
use std::rc::Rc;
use std::sync::Arc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, glib, pango};
use tablepro_core::Value;
use tablepro_core::column::ColumnKind;

use super::grid_cell::{GridCell, TextAttributes};
use super::server_sorter::ServerSorter;
use super::{DataGrid, GridRow, GridSorting, TrackedValues, client_sorter, grid_menu, row_number_column};
use crate::services::grid::{
    CellDisplay, ColumnLayout, GridColumn, LayoutSlot, Placement, default_width_chars, merge_order, number_width_chars,
    widest_text,
};

/// Rows sampled for a column's opening width.
const WIDTH_SAMPLE: usize = 200;
/// Cell padding Adwaita gives a data table's cell, both sides, and the
/// column separator.
const CELL_CHROME_PX: i32 = 13;
/// A resize step, in digits of the grid's font, so a step is the same
/// number of characters at any text size.
const STEP_DIGITS: i32 = 2;

/// What a column's cells read to draw a row. The column makes one and
/// every cell it builds shares it.
#[derive(Debug)]
pub struct ColumnPaint {
    pub column: GridColumn,
    pub tracked: TrackedValues,
    pub attributes: Rc<TextAttributes>,
    /// The column lines its values up on the last digit. An untyped column
    /// does once every value it holds is a number.
    pub numbers: Cell<bool>,
}

/// The grid's columns: what each one is and the view column that shows it.
#[derive(Debug, Default)]
pub struct ColumnSet {
    columns: Arc<[GridColumn]>,
    view_columns: Vec<gtk::ColumnViewColumn>,
    paints: Vec<Rc<ColumnPaint>>,
    row_numbers: Option<gtk::ColumnViewColumn>,
    sorting: Option<GridSorting>,
    /// The order, visibility and widths as the user left them.
    layout: ColumnLayout,
    /// The widths the grid gave columns itself, which the layout does not
    /// keep: a better guess from other rows should still reach them.
    auto_widths: std::collections::HashMap<usize, i32>,
    handlers: Vec<(glib::WeakRef<glib::Object>, glib::SignalHandlerId)>,
}

impl ColumnSet {
    pub fn columns(&self) -> Arc<[GridColumn]> {
        self.columns.clone()
    }

    pub fn view_column(&self, index: usize) -> Option<&gtk::ColumnViewColumn> {
        self.view_columns.get(index)
    }

    pub fn paint(&self, index: usize) -> Option<Rc<ColumnPaint>> {
        self.paints.get(index).cloned()
    }

    pub fn index_of(&self, view_column: &gtk::ColumnViewColumn) -> Option<usize> {
        self.view_columns.iter().position(|column| column == view_column)
    }

    pub fn row_numbers(&self) -> Option<&gtk::ColumnViewColumn> {
        self.row_numbers.as_ref()
    }

    pub fn layout(&self) -> &ColumnLayout {
        &self.layout
    }

    pub fn sorting(&self) -> GridSorting {
        self.sorting.unwrap_or(GridSorting::None)
    }

    pub(super) fn release(&mut self) {
        for (object, handler) in self.handlers.drain(..) {
            if let Some(object) = object.upgrade() {
                object.disconnect(handler);
            }
        }
        // GTK 4.22 leaks a reference to the column beside the focus column
        // when the view drops the focus column, so a column can outlive its
        // view; its factory must not keep the grid's cells alive with it.
        for column in self.view_columns.drain(..).chain(self.row_numbers.take()) {
            column.set_factory(None::<&gtk::ListItemFactory>);
        }
        self.paints.clear();
    }
}

impl DataGrid {
    pub(super) fn rebuild_columns(&self, columns: Arc<[GridColumn]>, sorting: GridSorting) {
        let view = self.column_view();
        let old_layout = self.imp().columns.borrow().layout.clone();
        let mut set = self.imp().columns.take();
        set.release();
        while let Some(column) = view.columns().item(0).and_downcast::<gtk::ColumnViewColumn>() {
            view.remove_column(&column);
        }
        let layout = match self.config().and_then(|config| config.layout.as_ref()) {
            Some(binding) => binding.load(),
            None if same_names(&old_layout, &columns) => old_layout,
            None => ColumnLayout::default(),
        };
        let tracked = self.tracked();
        let attributes = Rc::new(TextAttributes::new());
        let mut built = ColumnSet {
            columns: columns.clone(),
            sorting: Some(sorting),
            layout,
            ..ColumnSet::default()
        };
        for column in columns.iter() {
            let paint = Rc::new(ColumnPaint {
                column: column.clone(),
                tracked: tracked.clone(),
                attributes: attributes.clone(),
                numbers: Cell::new(column.display() == CellDisplay::Number),
            });
            built.view_columns.push(self.build_column(&paint, sorting));
            built.paints.push(paint);
        }
        built.row_numbers = Some(row_number_column::build(self));
        let names: Vec<&str> = columns.iter().map(|column| column.name.as_str()).collect();
        for placement in built.layout.arrange(&names) {
            let column = match placement {
                Placement::RowNumbers => built.row_numbers.clone(),
                Placement::Column { index, visible, width } => {
                    built.view_columns.get(index).cloned().inspect(|column| {
                        column.set_visible(visible);
                        if let Some(width) = width {
                            column.set_fixed_width(width);
                        }
                    })
                }
            };
            if let Some(column) = column {
                view.append_column(&column);
            }
        }
        self.imp().columns.replace(built);
        self.size_unsized_columns();
        self.watch_layout_changes();
        self.wire_sorting(sorting);
    }

    fn build_column(&self, paint: &Rc<ColumnPaint>, sorting: GridSorting) -> gtk::ColumnViewColumn {
        let factory = gtk::SignalListItemFactory::new();
        let setup_paint = paint.clone();
        factory.connect_setup(move |_, item| {
            let Some(cell) = item.downcast_ref::<gtk::ColumnViewCell>() else {
                return;
            };
            // Set through the property: under GTK 4.12 and later gtk-rs maps
            // `set_focusable` to the GtkListItem field the cell never reads.
            cell.set_property("focusable", true);
            let grid_cell = GridCell::new(setup_paint.clone());
            grid_cell.attach(cell);
            cell.set_child(Some(&grid_cell));
        });
        factory.connect_bind(|_, item| {
            let Some(cell) = item.downcast_ref::<gtk::ColumnViewCell>() else {
                return;
            };
            if let (Some(row), Some(grid_cell)) = (
                cell.item().and_downcast::<GridRow>(),
                cell.child().and_downcast::<GridCell>(),
            ) {
                grid_cell.bind(&row);
            }
        });
        factory.connect_unbind(|_, item| {
            if let Some(grid_cell) = item
                .downcast_ref::<gtk::ColumnViewCell>()
                .and_then(|cell| cell.child())
                .and_downcast::<GridCell>()
            {
                grid_cell.unbind();
            }
        });
        let column = &paint.column;
        let view_column = gtk::ColumnViewColumn::builder()
            .title(&column.name)
            .factory(&factory)
            .resizable(true)
            .build();
        view_column.set_id(Some(&format!("column-{}", column.index)));
        view_column.set_sorter(self.sorter_for(column, sorting).as_ref());
        view_column.set_header_menu(Some(&grid_menu::header_menu(column, sorting)));
        view_column
    }

    fn sorter_for(&self, column: &GridColumn, sorting: GridSorting) -> Option<gtk::Sorter> {
        if !column.sortable() {
            return None;
        }
        match sorting {
            GridSorting::Server { .. } => Some(ServerSorter::new().upcast()),
            GridSorting::Client => Some(client_sorter::column_sorter(column)),
            GridSorting::None => None,
        }
    }

    /// A column the layout gives no width opens at one from its type and
    /// the first rows, and keeps it while rows scroll by, since an
    /// automatic width measures every row GTK builds and shifts.
    fn size_unsized_columns(&self) {
        let widths = self.opening_widths();
        for (index, view_column, width) in widths {
            self.imp().columns.borrow_mut().auto_widths.insert(index, width);
            view_column.set_fixed_width(width);
        }
    }

    fn opening_widths(&self) -> Vec<(usize, gtk::ColumnViewColumn, i32)> {
        let set = self.imp().columns.borrow();
        let sample: Vec<Option<Arc<[Value]>>> = self.store().rows().take(WIDTH_SAMPLE).map(|row| row.cells()).collect();
        let metrics = self.column_view().pango_context().metrics(None, None);
        let char_px = pango::units_to_double(metrics.approximate_char_width());
        let mut widths = Vec::new();
        for (paint, view_column) in set.paints.iter().zip(&set.view_columns) {
            let index = paint.column.index;
            let auto = set.auto_widths.get(&index).copied();
            if view_column.fixed_width() > 0 && auto != Some(view_column.fixed_width()) {
                continue;
            }
            let values: Vec<&Value> = sample
                .iter()
                .filter_map(|cells| cells.as_deref().and_then(|cells| cells.get(index)))
                .collect();
            let chars = match paint.numbers.get() {
                true => number_width_chars(&paint.column, values.iter().copied()),
                false => default_width_chars(&paint.column, values.iter().copied()),
            };
            let estimate = (f64::from(chars) * char_px).ceil() as i32;
            // A number is never cut, and its digits in tabular figures run
            // wider than an average character.
            let text = match paint.numbers.get() {
                true => estimate.max(tabular_width(&self.column_view(), chars)),
                false => widest_text(&paint.column, values.iter().copied()).map_or(estimate, |widest| {
                    estimate.max(drawn_width(&self.column_view(), &widest))
                }),
            };
            let width = text + CELL_CHROME_PX;
            if auto.is_none_or(|auto| width > auto) {
                widths.push((index, view_column.clone(), width));
            }
        }
        widths
    }

    /// Rows came in: an untyped column may have turned out not to hold
    /// only numbers, and the row numbers may have grown a digit.
    pub(super) fn columns_took_rows(&self) {
        self.detect_untyped_numbers();
        self.size_unsized_columns();
        row_number_column::fit(self);
    }

    /// PostgreSQL results carry no type (ADR 0016), so such a column lines
    /// up by what it holds, as a spreadsheet does.
    fn detect_untyped_numbers(&self) {
        let set = self.imp().columns.borrow();
        let mut changed = false;
        for paint in &set.paints {
            if !matches!(paint.column.column_type.kind, ColumnKind::Other | ColumnKind::Variant) {
                continue;
            }
            let index = paint.column.index;
            let mut held = false;
            let all_numbers =
                self.store()
                    .rows()
                    .all(|row| match row.cells().and_then(|cells| cells.get(index).cloned()) {
                        Some(Value::Null) | None => true,
                        Some(value) => {
                            held = true;
                            is_number(&value)
                        }
                    });
            let numbers = held && all_numbers;
            changed |= paint.numbers.replace(numbers) != numbers;
        }
        drop(set);
        if changed {
            self.redraw();
        }
    }

    /// Save a drag in the header, a width and a hidden column the moment
    /// the user makes them.
    fn watch_layout_changes(&self) {
        let view = self.column_view();
        let mut handlers = Vec::new();
        let order = view.columns().connect_items_changed(glib::clone!(
            #[weak(rename_to = grid)]
            self,
            move |_, _, _, _| grid.columns_moved()
        ));
        handlers.push((view.columns().upcast::<glib::Object>().downgrade(), order));
        let set = self.imp().columns.borrow();
        for column in &set.view_columns {
            let width = column.connect_notify_local(
                Some("fixed-width"),
                glib::clone!(
                    #[weak(rename_to = grid)]
                    self,
                    move |_, _| grid.record_layout()
                ),
            );
            let visible = column.connect_notify_local(
                Some("visible"),
                glib::clone!(
                    #[weak(rename_to = grid)]
                    self,
                    move |_, _| grid.columns_moved()
                ),
            );
            for handler in [width, visible] {
                handlers.push((column.upcast_ref::<glib::Object>().downgrade(), handler));
            }
        }
        drop(set);
        self.imp().columns.borrow_mut().handlers.extend(handlers);
    }

    /// A column moved, went or came back: the layout keeps it, and a
    /// search counts only the columns on screen, in their order.
    fn columns_moved(&self) {
        self.record_layout();
        self.find_rows_changed();
    }

    /// Fold what the view shows into the stored layout. A column the rows
    /// lack this time keeps its place, width and hidden flag for when it
    /// is back.
    fn record_layout(&self) {
        let Ok(mut set) = self.imp().columns.try_borrow_mut() else {
            return;
        };
        let view = self.column_view();
        let mut layout = set.layout.clone();
        let mut shown_order = Vec::new();
        // A double click on a header's edge gives a column its automatic
        // width back, which the grid replaces with its own guess.
        let mut reset = Vec::new();
        for position in 0..view.columns().n_items() {
            let Some(column) = view.columns().item(position).and_downcast::<gtk::ColumnViewColumn>() else {
                continue;
            };
            if set.row_numbers.as_ref() == Some(&column) {
                shown_order.push(LayoutSlot::RowNumbers);
                continue;
            }
            let Some(index) = set.index_of(&column) else {
                continue;
            };
            let name = set.columns[index].name.clone();
            match column.is_visible() {
                true => layout.hidden.remove(&name),
                false => layout.hidden.insert(name.clone()),
            };
            let width = column.fixed_width();
            match width > 0 && set.auto_widths.get(&index) != Some(&width) {
                true => layout.widths.insert(name.clone(), width),
                false => layout.widths.remove(&name),
            };
            if width <= 0 {
                reset.push(index);
            }
            shown_order.push(LayoutSlot::Column(name));
        }
        layout.order = merge_order(&set.layout.order, shown_order);
        for index in &reset {
            set.auto_widths.remove(index);
        }
        let before = std::mem::replace(&mut set.layout, layout.clone());
        drop(set);
        if !reset.is_empty() {
            glib::idle_add_local_once(glib::clone!(
                #[weak(rename_to = grid)]
                self,
                move || grid.size_unsized_columns()
            ));
        }
        if layout != before
            && let Some(binding) = self.config().and_then(|config| config.layout.as_ref())
        {
            binding.save(&layout.rebased(&before, &binding.load()));
        }
    }

    /// The user gave the column a width, or took it back with `None`.
    pub(super) fn set_column_width(&self, index: usize, width: Option<i32>) {
        if let Some(column) = self.data_view_column(index) {
            column.set_fixed_width(width.unwrap_or(-1));
        }
    }

    pub(super) fn step_column(&self, index: usize, wider: bool) {
        let column = self.imp().columns.borrow().view_column(index).cloned();
        let Some(column) = column else {
            return;
        };
        let metrics = self.column_view().pango_context().metrics(None, None);
        let step = (pango::units_to_double(metrics.approximate_digit_width()) * f64::from(STEP_DIGITS)).ceil() as i32;
        let width = column.fixed_width();
        let width = match wider {
            true => width.max(0).saturating_add(step),
            // Narrow stops at one step, so the column the focus is in stays
            // on screen to widen again.
            false if width > step => (width - step).max(step),
            false => return,
        };
        self.set_column_width(index, Some(width));
    }

    /// The data columns on screen, in the order the user arranged them.
    pub(crate) fn shown_columns(&self) -> Vec<usize> {
        let set = self.imp().columns.borrow();
        let view = self.column_view();
        (0..view.columns().n_items())
            .filter_map(|position| view.columns().item(position).and_downcast::<gtk::ColumnViewColumn>())
            .filter(|column| column.is_visible())
            .filter_map(|column| set.index_of(&column))
            .collect()
    }

    pub(crate) fn data_view_column(&self, index: usize) -> Option<gtk::ColumnViewColumn> {
        self.imp().columns.borrow().view_column(index).cloned()
    }

    pub(crate) fn column_index(&self, view_column: &gtk::ColumnViewColumn) -> Option<usize> {
        self.imp().columns.borrow().index_of(view_column)
    }

    pub(crate) fn row_numbers_column(&self) -> Option<gtk::ColumnViewColumn> {
        self.imp().columns.borrow().row_numbers().cloned()
    }

    pub(crate) fn set_column_visible(&self, index: usize, visible: bool) {
        // The last column on screen stays: a grid of no columns has nothing
        // to focus and no header to bring one back from.
        if !visible && self.shown_columns() == [index] {
            self.column_view().error_bell();
            return;
        }
        if let Some(column) = self.data_view_column(index) {
            column.set_visible(visible);
        }
    }

    /// Every column back where the result has it, at its opening width,
    /// under the sort the headers show now.
    pub(crate) fn reset_layout(&self) {
        let sort = self.current_sort();
        let (columns, sorting) = {
            let mut set = self.imp().columns.borrow_mut();
            set.layout = ColumnLayout::default();
            (set.columns.clone(), set.sorting())
        };
        if let Some(binding) = self.config().and_then(|config| config.layout.as_ref()) {
            binding.save(&ColumnLayout::default());
        }
        let rows: Vec<_> = self.store().rows().map(|row| row.data()).collect();
        self.rebuild_columns(columns, sorting);
        self.apply_sort_quietly(sort);
        self.store().replace(rows);
        self.columns_took_rows();
    }

    fn wire_sorting(&self, sorting: GridSorting) {
        match sorting {
            GridSorting::Server { initial } => self.apply_sort_quietly(initial),
            GridSorting::Client => {}
            GridSorting::None => return,
        }
        let Some(sorter) = self.column_view().sorter().and_downcast::<gtk::ColumnViewSorter>() else {
            return;
        };
        let handler = sorter.connect_changed(glib::clone!(
            #[weak(rename_to = grid)]
            self,
            move |sorter, _| grid.sort_changed(sorter)
        ));
        self.imp()
            .columns
            .borrow_mut()
            .handlers
            .push((sorter.upcast_ref::<glib::Object>().downgrade(), handler));
        // New columns bring new sorters, and the rows must not keep one
        // of a column that is gone.
        self.sort_shown_rows(&sorter);
    }

    /// A header click or the menu changed the sort: a server grid asks the
    /// host for its rows in that order.
    fn sort_changed(&self, sorter: &gtk::ColumnViewSorter) {
        self.refresh_actions();
        self.sort_shown_rows(sorter);
        if self.imp().quiet_sort.get() {
            return;
        }
        let sort = self.sort_of(sorter);
        self.announce_sort(sort);
        if matches!(self.imp().columns.borrow().sorting(), GridSorting::Server { .. }) {
            self.request(super::GridRequest::Sort(sort));
        }
    }

    /// A grid that sorts its own rows sorts them with the header column's
    /// own sorter, which collates each row once, and shows them last first
    /// for a descending sort.
    fn sort_shown_rows(&self, sorter: &gtk::ColumnViewSorter) {
        let imp = self.imp();
        let (Some(sorted), Some(shown)) = (imp.sort_model.get(), imp.shown.get()) else {
            return;
        };
        let column = sorter.primary_sort_column();
        let by = column.as_ref().and_then(gtk::ColumnViewColumn::sorter);
        if sorted.sorter() != by {
            sorted.set_sorter(by.as_ref());
        }
        shown.set_reversed(column.is_some() && sorter.primary_sort_order() == gtk::SortType::Descending);
    }

    pub(super) fn apply_sort_quietly(&self, sort: Option<(usize, bool)>) {
        let quiet = &self.imp().quiet_sort;
        quiet.set(true);
        self.sort_by(sort);
        quiet.set(false);
    }

    /// Sort as a header click does: the server or the grid sorts, and the
    /// header shows it.
    pub(crate) fn sort_by(&self, sort: Option<(usize, bool)>) {
        let view = self.column_view();
        match sort.and_then(|(index, ascending)| Some((self.data_view_column(index)?, ascending))) {
            Some((column, ascending)) => {
                let order = match ascending {
                    true => gtk::SortType::Ascending,
                    false => gtk::SortType::Descending,
                };
                view.sort_by_column(Some(&column), order);
            }
            None => view.sort_by_column(None::<&gtk::ColumnViewColumn>, gtk::SortType::Ascending),
        }
    }

    /// The data column the headers sort by and whether ascending.
    fn current_sort(&self) -> Option<(usize, bool)> {
        let sorter = self.column_view().sorter().and_downcast::<gtk::ColumnViewSorter>()?;
        self.sort_of(&sorter)
    }

    fn sort_of(&self, sorter: &gtk::ColumnViewSorter) -> Option<(usize, bool)> {
        let column = sorter.primary_sort_column()?;
        let index = self.column_index(&column)?;
        Some((index, sorter.primary_sort_order() == gtk::SortType::Ascending))
    }

    pub(crate) fn is_sorted(&self) -> bool {
        self.column_view()
            .sorter()
            .and_downcast::<gtk::ColumnViewSorter>()
            .is_some_and(|sorter| sorter.primary_sort_column().is_some())
    }

    /// The header's arrow says nothing to a screen reader on Linux.
    fn announce_sort(&self, sort: Option<(usize, bool)>) {
        let text = match sort {
            Some((index, ascending)) => {
                let Some(name) = self.grid_columns().get(index).map(|column| column.name.clone()) else {
                    return;
                };
                match ascending {
                    true => crate::i18n::gettext_f("Sorted by {column}, ascending", &[("column", &name)]),
                    false => crate::i18n::gettext_f("Sorted by {column}, descending", &[("column", &name)]),
                }
            }
            None => crate::i18n::gettext("Sort cleared"),
        };
        crate::ui::a11y::announce(&self.column_view(), &text, gtk::AccessibleAnnouncementPriority::Medium);
    }

    pub(crate) fn shown_rows(&self) -> Vec<GridRow> {
        let model = self.selection();
        (0..model.n_items())
            .filter_map(|position| model.item(position).and_downcast::<GridRow>())
            .collect()
    }

    pub(crate) fn view_position(&self, row: &GridRow) -> Option<u32> {
        match self.imp().shown.get() {
            Some(shown) => {
                (0..shown.n_items()).find(|position| shown.item(*position).as_ref() == Some(row.upcast_ref()))
            }
            None => self.store().position_of(row),
        }
    }
}

fn same_names(layout: &ColumnLayout, columns: &[GridColumn]) -> bool {
    let names: Vec<&str> = layout
        .order
        .iter()
        .filter_map(|slot| match slot {
            LayoutSlot::Column(name) => Some(name.as_str()),
            LayoutSlot::RowNumbers => None,
        })
        .collect();
    names.len() == columns.len() && names.iter().zip(columns).all(|(name, column)| *name == column.name)
}

/// How wide `chars` digits are in the tabular figures libadwaita's
/// `numeric` class draws.
fn tabular_width(widget: &impl IsA<gtk::Widget>, chars: u32) -> i32 {
    let layout = widget.create_pango_layout(Some(&"0".repeat(usize::try_from(chars).unwrap_or_default())));
    let tabular = pango::AttrList::new();
    tabular.insert(pango::AttrFontFeatures::new("tnum"));
    layout.set_attributes(Some(&tabular));
    layout.pixel_size().0
}

fn drawn_width(widget: &impl IsA<gtk::Widget>, text: &str) -> i32 {
    widget.create_pango_layout(Some(text)).pixel_size().0
}

fn is_number(value: &Value) -> bool {
    match value {
        Value::Int(_)
        | Value::UInt(_)
        | Value::WideInt(_)
        | Value::Float32(_)
        | Value::Float64(_)
        | Value::Decimal(_) => true,
        Value::Text(text) => text.parse::<f64>().is_ok(),
        Value::Other(other) => other.text.parse::<f64>().is_ok(),
        _ => false,
    }
}
