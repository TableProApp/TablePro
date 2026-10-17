use std::cell::{Cell, RefCell};

use gtk4::prelude::*;
use gtk4::{self as gtk, pango};
use tablepro_core::Value;
use tablepro_core::column::{ColumnKind, ColumnType};

use super::RowObject;
use super::display_text::display_text;

const TEXT_MIN_CHARS: u32 = 3;
const TEXT_NAT_CHARS: u32 = 14;

/// How a column of either grid lays out its text. A column of numbers
/// lines them up on the last digit in tabular figures and asks for the
/// width of its longest number, so the column view never cuts one.
#[derive(Debug)]
pub struct ColumnFigures {
    numbers: Cell<bool>,
    /// The longest number the column has held, in characters.
    chars: Cell<u32>,
    /// An untyped column has held a value, and every one was a number.
    held_value: Cell<bool>,
    all_numbers: Cell<bool>,
    /// The last width asked of `digits_width`, which every numeric cell
    /// of the column asks again as it is bound.
    digits: RefCell<Option<DigitsWidth>>,
}

impl Default for ColumnFigures {
    fn default() -> Self {
        Self {
            numbers: Cell::new(false),
            chars: Cell::new(0),
            held_value: Cell::new(false),
            all_numbers: Cell::new(true),
            digits: RefCell::new(None),
        }
    }
}

#[derive(Debug)]
struct DigitsWidth {
    chars: u32,
    font: Option<pango::FontDescription>,
    dpi: i32,
    width: i32,
}

impl ColumnFigures {
    /// Decide from the column's type, or from `rows` when the driver
    /// could not type it.
    pub fn measure(&self, column_type: &ColumnType, index: usize, rows: &[RowObject]) {
        self.numbers.set(false);
        self.chars.set(0);
        self.held_value.set(false);
        self.all_numbers.set(true);
        self.extend(column_type, index, rows);
    }

    /// Take in rows added to those already measured. A draft has no
    /// cells, so it changes nothing.
    pub fn extend(&self, column_type: &ColumnType, index: usize, rows: &[RowObject]) {
        let values = rows
            .iter()
            .filter_map(|row| row.cell(index))
            .filter(|value| !value.is_null());
        if column_type.kind.is_numeric() {
            self.numbers.set(true);
            self.chars.set(self.chars.get().max(widest(column_type, values)));
            return;
        }
        // PostgreSQL editor results carry no type (ADR 0016), so such a
        // column aligns by what it holds, as a spreadsheet does.
        if !matches!(column_type.kind, ColumnKind::Other | ColumnKind::Variant) {
            return;
        }
        let mut scratch = String::new();
        for value in values {
            if !self.all_numbers.get() {
                break;
            }
            self.held_value.set(true);
            match is_number(value) {
                true => self.chars.set(
                    self.chars
                        .get()
                        .max(char_count(display_text(value, column_type, &mut scratch).text)),
                ),
                false => self.all_numbers.set(false),
            }
        }
        self.numbers.set(self.held_value.get() && self.all_numbers.get());
    }

    pub fn numbers(&self) -> bool {
        self.numbers.get()
    }

    /// Lay out `display` for `text`, the value it is about to show.
    pub fn apply(&self, display: &gtk::Inscription, text: &str, placeholder: bool) {
        if !self.numbers.get() {
            display.set_xalign(0.0);
            display.set_min_chars(TEXT_MIN_CHARS);
            display.set_nat_chars(TEXT_NAT_CHARS);
            display.set_width_request(-1);
            display.remove_css_class("numeric");
            return;
        }
        // An edit can hold a longer number than any row did.
        if !placeholder {
            self.chars.set(self.chars.get().max(char_count(text)));
        }
        display.set_xalign(1.0);
        display.set_min_chars(TEXT_MIN_CHARS);
        display.set_nat_chars(TEXT_MIN_CHARS);
        display.add_css_class("numeric");
        // GtkInscription sizes by an average character, which a run of
        // digits outgrows, so the cell asks for the digits' own width.
        display.set_width_request(self.digits_width(display, self.chars.get()));
    }

    /// The width of `chars` digits, laid out once per width, font and
    /// text scale rather than once per cell.
    fn digits_width(&self, display: &gtk::Inscription, chars: u32) -> i32 {
        let font = display.pango_context().font_description();
        let dpi = display.settings().gtk_xft_dpi();
        let mut cached = self.digits.borrow_mut();
        if let Some(digits) = cached.as_ref()
            && digits.chars == chars
            && digits.dpi == dpi
            && digits.font == font
        {
            return digits.width;
        }
        let width = digits_width(display, chars);
        *cached = Some(DigitsWidth {
            chars,
            font,
            dpi,
            width,
        });
        width
    }
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

fn widest<'a>(column_type: &ColumnType, values: impl Iterator<Item = &'a Value>) -> u32 {
    let mut scratch = String::new();
    values
        .map(|value| char_count(display_text(value, column_type, &mut scratch).text))
        .max()
        .unwrap_or(0)
}

