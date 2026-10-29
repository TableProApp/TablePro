use std::cell::RefCell;
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, glib};

use super::DataGrid;
use super::tracked_values::RowPendingState;
use crate::i18n::{gettext, gettext_f};
use crate::services::grid::{NumberFigures, SelectionSummary, SummaryRule, SummaryTally};
use crate::ui::format::{format_decimal, format_thousands};

/// A summary of one row says no more than the cell, so it starts at two.
const MIN_ROWS: usize = 2;

/// The figures of the focused column over the selected rows, as a
/// spreadsheet's status bar shows them, with every figure and a Copy
/// button for each in its popover.
#[derive(Clone)]
pub struct SummaryReadout {
    button: gtk::MenuButton,
    label: SummaryLadder,
    heading: gtk::Label,
    figures: gtk::Grid,
    shown: Rc<RefCell<Option<Shown>>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Shown {
    column: String,
    summary: SelectionSummary,
}

/// One line of the popover: what it is, the value as the locale writes
/// it, and the text Copy puts on the clipboard.
struct Figure {
    title: String,
    copy_title: String,
    shown: String,
    copied: String,
}

impl SummaryReadout {
    fn new(grid: &DataGrid) -> Self {
        let label = SummaryLadder::new();
        let heading = gtk::Label::builder()
            .xalign(0.0)
            .ellipsize(gtk::pango::EllipsizeMode::End)
            .build();
        heading.add_css_class("heading");
        let figures = gtk::Grid::builder().row_spacing(4).column_spacing(12).build();
        let content = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(8)
            .margin_top(6)
            .margin_bottom(6)
            .margin_start(6)
            .margin_end(6)
            .build();
        content.append(&heading);
        content.append(&figures);
        let popover = gtk::Popover::builder().child(&content).build();
        let button = gtk::MenuButton::builder()
            .child(&label)
            .popover(&popover)
            .visible(false)
            .build();
        button.add_css_class("flat");
        button.update_property(&[gtk::accessible::Property::Description(&gettext(
            "Shows every figure with a Copy button",
        ))]);
        let readout = Self {
            button,
            label,
            heading,
            figures,
            shown: Rc::default(),
        };
        let weak = grid.downgrade();
        let filled = readout.clone();
        popover.connect_show(move |_| {
            if let Some(grid) = weak.upgrade() {
                filled.fill_figures(&grid);
            }
        });
        readout
    }

    pub(crate) fn widget(&self) -> &gtk::Widget {
        self.button.upcast_ref()
    }

    fn show(&self, grid: &DataGrid, shown: Option<Shown>) {
        if *self.shown.borrow() == shown {
            return;
        }
        match &shown {
            Some(shown) => {
                let rungs = label_rungs(&shown.summary);
                self.button.set_tooltip_text(Some(&rungs[0]));
                self.button
                    .update_property(&[gtk::accessible::Property::Label(&rungs[0])]);
                self.label.set_rungs(&rungs);
            }
            None => self.button.popdown(),
        }
        self.button.set_visible(shown.is_some());
        self.shown.replace(shown);
        if self.button.popover().is_some_and(|popover| popover.is_visible()) {
            self.fill_figures(grid);
        }
    }

    fn fill_figures(&self, grid: &DataGrid) {
        while let Some(child) = self.figures.first_child() {
            self.figures.remove(&child);
        }
        let Some(shown) = self.shown.borrow().clone() else {
            return;
        };
        self.heading.set_label(&shown.column);
        let (counts, numbers) = figures(&shown.summary);
        let mut line = 0;
        for figure in counts {
            self.attach_figure(grid, &figure, line);
            line += 1;
        }
        if !numbers.is_empty() {
            self.figures
                .attach(&gtk::Separator::new(gtk::Orientation::Horizontal), 0, line, 3, 1);
            line += 1;
        }
        for figure in numbers {
            self.attach_figure(grid, &figure, line);
            line += 1;
        }
    }

