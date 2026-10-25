use tablepro_core::ColumnInfo;
use tablepro_core::edit::read_only_reason;
use tablepro_core::meta::RowIdentity;

use super::{CellLock, GridColumn, GridRowId};

/// Whether this cell takes a value. A draft may set the key a saved row
/// may not, but an auto-increment column stays locked on a draft too:
/// SQL Server IDENTITY and PostgreSQL GENERATED ALWAYS refuse a value.
pub fn cell_editability(
    column: &GridColumn,
    row: &GridRowId,
    identity: &RowIdentity,
    read_only: bool,
    pending_delete: bool,
) -> Result<(), CellLock> {
    match row {
        GridRowId::Result => return Err(CellLock::ResultRow),
        GridRowId::Unkeyed => return Err(CellLock::UnkeyedRow),
        GridRowId::Persisted(_) | GridRowId::Draft(_) => {}
    }
    if read_only {
        return Err(CellLock::ReadOnlySession);
    }
    if pending_delete {
        return Err(CellLock::PendingDelete);
    }
    if !column.addressable {
        return Err(CellLock::Unaddressable);
    }
    let Some(catalog) = column.catalog.as_ref() else {
        return Err(CellLock::ResultRow);
    };
    if catalog.is_generated {
        return Err(CellLock::Generated);
    }
    if let Some(reason) = read_only_reason(&catalog.column_type.kind) {
        return Err(CellLock::Value(reason));
    }
    if catalog.is_auto_increment {
        return Err(CellLock::AutoIncrement);
    }
    if matches!(row, GridRowId::Persisted(_)) && names_rows(catalog, identity) {
        return Err(CellLock::KeyColumn);
    }
    Ok(())
}

fn names_rows(column: &ColumnInfo, identity: &RowIdentity) -> bool {
    match identity {
        RowIdentity::UniqueKey { columns } => columns.contains(&column.name),
        RowIdentity::SortingKey { expressions } => expressions.contains(&column.name),
        RowIdentity::EngineRowId(_) | RowIdentity::Unordered => false,
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::ColumnKind;
    use tablepro_core::edit::ReadOnlyReason;
    use tablepro_core::meta::RowIdentity;

    use super::cell_editability;
    use crate::services::grid::test_columns::{grid, info, persisted, result_only};
    use crate::services::grid::{CellLock, GridColumn, GridRowId};

    fn column(name: &str, data_type: &str) -> GridColumn {
        grid(info(name, data_type))
    }

    fn keyed_by_id() -> RowIdentity {
        RowIdentity::UniqueKey {
            columns: vec!["id".to_owned()],
        }
    }

    fn with_catalog(column: &str, data_type: &str, change: impl Fn(&mut tablepro_core::ColumnInfo)) -> GridColumn {
        let mut info = info(column, data_type);
        change(&mut info);
        grid(info)
    }

    #[test]
    fn cell_editability_matrix() {
        let identity = keyed_by_id();
        let id = column("id", "integer");
        let name = column("name", "text");
        let serial = with_catalog("seq", "integer", |info| info.is_auto_increment = true);
        let total = with_catalog("total", "integer", |info| info.is_generated = true);
        let blob = column("data", "bytea");
        let draft = GridRowId::Draft(0);
        let check = |column: &GridColumn, row: &GridRowId, read_only: bool| {
            cell_editability(column, row, &identity, read_only, false)
        };

        assert_eq!(check(&name, &persisted(), false), Ok(()));
        assert_eq!(check(&id, &persisted(), false), Err(CellLock::KeyColumn));
        assert_eq!(check(&id, &draft, false), Ok(()), "a draft sets its own key");
        assert_eq!(check(&total, &draft, false), Err(CellLock::Generated));
        assert_eq!(check(&total, &persisted(), false), Err(CellLock::Generated));
        assert_eq!(check(&serial, &persisted(), false), Err(CellLock::AutoIncrement));
        assert_eq!(
            check(&serial, &draft, false),
            Err(CellLock::AutoIncrement),
            "an insert leaves an auto-increment column to the server"
        );
        assert_eq!(check(&name, &GridRowId::Unkeyed, false), Err(CellLock::UnkeyedRow));
        assert_eq!(check(&name, &GridRowId::Result, false), Err(CellLock::ResultRow));
        assert_eq!(check(&name, &persisted(), true), Err(CellLock::ReadOnlySession));
        assert_eq!(check(&name, &draft, true), Err(CellLock::ReadOnlySession));
        assert_eq!(check(&blob, &draft, false), Err(CellLock::Value(ReadOnlyReason::Bytes)));
    }

    #[test]
    fn a_sorting_key_column_is_locked_on_saved_rows() {
        let identity = RowIdentity::SortingKey {
            expressions: vec!["day".to_owned()],
        };

        assert_eq!(
            cell_editability(&column("day", "date"), &persisted(), &identity, false, false),
            Err(CellLock::KeyColumn)
        );
        assert_eq!(
            cell_editability(&column("hits", "integer"), &persisted(), &identity, false, false),
            Ok(())
        );
    }

    #[test]
    fn a_new_row_takes_no_value_in_a_column_the_server_fills_or_with_no_text() {
        let identity = keyed_by_id();
        let total = with_catalog("total", "integer", |info| info.is_generated = true);
        let serial = with_catalog("seq", "integer", |info| info.is_auto_increment = true);
        let draft = |column: &GridColumn, read_only: bool| {
            cell_editability(column, &GridRowId::Draft(0), &identity, read_only, false).is_ok()
        };

        assert!(draft(&column("id", "integer"), false));
        assert!(!draft(&total, false));
        assert!(!draft(&serial, false));
        assert!(!draft(&column("data", "blob"), false));
        assert!(!draft(&column("name", "text"), true));
    }

    #[test]
    fn a_row_marked_for_deletion_takes_no_edit() {
        let identity = keyed_by_id();
        let name = column("name", "text");

        assert_eq!(
            cell_editability(&name, &persisted(), &identity, false, true),
            Err(CellLock::PendingDelete)
        );
        assert_eq!(
            cell_editability(&name, &GridRowId::Draft(1), &identity, false, true),
            Err(CellLock::PendingDelete)
        );
    }

    #[test]
    fn an_unaddressable_or_uncatalogued_column_takes_no_edit() {
        let identity = keyed_by_id();
        let dotted = GridColumn {
            addressable: false,
            ..column("a.b", "text")
        };

        assert_eq!(
            cell_editability(&dotted, &persisted(), &identity, false, false),
            Err(CellLock::Unaddressable)
        );
        assert_eq!(
            cell_editability(
                &result_only("x", ColumnKind::Other),
                &persisted(),
                &identity,
                false,
                false
            ),
            Err(CellLock::ResultRow),
            "a column the catalogue does not know"
        );
        assert!(cell_editability(&dotted, &GridRowId::Draft(0), &identity, false, false).is_err());
    }
}
