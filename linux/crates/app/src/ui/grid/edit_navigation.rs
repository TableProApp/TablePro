#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EditDirection {
    Forward,
    Backward,
}

/// The cell Tab or Shift+Tab edits next, as `(row, column)` with the
/// column counted in the order the grid shows them: the next cell along
/// the row that opens an editor, then the row after it.
///
/// The walk stops one row out. Drafts sit together above the saved
/// rows and rows of one kind lock the same columns, so a row with
/// nothing to edit has no editable row past it either.
pub fn next_edit_target(
    opens_editor: impl Fn(u32, usize) -> bool,
    n_columns: usize,
    column: usize,
    position: u32,
    n_rows: u32,
    direction: EditDirection,
) -> Option<(u32, usize)> {
    if position >= n_rows || column >= n_columns {
        return None;
    }
    let candidates: Vec<(u32, usize)> = match direction {
        EditDirection::Forward => {
            let rest = (column + 1..n_columns).map(|c| (position, c));
            let below = position
                .checked_add(1)
                .filter(|row| *row < n_rows)
                .into_iter()
                .flat_map(|row| (0..n_columns).map(move |c| (row, c)));
            rest.chain(below).collect()
        }
        EditDirection::Backward => {
            let rest = (0..column).rev().map(|c| (position, c));
            let above = position
                .checked_sub(1)
                .into_iter()
                .flat_map(|row| (0..n_columns).rev().map(move |c| (row, c)));
            rest.chain(above).collect()
        }
    };
    candidates.into_iter().find(|&(row, c)| opens_editor(row, c))
}

#[cfg(test)]
mod tests {
    use super::{EditDirection, next_edit_target};

    #[test]
    fn next_edit_target_skips_locked_and_wraps_rows() {
        // Column 0 is a key, locked on the saved rows 1 and 2 and open
        // on the draft in row 0; column 2 is generated.
        let opens = |row: u32, column: usize| match column {
            0 => row == 0,
            1 | 3 => true,
            _ => false,
        };
        let next = |column, position, direction| next_edit_target(opens, 4, column, position, 3, direction);

        assert_eq!(next(1, 1, EditDirection::Forward), Some((1, 3)), "the generated column");
        assert_eq!(next(3, 1, EditDirection::Forward), Some((2, 1)), "a saved row's key");
        assert_eq!(next(3, 0, EditDirection::Forward), Some((1, 1)));
        assert_eq!(next(0, 0, EditDirection::Forward), Some((0, 1)));
        assert_eq!(next(1, 1, EditDirection::Backward), Some((0, 3)), "a saved row's key");
        assert_eq!(next(1, 0, EditDirection::Backward), Some((0, 0)), "a draft's own key");
        assert_eq!(next(3, 2, EditDirection::Forward), None, "past the last row");
        assert_eq!(next(0, 0, EditDirection::Backward), None, "before the first row");
    }

    #[test]
    fn a_row_with_nothing_to_edit_ends_the_walk() {
        let opens = |row: u32, _column: usize| row != 1;

        assert_eq!(next_edit_target(opens, 2, 1, 0, 3, EditDirection::Forward), None);
        assert_eq!(next_edit_target(opens, 2, 0, 2, 3, EditDirection::Backward), None);
        assert_eq!(
            next_edit_target(|_, _| true, 2, 0, 5, 5, EditDirection::Forward),
            None,
            "a row past the page"
        );
        assert_eq!(
            next_edit_target(|_, _| true, 0, 0, 0, 1, EditDirection::Forward),
            None,
            "a grid with no shown columns"
        );
    }
}
