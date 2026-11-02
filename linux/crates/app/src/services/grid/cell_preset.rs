use tablepro_core::dialect::SqlDialect;

use super::{GridColumn, GridRowId};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CellPreset {
    Empty,
    Null,
    /// Leave the column out of a new row's INSERT, or set a saved row's
    /// cell to `DEFAULT`.
    Default,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct CellPresets {
    pub empty: bool,
    pub null: bool,
    pub default: bool,
}

/// Default is offered where the server has something to fill in: on a
/// new row, whose INSERT leaves the column out, and on a saved row only
/// for a declared default where the engine parses `SET c = DEFAULT`. A
/// column the catalogue does not know takes none.
pub fn cell_presets(column: &GridColumn, row: &GridRowId, dialect: Option<&dyn SqlDialect>) -> CellPresets {
    let Some(catalog) = column.catalog.as_ref() else {
        return CellPresets::default();
    };
    let declared = !catalog.default.is_none() && !catalog.is_generated;
    let default = match row {
        GridRowId::Draft(_) => declared || catalog.is_auto_increment || catalog.is_generated,
        GridRowId::Persisted(_) => declared && dialect.is_some_and(SqlDialect::update_sets_default),
        GridRowId::Result | GridRowId::Unkeyed => false,
    };
    CellPresets {
        empty: catalog.column_type.kind.accepts_empty_string(),
        null: catalog.nullable,
        default,
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::ColumnInfo;
    use tablepro_core::column::{ColumnDefault, ColumnKind, IntegerKind, IntegerWidth, TextLength};

    use super::{CellPresets, cell_presets};
    use crate::services::grid::GridRowId;
    use crate::services::grid::test_columns::{grid, info_of_kind, persisted, result_only};

    fn column(kind: ColumnKind, nullable: bool, default: ColumnDefault) -> ColumnInfo {
        ColumnInfo {
            nullable,
            default,
            ..info_of_kind("c", kind)
        }
    }

    #[test]
    #[expect(
        clippy::disallowed_methods,
        reason = "a test fixture stands in for the catalogue, which is where a default expression comes from"
    )]
    fn presets_enabled_per_kind_nullability_and_draft() {
        let text = ColumnKind::Text {
            length: TextLength::Unbounded,
        };
        let integer = ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W32,
            signed: true,
        });
        let now = ColumnDefault::Expression(tablepro_core::column::SqlExpression::from_catalog_text("now()"));
        let saved = persisted();
        let draft = GridRowId::Draft(1);
        let presets = |empty, null, default| CellPresets { empty, null, default };
        let of = |info: ColumnInfo, row: &GridRowId| cell_presets(&grid(info), row, None);

        assert_eq!(
            of(column(text.clone(), true, ColumnDefault::None), &saved),
            presets(true, true, false)
        );
        assert_eq!(
            of(column(text, false, ColumnDefault::None), &draft),
            presets(true, false, false),
            "a column with nothing to fill offered Default"
        );
        assert_eq!(
            of(column(integer.clone(), false, now.clone()), &draft),
            presets(false, false, true)
        );
        assert_eq!(
            of(column(integer.clone(), true, now.clone()), &saved),
            presets(false, true, false),
            "a saved row offered Default where the engine has no SET c = DEFAULT"
        );
        let postgres =
            tablepro_driver_postgres::PgDialect::new(&tablepro_core::ServerInfo::new("PostgreSQL", "18.0", 18, 0, 0));
        assert_eq!(
            cell_presets(&grid(column(integer.clone(), true, now)), &saved, Some(&postgres)),
            presets(false, true, true)
        );
        let mut counted = column(integer.clone(), false, ColumnDefault::None);
        counted.is_auto_increment = true;
        assert_eq!(
            cell_presets(&grid(counted), &saved, Some(&postgres)),
            presets(false, false, false),
            "a saved row offered a new number"
        );
        let mut serial = column(integer.clone(), false, ColumnDefault::None);
        serial.is_auto_increment = true;
        assert_eq!(of(serial, &draft), presets(false, false, true));
        assert_eq!(
            cell_presets(&result_only("c", integer), &draft, None),
            CellPresets::default(),
            "a column the catalogue does not know"
        );
    }
}
