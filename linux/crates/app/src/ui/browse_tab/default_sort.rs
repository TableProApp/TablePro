use tablepro_core::ColumnInfo;

/// The column a table opens sorted by, as Preferences ask, and the way:
/// `None` for no sorting, or when the table has no primary key to use.
/// Linux sorts by one column, so a composite key gives its first.
pub(super) fn resolve(behavior: &str, descending: bool, columns: &[ColumnInfo]) -> Option<(usize, bool)> {
    let column = match behavior {
        "primary-key" => columns.iter().position(|column| column.primary_key)?,
        "first-column" if !columns.is_empty() => 0,
        _ => return None,
    };
    Some((column, !descending))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ui::data_grid::test_grid::named;

    fn columns() -> Vec<ColumnInfo> {
        vec![named("name", "text", false), named("id", "integer", true)]
    }

    #[test]
    fn none_sorts_nothing() {
        assert_eq!(resolve("none", false, &columns()), None);
    }

    #[test]
    fn primary_key_picks_the_key_column_in_the_direction() {
        assert_eq!(resolve("primary-key", false, &columns()), Some((1, true)));
        assert_eq!(resolve("primary-key", true, &columns()), Some((1, false)));
    }

    #[test]
    fn a_table_without_a_key_stays_unsorted_by_primary_key() {
        let keyless = vec![named("name", "text", false)];

        assert_eq!(resolve("primary-key", false, &keyless), None);
        assert_eq!(resolve("first-column", false, &keyless), Some((0, true)));
    }
}