    fn attach_figure(&self, grid: &DataGrid, figure: &Figure, line: i32) {
        let title = gtk::Label::builder().label(&figure.title).xalign(0.0).build();
        title.add_css_class("dimmed");
        let value = gtk::Label::builder()
            .label(&figure.shown)
            .xalign(1.0)
            .hexpand(true)
            .selectable(true)
            .build();
        value.add_css_class("numeric");
        value.update_relation(&[gtk::accessible::Relation::LabelledBy(&[title.upcast_ref()])]);
        let copy = gtk::Button::builder()
            .icon_name("edit-copy-symbolic")
            .tooltip_text(&figure.copy_title)
            .build();
        copy.add_css_class("flat");
        copy.update_property(&[gtk::accessible::Property::Label(&figure.copy_title)]);
        let text = figure.copied.clone();
        let weak = grid.downgrade();
        copy.connect_clicked(move |_| {
            if let Some(grid) = weak.upgrade() {
                crate::ui::clipboard::copy_text(&grid, text.clone(), |message| grid.toast(message));
            }
        });
        self.figures.attach(&title, 0, line, 1, 1);
        self.figures.attach(&value, 1, line, 1, 1);
        self.figures.attach(&copy, 2, line, 1, 1);
    }
}

/// The bar's text from the widest to the narrowest. Digits are never cut:
/// a narrower bar drops figures instead, down to a sign that keeps the
/// popover in reach at every width.
fn label_rungs(summary: &SelectionSummary) -> [String; 3] {
    let count = format_thousands(summary.value_count);
    // Translators: the summation sign, the bar's sum when it has room for nothing else.
    let sign = gettext("Σ");
    match &summary.numbers {
        Some(numbers) => {
            let sum = format_decimal(&numbers.sum.plain_text(numbers.scale));
            [
                gettext_f(
                    "Sum {sum}, Average {average}, Count {count}",
                    &[
                        ("sum", &sum),
                        ("average", &format_decimal(&numbers.average.plain_text(0))),
                        ("count", &count),
                    ],
                ),
                gettext_f("Sum {sum}", &[("sum", &sum)]),
                sign,
            ]
        }
        None => {
            let count = gettext_f("Count {count}", &[("count", &count)]);
            [count.clone(), count, sign]
        }
    }
}

mod ladder {
    use std::cell::RefCell;

    use gtk4::prelude::*;
    use gtk4::subclass::prelude::*;
    use gtk4::{self as gtk, glib};

    /// Shows the first of its labels that fits its width, the last one
    /// when none does, so a long one never shows cut short.
    #[derive(Default)]
    pub struct SummaryLadder {
        pub rungs: RefCell<Vec<gtk::Label>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for SummaryLadder {
        const NAME: &'static str = "TableProSummaryLadder";
        type Type = super::SummaryLadder;
        type ParentType = gtk::Widget;
    }

    impl ObjectImpl for SummaryLadder {
        fn dispose(&self) {
            for rung in self.rungs.take() {
                rung.unparent();
            }
        }
    }

    impl WidgetImpl for SummaryLadder {
        fn measure(&self, orientation: gtk::Orientation, _for_size: i32) -> (i32, i32, i32, i32) {
            let rungs = self.rungs.borrow();
            let natural = |rung: &gtk::Label| rung.measure(orientation, -1).1;
            match orientation {
                gtk::Orientation::Horizontal => {
                    let widest = rungs.first().map_or(0, natural);
                    let narrowest = rungs.last().map_or(0, natural);
                    (narrowest, widest.max(narrowest), -1, -1)
                }
                _ => {
                    let tallest = rungs.iter().map(natural).max().unwrap_or(0);
                    (tallest, tallest, -1, -1)
                }
            }
        }

