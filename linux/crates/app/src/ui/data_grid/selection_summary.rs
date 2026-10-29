use std::cell::{Cell, OnceCell, RefCell};
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, glib};

use super::DataGrid;
use crate::i18n::{gettext, gettext_f};
use crate::services::grid::{RowSnapshot, SelectionSummary, SummaryRule, summarize};
use crate::ui::format::{format_decimal, format_thousands};
use crate::ui::icons;

/// A summary of one row says no more than its cell.
const MIN_ROWS: usize = 2;

#[derive(Default)]
pub struct SummaryState {
    readout: OnceCell<Readout>,
    /// The last data column a cell had the focus in. It stays while the
    /// focus is in the readout's popover or the detail pane.
    column: Cell<Option<usize>>,
    queued: Cell<bool>,
    /// Counts runs, so an answer to an older one is dropped.
    runs: Cell<u64>,
    running: RefCell<Option<Arc<AtomicBool>>>,
}

impl SummaryState {
    pub(super) fn forget_column(&self) {
        self.column.set(None);
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Shown {
    column: String,
    summary: SelectionSummary,
}

/// A menu button in the host's bottom bar whose popover lists every
/// figure with a Copy button. The revealer keeps the bar's height while
/// it is hidden.
struct Readout {
    revealer: gtk::Revealer,
    button: gtk::MenuButton,
    heading: gtk::Label,
    separator: gtk::Separator,
    figures: Vec<FigureRow>,
    shown: RefCell<Option<Shown>>,
}

impl Readout {
    fn new(grid: &DataGrid) -> Self {
        let heading = gtk::Label::builder()
            .xalign(0.0)
            .ellipsize(gtk::pango::EllipsizeMode::End)
            .build();
        heading.add_css_class("heading");
        let table = gtk::Grid::builder().row_spacing(4).column_spacing(12).build();
        let separator = gtk::Separator::new(gtk::Orientation::Horizontal);
        let mut figures = Vec::with_capacity(Figure::ALL.len());
        let mut line = 0;
        for figure in Figure::ALL {
            if figure == Figure::Sum {
                table.attach(&separator, 0, line, 3, 1);
                line += 1;
            }
            let row = FigureRow::new(grid, figure);
            table.attach(&row.title, 0, line, 1, 1);
            table.attach(&row.value, 1, line, 1, 1);
            table.attach(&row.copy, 2, line, 1, 1);
            figures.push(row);
            line += 1;
        }
        let content = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(8)
            .margin_top(6)
            .margin_bottom(6)
            .margin_start(6)
            .margin_end(6)
            .build();
        content.append(&heading);
        content.append(&table);
        let button = gtk::MenuButton::builder()
            .popover(&gtk::Popover::builder().child(&content).build())
            .direction(gtk::ArrowType::Up)
            .can_shrink(true)
            .build();
        button.add_css_class("flat");
        button.add_css_class("caption");
        button.add_css_class("numeric");
        let revealer = gtk::Revealer::builder()
            .transition_type(gtk::RevealerTransitionType::SlideRight)
            .child(&button)
            .build();
        Self {
            revealer,
            button,
            heading,
            separator,
            figures,
            shown: RefCell::default(),
        }
    }

    /// While a run is out, Copy would take figures of rows no longer
    /// selected.
    fn set_current(&self, current: bool) {
        for row in &self.figures {
            row.copy.set_sensitive(current);
        }
    }

    fn show(&self, shown: Option<Shown>) {
        self.set_current(true);
        if *self.shown.borrow() == shown {
            return;
        }
        match &shown {
            Some(shown) => {
                let sentence = sentence(&shown.summary);
                self.button.set_label(&sentence);
                // The label ellipsizes in a narrow bar; the tooltip keeps every digit.
                self.button.set_tooltip_text(Some(&sentence));
                self.heading.set_label(&shown.column);
                for row in &self.figures {
                    row.show(row.figure.of(&shown.summary));
                }
                self.separator.set_visible(shown.summary.numbers.is_some());
            }
            None => self.button.popdown(),
        }
        self.revealer.set_reveal_child(shown.is_some());
        self.shown.replace(shown);
    }
}

fn sentence(summary: &SelectionSummary) -> String {
    let count = format_thousands(summary.value_count);
    match &summary.numbers {
        Some(numbers) => gettext_f(
            "Sum {sum}, Average {average}, Count {count}",
            &[
                ("sum", &format_decimal(&numbers.sum)),
                ("average", &format_decimal(&numbers.average)),
                ("count", &count),
            ],
        ),
        None => gettext_f("Count {count}", &[("count", &count)]),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Figure {
    Count,
    Numbers,
    Empty,
    NotANumber,
    Sum,
    Average,
    Minimum,
    Maximum,
}

impl Figure {
    const ALL: [Self; 8] = [
        Self::Count,
        Self::Numbers,
        Self::Empty,
        Self::NotANumber,
        Self::Sum,
        Self::Average,
        Self::Minimum,
        Self::Maximum,
    ];

    fn title(self) -> String {
        match self {
            Self::Count => gettext("Count"),
            // Translators: how many of the summed cells hold a number.
            Self::Numbers => gettext("Numbers"),
            Self::Empty => gettext("Empty"),
            Self::NotANumber => gettext("Not a Number"),
            Self::Sum => gettext("Sum"),
            Self::Average => gettext("Average"),
            Self::Minimum => gettext("Minimum"),
            Self::Maximum => gettext("Maximum"),
        }
    }

    fn copy_title(self) -> String {
        match self {
            Self::Count => gettext("Copy Count"),
            Self::Numbers => gettext("Copy Number Count"),
            Self::Empty => gettext("Copy Empty Count"),
            Self::NotANumber => gettext("Copy Not a Number Count"),
            Self::Sum => gettext("Copy Sum"),
            Self::Average => gettext("Copy Average"),
            Self::Minimum => gettext("Copy Minimum"),
            Self::Maximum => gettext("Copy Maximum"),
        }
    }

    /// The figure as the locale writes it and as Copy puts it on the
    /// clipboard, when the summary has it.
    fn of(self, summary: &SelectionSummary) -> Option<(String, String)> {
        let count = |n: u64| (format_thousands(n), n.to_string());
        let number = |plain: &String| (format_decimal(plain), plain.clone());
        let numbers = summary.numbers.as_ref();
        match self {
            Self::Count => Some(count(summary.value_count)),
            Self::Numbers => Some(count(numbers.map_or(0, |numbers| numbers.count))),
            Self::Empty => Some(count(summary.empty_count)),
            Self::NotANumber => (summary.not_a_number_count > 0).then(|| count(summary.not_a_number_count)),
            Self::Sum => numbers.map(|numbers| number(&numbers.sum)),
            Self::Average => numbers.map(|numbers| number(&numbers.average)),
            Self::Minimum => numbers.map(|numbers| number(&numbers.minimum)),
            Self::Maximum => numbers.map(|numbers| number(&numbers.maximum)),
        }
    }
}

struct FigureRow {
    figure: Figure,
    title: gtk::Label,
    value: gtk::Label,
    copy: gtk::Button,
    copied: Rc<RefCell<String>>,
}

impl FigureRow {
    fn new(grid: &DataGrid, figure: Figure) -> Self {
        let title = gtk::Label::builder().label(figure.title()).xalign(0.0).build();
        title.add_css_class("dimmed");
        // A sum can run to thousands of digits; the popover stays narrow.
        let value = gtk::Label::builder()
            .xalign(1.0)
            .hexpand(true)
            .wrap(true)
            .wrap_mode(gtk::pango::WrapMode::Char)
            .max_width_chars(32)
            .build();
        value.add_css_class("numeric");
        value.update_relation(&[gtk::accessible::Relation::LabelledBy(&[title.upcast_ref()])]);
        let copy_title = figure.copy_title();
        let copy = gtk::Button::builder()
            .icon_name(icons::EDIT_COPY)
            .tooltip_text(&copy_title)
            .valign(gtk::Align::Center)
            .build();
        copy.add_css_class("flat");
        copy.update_property(&[gtk::accessible::Property::Label(&copy_title)]);
        let copied: Rc<RefCell<String>> = Rc::default();
        let text = copied.clone();
        let grid = grid.downgrade();
        copy.connect_clicked(move |_| {
            if let Some(grid) = grid.upgrade() {
                crate::ui::clipboard::copy_text(&grid, text.borrow().clone(), |message| grid.toast(message));
            }
        });
        Self {
            figure,
            title,
            value,
            copy,
            copied,
        }
    }

    fn show(&self, figure: Option<(String, String)>) {
        let shown = figure.is_some();
        if let Some((text, copied)) = figure {
            self.value.set_label(&text);
            self.copied.replace(copied);
        }
        self.title.set_visible(shown);
        self.value.set_visible(shown);
        self.copy.set_visible(shown);
    }
}

impl DataGrid {
    /// The readout for a host to place in its bottom bar. A grid sums
    /// nothing until one is placed.
    pub(crate) fn selection_summary(&self) -> gtk::Widget {
        let state = &self.imp().summary;
        let placed = state.readout.get().is_some();
        let widget = state
            .readout
            .get_or_init(|| Readout::new(self))
            .revealer
            .clone()
            .upcast();
        if !placed {
            self.refresh_summary();
        }
        widget
    }

    /// Sum again once the main loop is idle, so a key press that moves
    /// both the focus and the selection sums once.
    pub(super) fn refresh_summary(&self) {
        let state = &self.imp().summary;
        if let Some(cell) = self.focused_cell() {
            state.column.set(Some(cell.column()));
        }
        if state.readout.get().is_none() || state.queued.replace(true) {
            return;
        }
        let grid = self.downgrade();
        glib::idle_add_local_once(move || {
            if let Some(grid) = grid.upgrade() {
                grid.imp().summary.queued.set(false);
                grid.start_summary();
            }
        });
    }

    /// Sum the values off the GTK thread: a page holds up to 100,000 rows.
    /// A newer run stops this one.
    fn start_summary(&self) {
        let state = &self.imp().summary;
        let Some(readout) = state.readout.get() else {
            return;
        };
        if let Some(running) = state.running.take() {
            running.store(true, Ordering::Relaxed);
        }
        let run = state.runs.get().wrapping_add(1);
        state.runs.set(run);
        let (Some(tasks), Some(input)) = (self.config().map(|config| config.tasks.clone()), self.summary_input()) else {
            readout.show(None);
            return;
        };
        let SummaryInput {
            column,
            index,
            rule,
            rows,
        } = input;
        let cancelled = Arc::new(AtomicBool::new(false));
        state.running.replace(Some(cancelled.clone()));
        readout.set_current(false);
        let grid = self.downgrade();
        glib::spawn_future_local(async move {
            let answer = tasks
                .spawn_blocking_task(move || {
                    let values = rows.iter().map(|row| row.value(index));
                    summarize(values, rule, &|| cancelled.load(Ordering::Relaxed))
                })
                .await;
            let Some(grid) = grid.upgrade() else {
                return;
            };
            let state = &grid.imp().summary;
            if state.runs.get() != run {
                return;
            }
            state.running.take();
            let Some(readout) = state.readout.get() else {
                return;
            };
            match answer {
                Ok(Some(summary)) => readout.show(Some(Shown { column, summary })),
                Ok(None) => {}
                Err(failure) => {
                    tracing::warn!(%failure, "the selection could not be summed");
                    readout.show(None);
                }
            }
        });
    }

    /// The selected rows as the cells show them, sharing the cells the page
    /// read. Rows marked for deletion are left out, also once a save failed
    /// on them.
    fn summary_input(&self) -> Option<SummaryInput> {
        let rows = self.selected_rows();
        if rows.len() < MIN_ROWS {
            return None;
        }
        let index = self.imp().summary.column.get()?;
        if !self.shown_columns().contains(&index) {
            return None;
        }
        let columns = self.grid_columns();
        let column = columns.iter().find(|column| column.index == index)?;
        let tracked = self.tracked();
        let rows = rows
            .iter()
            .filter(|row| !tracked.mark(row, index).row_deleted)
            .map(|row| tracked.snapshot(row))
            .collect();
        Some(SummaryInput {
            column: column.name.clone(),
            index,
            rule: SummaryRule::for_column(column),
            rows,
        })
    }
}

struct SummaryInput {
    column: String,
    index: usize,
    rule: SummaryRule,
    rows: Vec<RowSnapshot>,
}
