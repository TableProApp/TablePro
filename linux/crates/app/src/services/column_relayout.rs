use tablepro_core::column::ColumnType;
use tablepro_core::edit::parse_literal_text;
use tablepro_core::export::value_text;
use tablepro_core::value::same_value;
use tablepro_core::{ColumnInfo, Value};

use super::change_tracker::RowKey;

/// How the columns a tab's pending changes were made against line up
/// with the columns it read since. Columns are matched by name: once a
/// column is dropped or added, a position names another column.
#[derive(Debug)]
pub(crate) struct ColumnRelayout<'a> {
    old: &'a [ColumnInfo],
    new: &'a [ColumnInfo],
    /// Each old column's position among the new ones.
    positions: Vec<Option<usize>>,
    /// Each new column's position among the old ones.
    sources: Vec<Option<usize>>,
    key_moved: bool,
}

/// Why a pending change has no place under the new columns.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Misfit {
    /// These columns are gone, or no longer take the value.
    Columns(Vec<String>),
    /// The primary key changed, so a row key read under the old one
    /// may name another row, or none.
    Key,
}

impl<'a> ColumnRelayout<'a> {
    pub(crate) fn new(old: &'a [ColumnInfo], new: &'a [ColumnInfo]) -> Self {
        let position = |name: &str, columns: &[ColumnInfo]| columns.iter().position(|column| column.name == name);
        Self {
            old,
            new,
            positions: old.iter().map(|column| position(&column.name, new)).collect(),
            sources: new.iter().map(|column| position(&column.name, old)).collect(),
            key_moved: key_names(old) != key_names(new),
        }
    }

    pub(crate) fn position(&self, col: usize) -> Option<usize> {
        self.positions.get(col).copied().flatten()
    }

    /// Where a value put in old column `col` belongs now.
    pub(crate) fn cell(&self, col: usize, value: &Value) -> Result<usize, Misfit> {
        let misfit = || {
            Misfit::Columns(
                self.old
                    .get(col)
                    .map(|column| column.name.clone())
                    .into_iter()
                    .collect(),
            )
        };
        let (Some(old), Some(moved)) = (self.old.get(col), self.position(col)) else {
            return Err(misfit());
        };
        match fits(value, &old.column_type, &self.new[moved].column_type) {
            true => Ok(moved),
            false => Err(misfit()),
        }
    }

    /// Whether a row key read under the old primary key names the same
    /// row under the new one.
    pub(crate) fn key(&self, key: &RowKey) -> Result<(), Misfit> {
        let RowKey::Persisted(parts) = key else {
            return Ok(());
        };
        if self.key_moved {
            return Err(Misfit::Key);
        }
        let old = self.old.iter().filter(|column| column.primary_key);
        let new = self.new.iter().filter(|column| column.primary_key);
        match parts
            .iter()
            .zip(old.zip(new))
            .all(|(part, (old, new))| fits(part.value(), &old.column_type, &new.column_type))
        {
            true => Ok(()),
            false => Err(Misfit::Key),
        }
    }

    /// A new row's values under the new columns. A value the user left
    /// in a column that is gone, or that no longer takes it, has no
    /// place; an empty cell there is dropped.
    pub(crate) fn row(&self, values: &[Value]) -> Result<Vec<Value>, Misfit> {
        let mut lost = Vec::new();
        for (col, value) in values.iter().enumerate() {
            if matches!(value, Value::Null) {
                continue;
            }
            if let Err(Misfit::Columns(columns)) = self.cell(col, value) {
                lost.extend(columns);
            }
        }
        match lost.is_empty() {
            true => Ok(self.fetched(values)),
            false => Err(Misfit::Columns(lost)),
        }
    }

    /// A row as read under the old columns, under the new ones. A new
    /// column reads as NULL.
    pub(crate) fn fetched(&self, values: &[Value]) -> Vec<Value> {
        self.sources
            .iter()
            .map(|source| source.and_then(|col| values.get(col)).cloned().unwrap_or(Value::Null))
            .collect()
    }
}

fn key_names(columns: &[ColumnInfo]) -> Vec<&str> {
    columns
        .iter()
        .filter(|column| column.primary_key)
        .map(|column| column.name.as_str())
        .collect()
}

/// Whether a value made for a column of type `old` is still the value
/// a column of type `new` would take from the same text. NULL is left
/// to the server, which knows whether the column takes it.
fn fits(value: &Value, old: &ColumnType, new: &ColumnType) -> bool {
    if old == new || matches!(value, Value::Null) {
        return true;
    }
    value_text(value, old)
        .and_then(|text| parse_literal_text(&text, new).ok())
        .is_some_and(|parsed| same_value(&parsed, value))
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnDefault, ColumnKind, IntegerKind, IntegerWidth, TextLength};

    use super::*;

    fn column(name: &str, kind: ColumnKind, primary_key: bool) -> ColumnInfo {
        let mut column_type = ColumnType::untyped_text(name);
        column_type.kind = kind;
        ColumnInfo {
            name: name.to_owned(),
            column_type,
            nullable: !primary_key,
            primary_key,
            is_auto_increment: false,
            is_generated: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn integer(width: IntegerWidth) -> ColumnKind {
        ColumnKind::Integer(IntegerKind { width, signed: true })
    }

    fn text(length: TextLength) -> ColumnKind {
        ColumnKind::Text { length }
    }

    #[test]
    fn a_wider_type_takes_the_value_and_a_narrower_or_other_one_does_not() {
        let int = column("n", integer(IntegerWidth::W32), false);
        let wide = ColumnType {
            kind: integer(IntegerWidth::W64),
            ..int.column_type.clone()
        };
        let narrow = ColumnType {
            kind: integer(IntegerWidth::W8),
            ..int.column_type.clone()
        };
        let words = ColumnType {
            kind: text(TextLength::Unbounded),
            ..int.column_type.clone()
        };

        assert!(fits(&Value::Int(300), &int.column_type, &wide));
        assert!(!fits(&Value::Int(300), &int.column_type, &narrow));
        assert!(!fits(&Value::Int(3), &int.column_type, &words), "a number became text");
        assert!(fits(&Value::Null, &int.column_type, &words));
    }

    #[test]
    fn a_key_column_left_out_of_the_key_moves_every_row_key() {
        let old = [column("id", integer(IntegerWidth::W32), true)];
        let new = [column("id", integer(IntegerWidth::W32), false)];
        let key = RowKey::from_pk_values(&[Value::Int(1)]).expect("a key");

        assert_eq!(ColumnRelayout::new(&old, &new).key(&key), Err(Misfit::Key));
        assert_eq!(ColumnRelayout::new(&old, &old).key(&key), Ok(()));
        assert_eq!(ColumnRelayout::new(&old, &new).key(&RowKey::Draft(1)), Ok(()));
    }
}