        fn size_allocate(&self, width: i32, height: i32, baseline: i32) {
            let rungs = self.rungs.borrow();
            let last = rungs.len().saturating_sub(1);
            let chosen = rungs
                .iter()
                .position(|rung| rung.measure(gtk::Orientation::Horizontal, -1).1 <= width)
                .unwrap_or(last);
            for (index, rung) in rungs.iter().enumerate() {
                rung.set_child_visible(index == chosen);
                if index == chosen {
                    rung.allocate(width, height, baseline, None);
                }
            }
        }
    }
}

glib::wrapper! {
    pub struct SummaryLadder(ObjectSubclass<ladder::SummaryLadder>)
        @extends gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl SummaryLadder {
    fn new() -> Self {
        glib::Object::new()
    }

    fn set_rungs(&self, texts: &[String]) {
        let mut rungs = self.imp().rungs.borrow_mut();
        while rungs.len() < texts.len() {
            // The button carries the whole text for a screen reader.
            let rung = gtk::Label::builder()
                .accessible_role(gtk::AccessibleRole::Presentation)
                .build();
            rung.add_css_class("caption");
            rung.add_css_class("numeric");
            rung.set_parent(self);
            rungs.push(rung);
        }
        for (rung, text) in rungs.iter().zip(texts) {
            rung.set_label(text);
        }
        drop(rungs);
        self.queue_resize();
    }

    /// The text it shows when nothing is short of room.
    #[cfg(test)]
    fn widest(&self) -> String {
        self.imp()
            .rungs
            .borrow()
            .first()
            .map(|rung| rung.label().to_string())
            .unwrap_or_default()
    }
}

fn count_figure(title: String, copy_title: String, n: u64) -> Figure {
    Figure {
        title,
        copy_title,
        shown: format_thousands(n),
        copied: n.to_string(),
    }
}

fn number_figure(title: String, copy_title: String, plain: String) -> Figure {
    Figure {
        title,
        copy_title,
        shown: format_decimal(&plain),
        copied: plain,
    }
}

/// The counts, then the figures of the numbers among the values.
fn figures(summary: &SelectionSummary) -> (Vec<Figure>, Vec<Figure>) {
    let mut counts = vec![
        count_figure(gettext("Count"), gettext("Copy Count"), summary.value_count),
        count_figure(
            // Translators: how many of the summed cells hold a number.
            gettext("Numbers"),
            gettext("Copy Number Count"),
            summary.numbers.as_ref().map_or(0, |numbers| numbers.count),
        ),
        count_figure(gettext("Empty"), gettext("Copy Empty Count"), summary.empty_count),
    ];
    if summary.not_a_number_count > 0 {
        counts.push(count_figure(
            gettext("Not a Number"),
            gettext("Copy Not a Number Count"),
            summary.not_a_number_count,
        ));
    }
    let numbers = summary.numbers.as_ref().map_or_else(Vec::new, number_figures);
    (counts, numbers)
}

fn number_figures(numbers: &NumberFigures) -> Vec<Figure> {
    vec![
        number_figure(
            gettext("Sum"),
            gettext("Copy Sum"),
            numbers.sum.plain_text(numbers.scale),
        ),
        number_figure(
            gettext("Average"),
            gettext("Copy Average"),
            numbers.average.plain_text(0),
        ),
        number_figure(
            gettext("Minimum"),
            gettext("Copy Minimum"),
            numbers.minimum.plain_text(numbers.scale),
        ),
        number_figure(
            gettext("Maximum"),
            gettext("Copy Maximum"),
            numbers.maximum.plain_text(numbers.scale),
        ),
    ]
}

impl DataGrid {
    /// The readout for a host to place in its status bar. It shows only
    /// once placed, so a grid no bar holds sums nothing.
    pub(crate) fn selection_summary(&self) -> SummaryReadout {
        let readout = self.imp().summary.get_or_init(|| SummaryReadout::new(self)).clone();
        self.refresh_summary();
        readout
    }

    pub(super) fn refresh_summary(&self) {
        if let Some(readout) = self.imp().summary.get() {
            readout.show(self, self.summarize());
        }
    }

    /// The focused column over the selected rows. Rows marked for
    /// deletion are left out, and pending edits count as the cell shows
    /// them.
    fn summarize(&self) -> Option<Shown> {
        let rows = self.selected_rows();
        if rows.len() < MIN_ROWS {
            return None;
        }
        let column = self.focus_target().resolve()?.cell?.1;
        let columns = self.grid_columns();
        let grid_column = columns.iter().find(|candidate| candidate.index == column)?;
        let rule = SummaryRule::for_column(grid_column);
        let tracked = self.tracked();
        let mut tally = SummaryTally::default();
        for row in rows {
            if tracked.row_state(&row) == RowPendingState::MarkedForDeletion {
                continue;
            }
            tracked.with_value(&row, column, |value, default| tally.add(value, default, rule));
        }
        Some(Shown {
            column: grid_column.name.clone(),
            summary: tally.summary(),
        })
    }
}

#[cfg(test)]
mod tests {
    use gtk4::prelude::*;
    use tablepro_core::Value;

    use crate::ui::data_grid::test_grid::{Grid, named};

    fn numbers_and_names() -> Vec<Vec<Value>> {
        let text = |name: &str| Value::Text(name.to_owned());
        vec![
            vec![Value::Int(10), text("a")],
            vec![Value::Int(32), text("b")],
            vec![Value::Null, text("c")],
        ]
    }

    #[gtk4::test]
    fn summary_sums_the_focused_column_over_the_selected_rows() {
        let grid = Grid::open(
            vec![named("amount", "integer", false), named("name", "text", true)],
            numbers_and_names(),
        );
        let readout = grid.grid.selection_summary();
        assert!(!readout.widget().is_visible(), "nothing is selected yet");

        grid.focus(0, 0);
        grid.grid.selection().select_all();

        assert!(readout.widget().is_visible());
        assert_eq!(readout.label.widest(), "Sum 42, Average 21, Count 2");
    }

    #[gtk4::test]
    fn summary_only_counts_a_text_column() {
        let grid = Grid::open(
            vec![named("amount", "integer", false), named("name", "text", true)],
            numbers_and_names(),
        );
        let readout = grid.grid.selection_summary();

        grid.focus(0, 1);
        grid.grid.selection().select_all();

        assert_eq!(readout.label.widest(), "Count 3");
    }

    #[gtk4::test]
    fn summary_hides_for_a_single_row() {
        let grid = Grid::open(
            vec![named("amount", "integer", false), named("name", "text", true)],
            numbers_and_names(),
        );
        let readout = grid.grid.selection_summary();
        grid.focus(0, 0);
        grid.grid.selection().select_all();
        assert!(readout.widget().is_visible());

        grid.grid.selection().select_item(1, true);

        assert!(!readout.widget().is_visible());
    }
}
