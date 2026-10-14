use tablepro_core::ColumnInfo;

use super::GridRowId;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CellPreset {
    Empty,
    Null,
    /// Leave the column out of the new row's INSERT.
    Default,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CellPresets {
    pub empty: bool,
    pub null: bool,
    pub default: bool,
}

/// Only an INSERT can leave a column out, so Default is for new rows
/// alone, and only where the server has something to fill in.
pub fn cell_presets(column: &ColumnInfo, row: &GridRowId) -> CellPresets {
    let server_fills = !column.default.is_none() || column.is_auto_increment || column.is_generated;
    CellPresets {
        empty: column.column_type.kind.accepts_empty_string(),
        null: column.nullable,
        default: matches!(row, GridRowId::Draft(_)) && server_fills,
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnDefault, ColumnKind, ColumnType, IntegerKind, IntegerWidth, TextLength};
    use tablepro_core::{ColumnInfo, Value};

    use super::{CellPresets, cell_presets};
    use crate::services::change_tracker::RowKey;
    use crate::ui::grid::GridRowId;

    fn column(kind: ColumnKind, nullable: bool, default: ColumnDefault) -> ColumnInfo {
        let mut column_type = ColumnType::untyped_text("t");
        column_type.kind = kind;
        ColumnInfo {
            name: "c".to_owned(),
            column_type,
            nullable,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default,
            comment: None,
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
        let saved = GridRowId::Persisted(RowKey::from_pk_values(&[Value::Int(1)]).expect("a key"));
        let draft = GridRowId::Draft(1);
        let presets = |empty, null, default| CellPresets { empty, null, default };

        assert_eq!(
            cell_presets(&column(text.clone(), true, ColumnDefault::None), &saved),
            presets(true, true, false)
        );
        assert_eq!(
            cell_presets(&column(text, false, ColumnDefault::None), &draft),
            presets(true, false, false),
            "a column with nothing to fill offered Default"
        );
        assert_eq!(
            cell_presets(&column(integer.clone(), false, now.clone()), &draft),
            presets(false, false, true)
        );
        assert_eq!(
            cell_presets(&column(integer.clone(), true, now), &saved),
            presets(false, true, false),
            "a saved row offered Default"
        );
        let mut serial = column(integer, false, ColumnDefault::None);
        serial.is_auto_increment = true;
        assert_eq!(cell_presets(&serial, &draft), presets(false, false, true));
    }
}
