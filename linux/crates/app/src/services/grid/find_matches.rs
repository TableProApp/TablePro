use super::display_text::whole_text;
use super::{GridColumn, RowSnapshot};

const CANCEL_CHECK_ROWS: usize = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FindMatch {
    pub row: usize,
    /// The column's index in a row.
    pub column: usize,
}

/// Cells whose whole text holds `query`, ignoring case, row by row and
/// along each row in `order`, the positions in `columns` as displayed.
/// Stops early, with what it found, once `cancelled` says so.
pub fn find_matches(
    query: &str,
    rows: &[RowSnapshot],
    columns: &[GridColumn],
    order: &[usize],
    cancelled: &dyn Fn() -> bool,
) -> Vec<FindMatch> {
    if query.is_empty() {
        return Vec::new();
    }
    let needle = query.to_lowercase();
    let shown: Vec<&GridColumn> = order.iter().filter_map(|position| columns.get(*position)).collect();
    let mut scratch = String::new();
    let mut matches = Vec::new();
    for (row_index, row) in rows.iter().enumerate() {
        if row_index % CANCEL_CHECK_ROWS == 0 && cancelled() {
            break;
        }
        for column in &shown {
            let value = row.value(column.index);
            if value.is_null() {
                continue;
            }
            let text = whole_text(value, &column.column_type, &mut scratch);
            if text.to_lowercase().contains(&needle) {
                matches.push(FindMatch {
                    row: row_index,
                    column: column.index,
                });
            }
        }
    }
    matches
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::sync::Arc;

    use tablepro_core::Value;
    use tablepro_core::column::ColumnKind;

    use super::{FindMatch, find_matches};
    use crate::services::grid::test_columns::result_only;
    use crate::services::grid::{GridColumn, RowSnapshot};

    fn columns(count: usize) -> Vec<GridColumn> {
        (0..count)
            .map(|index| GridColumn {
                index,
                ..result_only(&format!("c{index}"), ColumnKind::Other)
            })
            .collect()
    }

    fn row(values: &[Value]) -> RowSnapshot {
        RowSnapshot::new(Arc::from(values.to_vec()), Vec::new())
    }

    fn text(value: &str) -> Value {
        Value::Text(value.to_owned())
    }

    fn at(row: usize, column: usize) -> FindMatch {
        FindMatch { row, column }
    }

    /// The cell cuts a long value and notes what it left out; the search
    /// reads the value itself.
    #[test]
    fn a_long_value_matches_past_the_cells_cut_and_never_on_its_note() {
        let long = format!("{}needle", "x".repeat(2_000));
        let rows = [row(&[text(&long)]), row(&[text(&"y".repeat(2_000))])];

        assert_eq!(
            find_matches("needle", &rows, &columns(1), &[0], &|| false),
            vec![at(0, 0)]
        );
        assert!(find_matches("more bytes", &rows, &columns(1), &[0], &|| false).is_empty());
    }

    #[test]
    fn matches_come_in_row_order_then_display_order() {
        let rows = [
            row(&[text("apple"), text("Pineapple"), text("pear")]),
            row(&[text("grape"), Value::Int(42), text("APPLE pie")]),
        ];

        let found = find_matches("apple", &rows, &columns(3), &[2, 0, 1], &|| false);

        assert_eq!(found, vec![at(0, 0), at(0, 1), at(1, 2)]);
        assert_eq!(
            find_matches("4", &rows, &columns(3), &[0, 1, 2], &|| false),
            vec![at(1, 1)],
            "a number matches as it is shown"
        );
    }

    #[test]
    fn null_and_an_empty_query_never_match() {
        let rows = [row(&[Value::Null, text("null")])];

        assert_eq!(
            find_matches("null", &rows, &columns(2), &[0, 1], &|| false),
            vec![at(0, 1)]
        );
        assert_eq!(find_matches("", &rows, &columns(2), &[0, 1], &|| false), Vec::new());
    }

    #[test]
    fn case_folds_past_ascii() {
        let rows = [row(&[text("Ärger"), text("straße")])];

        assert_eq!(
            find_matches("äR", &rows, &columns(2), &[0, 1], &|| false),
            vec![at(0, 0)]
        );
        assert_eq!(
            find_matches("STRAßE", &rows, &columns(2), &[0, 1], &|| false),
            vec![at(0, 1)]
        );
    }

    #[test]
    fn a_hidden_column_is_not_searched() {
        let rows = [row(&[text("x"), text("x")])];

        assert_eq!(find_matches("x", &rows, &columns(2), &[1], &|| false), vec![at(0, 1)]);
    }

    #[test]
    fn a_cancel_stops_at_the_next_check_with_what_it_found() {
        let rows: Vec<RowSnapshot> = (0..1_000).map(|_| row(&[text("hit")])).collect();
        let checks = Cell::new(0);
        let cancelled = || {
            checks.set(checks.get() + 1);
            checks.get() > 1
        };

        let found = find_matches("hit", &rows, &columns(1), &[0], &cancelled);

        assert_eq!(found.len(), 256, "rows past the cancel were searched");
        assert_eq!(checks.get(), 2);
        assert_eq!(find_matches("hit", &rows, &columns(1), &[0], &|| true), Vec::new());
    }
}
