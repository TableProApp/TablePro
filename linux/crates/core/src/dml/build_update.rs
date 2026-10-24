use crate::column::ColumnInfo;
use crate::dialect::{BindTarget, SqlDialect};
use crate::meta::{RowIdentity, TableRef};
use crate::statement::{Statement, StatementBuilder};
use crate::value::Value;

use super::predicate::key_predicate;
use super::{BuildSqlError, KeyComponent, key_components};

/// The UPDATE for one row's changed cells.
///
/// Only the cells that moved are assigned, so a save does not rewrite
/// columns the user never touched and trigger their side effects.
pub fn build_update(
    dialect: &dyn SqlDialect,
    table: &TableRef,
    columns: &[ColumnInfo],
    identity: &RowIdentity,
    key: &[Value],
    assignments: &[(usize, Value)],
) -> Result<Statement, BuildSqlError> {
    if crate::document::speaks_shell(dialect) {
        return crate::document::update(table, columns, identity, key, assignments);
    }
    if assignments.is_empty() {
        return Err(BuildSqlError::NothingToUpdate);
    }
    let (components, key) = update_scope(columns, assignments, key_components(identity, columns)?, key);

    let mut builder = StatementBuilder::new();
    let mut set = Vec::with_capacity(assignments.len());
    for (index, value) in assignments {
        let column = columns.get(*index).ok_or(BuildSqlError::UnknownKeyColumn {
            name: index.to_string(),
        })?;
        let marker = builder.bind(dialect, value.clone(), BindTarget::Column(column))?;
        set.push(format!("{} = {marker}", dialect.quote_identifier(&column.name)));
    }
    let predicate = key_predicate(&mut builder, dialect, &components, &key)?;

    let table_sql = dialect.qualify(table);
    let sql = match sets_partition_only(columns, assignments) {
        true => dialect.partition_update_statement(&table_sql, &set.join(", "), &predicate),
        false => dialect.update_statement(&table_sql, &set.join(", "), &predicate),
    };
    builder.push_sql(&sql);
    Ok(builder.finish())
}

/// Whether every column the update sets holds one value per partition,
/// so the update changes the partition rather than the row.
pub(crate) fn sets_partition_only(columns: &[ColumnInfo], assignments: &[(usize, Value)]) -> bool {
    !assignments.is_empty()
        && assignments
            .iter()
            .all(|(index, _)| columns.get(*index).is_some_and(|column| column.partition_scoped))
}

/// The key an update names: the whole key, or for an update of
/// partition-scoped columns alone (CQL static columns) the partition
/// key only, the one restriction CQL takes for it.
fn update_scope<'a>(
    columns: &[ColumnInfo],
    assignments: &[(usize, Value)],
    components: Vec<KeyComponent<'a>>,
    key: &[Value],
) -> (Vec<KeyComponent<'a>>, Vec<Value>) {
    let scoped =
        |component: &KeyComponent<'_>| matches!(component, KeyComponent::Column(column) if column.partition_scoped);
    if !sets_partition_only(columns, assignments) || components.len() != key.len() || !components.iter().any(scoped) {
        return (components, key.to_vec());
    }
    components
        .into_iter()
        .zip(key.iter().cloned())
        .filter(|(component, _)| scoped(component))
        .unzip()
}