/// How wide `chars` digits are in tabular figures, which libadwaita's
/// `numeric` class draws.
fn digits_width(widget: &impl IsA<gtk::Widget>, chars: u32) -> i32 {
    tabular_width(widget, &"0".repeat(usize::try_from(chars).unwrap_or_default()))
}

fn tabular_width(widget: &impl IsA<gtk::Widget>, text: &str) -> i32 {
    let layout = widget.create_pango_layout(Some(text));
    let tabular = pango::AttrList::new();
    tabular.insert(pango::AttrFontFeatures::new("tnum"));
    layout.set_attributes(Some(&tabular));
    layout.pixel_size().0
}

fn char_count(text: &str) -> u32 {
    u32::try_from(text.chars().count()).unwrap_or(u32::MAX)
}

#[cfg(test)]
mod tests {
    use gtk4::prelude::*;
    use gtk4::{self as gtk, gio};
    use tablepro_core::column::ColumnType;
    use tablepro_core::{ColumnInfo, Value};

    use super::{ColumnFigures, tabular_width};
    use crate::services::tab_tracker_handle::TabTrackerHandle;
    use crate::test_support::{descendants, wait_until};
    use crate::ui::grid::test_grid::{WAIT, col, content, named, persisted, recorder, tracked};
    use crate::ui::grid::{GridCell, GridSorting, RowObject, build_column_view};

    fn rows(values: &[Value]) -> Vec<RowObject> {
        values
            .iter()
            .map(|value| RowObject::result(vec![value.clone()].into()))
            .collect()
    }

    fn measured(column_type: &ColumnType, values: &[Value]) -> ColumnFigures {
        let figures = ColumnFigures::default();
        figures.measure(column_type, 0, &rows(values));
        figures
    }

    fn text(value: &str) -> Value {
        Value::Text(value.to_owned())
    }

    #[test]
    fn a_typed_column_is_numbers_by_its_type_alone() {
        assert!(measured(&col("integer", false).column_type, &[]).numbers());
        assert!(!measured(&col("text", false).column_type, &[text("12"), text("7")]).numbers());
    }

    #[test]
    fn an_untyped_column_is_numbers_when_every_value_is_one() {
        let untyped = ColumnType::untyped_text("text");

        for numbers in [
            vec![
                text("6"),
                text("-18.15"),
                Value::Null,
                text("1e-05"),
                text("NaN"),
                text("Infinity"),
            ],
            vec![Value::Int(2), Value::Float64(0.5)],
        ] {
            assert!(measured(&untyped, &numbers).numbers(), "{numbers:?}");
        }
        for not_numbers in [
            vec![text("6"), text("Coffee")],
            vec![text(" 6")],
            vec![text("")],
            vec![Value::Null],
            vec![],
        ] {
            assert!(!measured(&untyped, &not_numbers).numbers(), "{not_numbers:?}");
        }
    }

    #[test]
    fn rows_added_later_widen_the_column_and_a_draft_changes_nothing() {
        let integer = col("integer", false).column_type;
        let figures = measured(&integer, &[Value::Int(12)]);

        figures.extend(&integer, 0, &[RowObject::draft(1)]);
        assert_eq!(figures.chars.get(), 2);
        figures.extend(&integer, 0, &rows(&[Value::Int(-1_234)]));
        assert_eq!(figures.chars.get(), 5, "the widest row so far");
        figures.measure(&integer, 0, &rows(&[Value::Int(7)]));
        assert_eq!(figures.chars.get(), 1, "a new page measures from scratch");
    }

    #[test]
    fn an_untyped_column_stops_being_numbers_at_the_first_word_added() {
        let untyped = ColumnType::untyped_text("text");
        let figures = measured(&untyped, &[text("6")]);
        assert!(figures.numbers());

        figures.extend(&untyped, 0, &rows(&[Value::Null, text("Coffee")]));
        assert!(!figures.numbers());
        figures.extend(&untyped, 0, &rows(&[text("7")]));
        assert!(!figures.numbers(), "one word in the column is enough");
    }

    /// A browse page in a window too narrow for every column to get the
    /// width it asks for.
    struct Crowded {
        window: gtk::Window,
        view: gtk::ColumnView,
        store: gio::ListStore,
    }

    impl Drop for Crowded {
        fn drop(&mut self) {
            self.window.destroy();
        }
    }

