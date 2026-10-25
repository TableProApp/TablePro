use std::sync::Arc;

use tablepro_core::ColumnInfo;
use tablepro_core::column::{ColumnKind, ColumnType, ResultColumn};

/// One column of a grid: the result column, plus the catalogue entry
/// when the host has one.
#[derive(Debug, Clone, PartialEq)]
pub struct GridColumn {
    /// Where the column's value sits in a row.
    pub index: usize,
    pub name: String,
    /// The type the result set gives the column, which a value is
    /// written out in.
    pub column_type: ColumnType,
    pub catalog: Option<ColumnInfo>,
    /// Whether a filter, a sort or an update can name the column (ADR 0026).
    pub addressable: bool,
}

/// How a column's cells draw.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CellDisplay {
    Text,
    Number,
    Bool,
    Temporal,
    Json,
    Binary,
}

impl GridColumn {
    pub fn result_column(&self) -> ResultColumn {
        ResultColumn::new(self.name.clone(), self.column_type.clone())
    }

    pub fn display(&self) -> CellDisplay {
        match &self.column_type.kind {
            ColumnKind::Bool(_) => CellDisplay::Bool,
            ColumnKind::Integer(_) | ColumnKind::Float(_) | ColumnKind::Decimal { .. } | ColumnKind::Money { .. } => {
                CellDisplay::Number
            }
            ColumnKind::Date | ColumnKind::Time { .. } | ColumnKind::Timestamp { .. } => CellDisplay::Temporal,
            ColumnKind::Json { .. } => CellDisplay::Json,
            ColumnKind::Bytes { .. } => CellDisplay::Binary,
            ColumnKind::Text { .. }
            | ColumnKind::Enum { .. }
            | ColumnKind::Uuid
            | ColumnKind::Interval
            | ColumnKind::BitString { .. }
            | ColumnKind::Network(_)
            | ColumnKind::Xml
            | ColumnKind::Spatial
            | ColumnKind::Array { .. }
            | ColumnKind::Variant
            | ColumnKind::Composite
            | ColumnKind::Other => CellDisplay::Text,
        }
    }

    /// The type a value is typed and parsed in: the catalogue's where the
    /// grid has it, since that is what an UPDATE writes.
    pub fn value_type(&self) -> &ColumnType {
        self.catalog
            .as_ref()
            .map_or(&self.column_type, |catalog| &catalog.column_type)
    }

    /// The server fills these in, so a new row shows a placeholder
    /// rather than an empty cell.
    pub fn auto_filled(&self) -> bool {
        self.catalog
            .as_ref()
            .is_some_and(|catalog| catalog.is_auto_increment || catalog.is_generated)
    }

    pub fn sortable(&self) -> bool {
        self.addressable
    }
}

/// The grid's columns, each matched to the catalogue entry at its own
/// index, as the browse page reads them in catalogue order.
pub fn grid_columns(
    result: &[ResultColumn],
    catalog: &[ColumnInfo],
    addressable: impl Fn(&str) -> bool,
) -> Arc<[GridColumn]> {
    result
        .iter()
        .enumerate()
        .map(|(index, column)| GridColumn {
            index,
            name: column.name.clone(),
            column_type: column.column_type.clone(),
            catalog: catalog.get(index).cloned(),
            addressable: addressable(&column.name),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{
        BoolStorage, ColumnKind, ColumnType, FloatWidth, IntegerKind, IntegerWidth, ResultColumn, TemporalZone,
        TextLength,
    };

    use super::{CellDisplay, grid_columns};
    use crate::services::grid::test_columns::{grid, grid_of_kind, info, result_only};

    fn display(kind: ColumnKind) -> CellDisplay {
        result_only("c", kind).display()
    }

    #[test]
    fn display_follows_the_column_kind() {
        let integer = ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W64,
            signed: true,
        });

        assert_eq!(display(integer), CellDisplay::Number);
        assert_eq!(display(ColumnKind::Float(FloatWidth::F32)), CellDisplay::Number);
        assert_eq!(
            display(ColumnKind::Decimal {
                precision: None,
                scale: None
            }),
            CellDisplay::Number
        );
        assert_eq!(display(ColumnKind::Money { scale: Some(2) }), CellDisplay::Number);
        assert_eq!(display(ColumnKind::Bool(BoolStorage::Integer)), CellDisplay::Bool);
        assert_eq!(display(ColumnKind::Date), CellDisplay::Temporal);
        assert_eq!(
            display(ColumnKind::Timestamp {
                fractional_digits: None,
                zone: TemporalZone::Offset
            }),
            CellDisplay::Temporal
        );
        assert_eq!(display(ColumnKind::Json { binary: true }), CellDisplay::Json);
        assert_eq!(
            display(ColumnKind::Bytes {
                length: TextLength::Unbounded
            }),
            CellDisplay::Binary
        );
        assert_eq!(display(ColumnKind::Other), CellDisplay::Text);
        assert_eq!(display(ColumnKind::Interval), CellDisplay::Text);
    }

    #[test]
    fn grid_columns_match_the_catalogue_by_index() {
        let result = [
            ResultColumn::new("id", ColumnType::untyped_text("int")),
            ResultColumn::new("a.b", ColumnType::untyped_text("text")),
        ];
        let catalog = [info("id", "integer")];

        let columns = grid_columns(&result, &catalog, |name| !name.contains('.'));

        assert_eq!(columns.len(), 2);
        assert_eq!(
            columns[0].catalog.as_ref().map(|column| column.name.as_str()),
            Some("id")
        );
        assert_eq!(columns[1].index, 1);
        assert_eq!(columns[1].catalog, None, "a column past the catalogue");
        assert!(columns[0].sortable());
        assert!(!columns[1].addressable);
        assert!(!columns[1].sortable(), "an unaddressable field sorted");
        assert_eq!(columns[1].result_column(), result[1]);
        assert_eq!(columns[0].value_type(), &catalog[0].column_type);
        assert_eq!(columns[1].value_type(), &result[1].column_type);
    }

    #[test]
    fn auto_filled_needs_a_catalogue_that_says_so() {
        let mut serial = info("id", "integer");
        serial.is_auto_increment = true;
        let mut total = info("total", "integer");
        total.is_generated = true;

        assert!(grid(serial).auto_filled());
        assert!(grid(total).auto_filled());
        assert!(!grid_of_kind("name", ColumnKind::Other).auto_filled());
        assert!(!result_only("id", ColumnKind::Other).auto_filled());
    }
}
