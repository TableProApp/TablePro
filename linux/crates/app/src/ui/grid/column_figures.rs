use std::cell::Cell;

use gtk4 as gtk;
use gtk4::prelude::*;
use tablepro_core::Value;
use tablepro_core::column::{ColumnKind, ColumnType};

use super::RowObject;

/// How a column of either grid lines up its text. A column of numbers
/// lines them up on the last digit in tabular figures.
#[derive(Debug, Default)]
pub struct ColumnFigures {
    numbers: Cell<bool>,
}

impl ColumnFigures {
    /// Decide from the column's type, or from `rows` when the driver
    /// could not type it.
    pub fn measure(&self, column_type: &ColumnType, index: usize, rows: &[RowObject]) {
        let values = rows
            .iter()
            .filter_map(|row| row.cell(index))
            .filter(|value| !value.is_null());
        self.numbers.set(holds_numbers(&column_type.kind, values));
    }

    pub fn apply(&self, display: &gtk::Inscription) {
        if self.numbers.get() {
            display.set_xalign(1.0);
            display.add_css_class("numeric");
        } else {
            display.set_xalign(0.0);
            display.remove_css_class("numeric");
        }
    }
}

fn holds_numbers<'a>(kind: &ColumnKind, values: impl Iterator<Item = &'a Value>) -> bool {
    if kind.is_numeric() {
        return true;
    }
    // PostgreSQL editor results carry no type (ADR 0016), so such a
    // column aligns by what it holds, as a spreadsheet does.
    if !matches!(kind, ColumnKind::Other | ColumnKind::Variant) {
        return false;
    }
    let mut values = values.peekable();
    values.peek().is_some() && values.all(is_number)
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

#[cfg(test)]
mod tests {
    use tablepro_core::Value;
    use tablepro_core::column::ColumnType;

    use super::ColumnFigures;
    use crate::ui::grid::RowObject;
    use crate::ui::grid::test_grid::col;

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
        assert!(measured(&col("integer", false).column_type, &[]).numbers.get());
        assert!(
            !measured(&col("text", false).column_type, &[text("12"), text("7")])
                .numbers
                .get()
        );
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
            assert!(measured(&untyped, &numbers).numbers.get(), "{numbers:?}");
        }
        for not_numbers in [
            vec![text("6"), text("Coffee")],
            vec![text(" 6")],
            vec![text("")],
            vec![Value::Null],
            vec![],
        ] {
            assert!(!measured(&untyped, &not_numbers).numbers.get(), "{not_numbers:?}");
        }
    }
}
