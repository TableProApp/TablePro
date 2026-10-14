//! Which changes SQLite's own ALTER TABLE makes, per the rules of
//! lang_altertable.html. Anything else rebuilds the table.

use tablepro_core::column::ColumnDefault;
use tablepro_core::ddl::{ColumnDefinition, DdlOperation, DraftColumn, TableChanges, TableDefinition};
use tablepro_core::value::Value;

use super::column_constraint_segment::ColumnConstraintKind;
use super::create_table_source::CreateTableSource;
use super::source_element::TableConstraintKind;

/// The first change that needs a rebuild, named as the error that
/// refuses it would name it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct RebuildChange {
    pub column: String,
    pub operation: DdlOperation,
}

impl RebuildChange {
    fn new(column: &str, operation: DdlOperation) -> Self {
        Self {
            column: column.to_owned(),
            operation,
        }
    }
}

/// `None` when every change has a native statement: a table or column
/// rename, an index created or dropped, a column added or dropped where
/// ALTER TABLE allows it.
pub(super) fn first_rebuild_change(
    original: &TableDefinition,
    source: Option<&CreateTableSource<'_>>,
    changes: &TableChanges,
) -> Option<RebuildChange> {
    for alteration in &changes.altered_columns {
        let changed = alteration.changed;
        let operation = if changed.column_type {
            DdlOperation::AlterColumnType
        } else if changed.nullability {
            DdlOperation::AlterColumnNullability
        } else if changed.default {
            DdlOperation::AlterColumnDefault
        } else if changed.primary_key {
            DdlOperation::AlterPrimaryKey
        } else if changed.auto_increment {
            DdlOperation::AlterAutoIncrement
        } else {
            continue;
        };
        return Some(RebuildChange::new(alteration.original.name(), operation));
    }
    if let Some(change) = &changes.primary_key {
        let column = change
            .to
            .first()
            .or_else(|| change.from.as_ref().and_then(|key| key.columns.first()))
            .map_or("", String::as_str);
        return Some(RebuildChange::new(column, DdlOperation::AlterPrimaryKey));
    }
    if let Some(key) = changes.dropped_foreign_keys.first() {
        let column = key.columns.first().map_or("", String::as_str);
        return Some(RebuildChange::new(column, DdlOperation::DropForeignKey));
    }
    if let Some(key) = changes.added_foreign_keys.first() {
        let column = key.columns.first().map_or("", String::as_str);
        return Some(RebuildChange::new(column, DdlOperation::AddForeignKey));
    }
    if let Some(column) = changes.added_columns.iter().find(|column| !adds_natively(column)) {
        return Some(RebuildChange::new(&column.name, DdlOperation::AddColumn));
    }
    changes
        .dropped_columns
        .iter()
        .find(|column| !drops_natively(original, source, column))
        .map(|column| RebuildChange::new(column.name(), DdlOperation::DropColumn))
}

/// ADD COLUMN takes no key, no default but a constant one, and NOT NULL
/// only with a default the rows already there can take.
fn adds_natively(column: &DraftColumn) -> bool {
    let constant = !matches!(column.default, ColumnDefault::Expression(_));
    let has_value = !matches!(
        column.default,
        ColumnDefault::None | ColumnDefault::Literal(Value::Null)
    );
    !column.primary_key && constant && (column.nullable || has_value)
}

/// DROP COLUMN refuses a key or UNIQUE column, which a rebuild can drop
/// with its constraint. Every other use, by an index, a CHECK, a
/// generated column, a trigger or a view, SQLite checks against the
/// schema itself and refuses by name, which no rebuild could improve on
/// without breaking that use.
fn drops_natively(
    original: &TableDefinition,
    source: Option<&CreateTableSource<'_>>,
    column: &ColumnDefinition,
) -> bool {
    if column.info.primary_key
        || original
            .foreign_keys
            .iter()
            .any(|key| names(&key.columns, column.name()))
    {
        return false;
    }
    let Some(source) = source else {
        return true;
    };
    let own_unique = source
        .columns()
        .find(|(_, source_column)| source_column.name.eq_ignore_ascii_case(column.name()))
        .is_some_and(|(_, source_column)| {
            source_column.segments.iter().any(|segment| {
                matches!(
                    segment.kind,
                    ColumnConstraintKind::Unique | ColumnConstraintKind::PrimaryKey { .. }
                )
            })
        });
    let unique_alone = source.constraints().any(|(_, constraint)| match &constraint.kind {
        TableConstraintKind::Unique { columns } => {
            matches!(columns.as_slice(), [only] if only.eq_ignore_ascii_case(column.name()))
        }
        _ => false,
    });
    !own_unique && !unique_alone
}

pub(super) fn names(columns: &[String], name: &str) -> bool {
    columns.iter().any(|column| column.eq_ignore_ascii_case(name))
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::SqlExpression;
    use tablepro_core::ddl::DraftType;

    use super::*;

    fn column(nullable: bool, default: ColumnDefault) -> DraftColumn {
        let mut column = DraftColumn::new("c", DraftType::Typed("TEXT".to_owned()));
        column.nullable = nullable;
        column.default = default;
        column
    }

    #[test]
    fn add_column_is_native_only_where_alter_table_allows_it() {
        let literal = ColumnDefault::Literal(Value::Text("x".to_owned()));
        let expression = ColumnDefault::Expression(SqlExpression::from_catalog_text("CURRENT_TIMESTAMP"));

        assert!(adds_natively(&column(true, ColumnDefault::None)));
        assert!(adds_natively(&column(false, literal.clone())));
        assert!(!adds_natively(&column(false, ColumnDefault::None)));
        assert!(!adds_natively(&column(false, ColumnDefault::Literal(Value::Null))));
        assert!(!adds_natively(&column(true, expression)));
        let mut keyed = column(false, literal);
        keyed.primary_key = true;
        assert!(!adds_natively(&keyed));
    }
}