    fn crowded(columns: &[ColumnInfo], rows: &[Vec<Value>]) -> Crowded {
        let (view, selection) = build_column_view(
            content(columns, persisted(rows)),
            columns,
            recorder().0,
            GridSorting::Server { initial: None },
            tracked(&TabTrackerHandle::default()),
        );
        let store = selection
            .model()
            .and_downcast::<gio::ListStore>()
            .expect("a list store");
        let window = gtk::Window::new();
        window.set_default_size(725, 400);
        window.set_child(Some(&gtk::ScrolledWindow::builder().child(&view).build()));
        window.present();
        Crowded { window, view, store }
    }

    fn shop_columns(more_text: usize) -> Vec<ColumnInfo> {
        let mut columns = vec![
            named("id", "bigint", true),
            named("sku", "text", false),
            named("name", "text", false),
            named("price", "numeric(20,4)", false),
            named("stock", "integer", false),
            named("updated_at", "text", false),
            named("note", "text", false),
            named("comment", "text", false),
        ];
        columns.extend((0..more_text).map(|index| named(&format!("tag_{index}"), "text", false)));
        columns
    }

    const NUMBER_COLUMNS: [usize; 3] = [0, 3, 4];

    fn shop_row(id: i64, price: &str, width: usize) -> Vec<Value> {
        let mut row = vec![
            Value::Int(id),
            text("CF-1001"),
            text("Ethiopia Yirgacheffe, 250 g"),
            Value::Decimal(price.parse().expect("a decimal")),
            Value::Int(123_456),
            text("2026-09-02 09:14:00+00"),
            text("Ground for a paper filter"),
            text("Ships in two days"),
        ];
        row.resize(width, text("seasonal"));
        row
    }

    /// The text of `columns` in the rows on screen.
    fn drawn(view: &gtk::ColumnView, columns: &[usize]) -> Vec<gtk::Inscription> {
        descendants(view)
            .into_iter()
            .filter_map(|widget| widget.downcast::<GridCell>().ok())
            .filter(|cell| cell.row().is_some() && columns.contains(&cell.column()) && cell.is_mapped())
            .filter_map(|cell| cell.display())
            .collect()
    }

    fn shows_whole(display: &gtk::Inscription) -> bool {
        let text = display.text().unwrap_or_default();
        display.width() > 0 && tabular_width(display, &text) <= display.width()
    }

    #[gtk4::test]
    fn a_number_column_is_as_wide_as_its_widest_number() {
        // Eight columns share the width; past eight, each starts at a
        // readable width of its own.
        for more_text in [0, 2] {
            let columns = shop_columns(more_text);
            let rows: Vec<Vec<Value>> = (0..20)
                .map(|offset| shop_row(100_000_001 + offset, "123456789012.3456", columns.len()))
                .collect();
            let grid = crowded(&columns, &rows);

            let whole = wait_until(WAIT, || {
                let numbers = drawn(&grid.view, &NUMBER_COLUMNS);
                !numbers.is_empty() && numbers.iter().all(shows_whole)
            });

            assert!(whole.is_ok(), "a number was cut among {} columns", columns.len());
        }
    }

    #[gtk4::test]
    fn a_new_page_is_measured_down_to_its_last_row() {
        let columns = shop_columns(0);
        let first: Vec<Vec<Value>> = (1..=20).map(|id| shop_row(id, "1.5", columns.len())).collect();
        let grid = crowded(&columns, &first);
        wait_until(WAIT, || !drawn(&grid.view, &[0]).is_empty()).expect("the first page is drawn");
        let mut next: Vec<Vec<Value>> = (21..=320).map(|id| shop_row(id, "1.5", columns.len())).collect();
        if let Some(last) = next.last_mut() {
            last[0] = Value::Int(100_000_000_001);
        }

        grid.store.splice(0, grid.store.n_items(), &persisted(&next));

        let wide = wait_until(WAIT, || {
            drawn(&grid.view, &[0])
                .iter()
                .any(|display| display.width() >= tabular_width(display, "100000000001"))
        });
        assert!(wide.is_ok(), "the column waits for its widest row to scroll into view");
    }

    #[gtk4::test]
    fn adding_a_draft_keeps_the_width_the_page_measured() {
        let columns = shop_columns(0);
        let mut first: Vec<Vec<Value>> = (1..=20).map(|id| shop_row(id, "1.5", columns.len())).collect();
        if let Some(last) = first.last_mut() {
            last[0] = Value::Int(100_000_000_001);
        }
        let grid = crowded(&columns, &first);
        wait_until(WAIT, || !drawn(&grid.view, &[0]).is_empty()).expect("the page is drawn");

        grid.store.insert(0, &RowObject::draft(1));

        let wide = wait_until(WAIT, || {
            let ids = drawn(&grid.view, &[0]);
            !ids.is_empty()
                && ids
                    .iter()
                    .all(|display| display.width() >= tabular_width(display, "100000000001"))
        });
        assert!(wide.is_ok(), "the draft narrowed the column its rows had widened");
    }
}
