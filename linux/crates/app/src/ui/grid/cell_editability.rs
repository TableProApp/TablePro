use tablepro_core::ColumnInfo;
use tablepro_core::edit::read_only_reason;
use tablepro_core::meta::RowIdentity;

use super::{CellLock, GridRowId};

/// A draft is a new row, so it may set the key a saved row may not.
/// An auto-increment column stays locked on a draft too: an insert
/// leaves it to the server, and SQL Server IDENTITY and PostgreSQL
/// GENERATED ALWAYS refuse a value without a statement-level override.
pub fn cell_editability(
    column: &ColumnInfo,
    row: &GridRowId,
    identity: &RowIdentity,
    read_only: bool,
) -> Result<(), CellLock> {
    match row {
        GridRowId::Result => return Err(CellLock::ResultRow),
        GridRowId::Unkeyed => return Err(CellLock::UnkeyedRow),
        GridRowId::Persisted(_) | GridRowId::Draft(_) => {}
    }
    if read_only {
        return Err(CellLock::ReadOnlySession);
    }
    if column.is_generated {
        return Err(CellLock::Generated);
    }
    if let Some(reason) = read_only_reason(&column.column_type.kind) {
        return Err(CellLock::Value(reason));
    }
    if column.is_auto_increment {
        return Err(CellLock::AutoIncrement);
    }
    if matches!(row, GridRowId::Persisted(_)) && names_rows(column, identity) {
        return Err(CellLock::KeyColumn);
    }
    Ok(())
}

/// Whether some row of this column can be edited, which decides the
/// widget the column's cells are built with. A draft has the fewest
/// locks, so a column a draft cannot edit no row can.
pub fn column_takes_edits(column: &ColumnInfo, identity: &RowIdentity, read_only: bool) -> bool {
    cell_editability(column, &GridRowId::Draft(0), identity, read_only).is_ok()
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
    use tablepro_core::column::{ColumnDefault, ColumnType};
    use tablepro_core::edit::ReadOnlyReason;
    use tablepro_core::meta::RowIdentity;
    use tablepro_core::{ColumnInfo, Value};

    use super::{cell_editability, column_takes_edits};
    use crate::services::change_tracker::RowKey;
    use crate::ui::grid::{CellLock, GridRowId};

    fn column(name: &str, data_type: &str) -> ColumnInfo {
        let kind = tablepro_core::column::classify_type_name(data_type);
        ColumnInfo {
            name: name.to_owned(),
            column_type: ColumnType {
                kind,
                ..ColumnType::untyped_text(data_type)
            },
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn keyed_by_id() -> RowIdentity {
        RowIdentity::UniqueKey {
            columns: vec!["id".to_owned()],
        }
    }

    fn persisted() -> GridRowId {
        GridRowId::Persisted(RowKey::from_pk_values(&[Value::Int(1)]).expect("a key"))
    }

    #[test]
    fn cell_editability_matrix() {
        let identity = keyed_by_id();
        let id = column("id", "integer");
        let name = column("name", "text");
        let mut serial = column("seq", "integer");
        serial.is_auto_increment = true;
        let mut total = column("total", "integer");
        total.is_generated = true;
        let blob = column("data", "bytea");
        let draft = GridRowId::Draft(0);
        let check =
            |column: &ColumnInfo, row: &GridRowId, read_only: bool| cell_editability(column, row, &identity, read_only);

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
            cell_editability(&column("day", "date"), &persisted(), &identity, false),
            Err(CellLock::KeyColumn)
        );
        assert_eq!(
            cell_editability(&column("hits", "integer"), &persisted(), &identity, false),
            Ok(())
        );
    }

    #[test]
    fn a_column_no_row_can_edit_is_built_read_only() {
        let identity = keyed_by_id();
        let mut total = column("total", "integer");
        total.is_generated = true;

        let mut serial = column("seq", "integer");
        serial.is_auto_increment = true;

        assert!(column_takes_edits(&column("id", "integer"), &identity, false));
        assert!(!column_takes_edits(&total, &identity, false));
        assert!(!column_takes_edits(&serial, &identity, false));
        assert!(!column_takes_edits(&column("data", "blob"), &identity, false));
        assert!(!column_takes_edits(&column("name", "text"), &identity, true));
    }
}
