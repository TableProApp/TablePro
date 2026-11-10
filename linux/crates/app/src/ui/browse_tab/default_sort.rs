use tablepro_linux_platform::settings::{DefaultSort, GridSortDirection};

use crate::services::grid::GridColumn;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InitialSort {
    Default,
    Kept(Option<(usize, bool)>),
}

pub(super) fn resolve(
    behavior: DefaultSort,
    direction: GridSortDirection,
    columns: &[GridColumn],
) -> Option<(usize, bool)> {
    let column = match behavior {
        DefaultSort::PrimaryKey => columns
            .iter()
            .find(|column| column.catalog.as_ref().is_some_and(|catalog| catalog.primary_key))?,
        DefaultSort::FirstColumn => columns.first()?,
        DefaultSort::None => return None,
    };
    column.sortable().then_some((column.index, direction.ascending()))
}

#[cfg(test)]
mod tests {
    use tablepro_core::ColumnInfo;

    use super::*;
    use crate::services::grid::grid_columns;
    use crate::ui::data_grid::test_grid::named;

    fn columns() -> std::sync::Arc<[GridColumn]> {
        let catalog = vec![named("name", "text", false), named("id", "integer", true)];
        grid_columns(
            &catalog.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
            &catalog,
            |_| true,
        )
    }

    #[test]
    fn none_sorts_nothing() {
        assert_eq!(
            resolve(DefaultSort::None, GridSortDirection::Ascending, &columns()),
            None
        );
    }

    #[test]
    fn primary_key_picks_the_key_column_in_the_direction() {
        assert_eq!(
            resolve(DefaultSort::PrimaryKey, GridSortDirection::Ascending, &columns()),
            Some((1, true))
        );
        assert_eq!(
            resolve(DefaultSort::PrimaryKey, GridSortDirection::Descending, &columns()),
            Some((1, false))
        );
    }

    #[test]
    fn a_table_without_a_key_stays_unsorted_by_primary_key() {
        let keyless = columns()[..1].to_vec();
        assert_eq!(
            resolve(DefaultSort::PrimaryKey, GridSortDirection::Ascending, &keyless),
            None
        );
        assert_eq!(
            resolve(DefaultSort::FirstColumn, GridSortDirection::Ascending, &keyless),
            Some((0, true))
        );
    }

    #[test]
    fn unaddressable_and_missing_columns_are_not_sorted() {
        let mut columns = columns().to_vec();
        columns[0].addressable = false;
        columns[1].addressable = false;
        assert_eq!(
            resolve(DefaultSort::FirstColumn, GridSortDirection::Ascending, &columns),
            None
        );
        assert_eq!(
            resolve(DefaultSort::PrimaryKey, GridSortDirection::Ascending, &columns),
            None
        );
        assert_eq!(
            resolve(DefaultSort::FirstColumn, GridSortDirection::Ascending, &[]),
            None
        );
    }

    #[test]
    fn a_composite_key_uses_its_first_column() {
        let mut columns = columns().to_vec();
        columns[0].catalog.as_mut().expect("catalog").primary_key = true;
        assert_eq!(
            resolve(DefaultSort::PrimaryKey, GridSortDirection::Descending, &columns),
            Some((0, false))
        );
    }
}
