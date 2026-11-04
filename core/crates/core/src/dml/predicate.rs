use crate::dialect::{BindTarget, SqlDialect};
use crate::statement::StatementBuilder;
use crate::value::Value;

use super::{BuildSqlError, KeyComponent};

/// The predicate that names one row, with its values bound in
/// `builder`.
///
/// A NULL key part renders `IS NULL` with no marker: `= NULL` is never
/// true, so binding it would silently match nothing.
pub(super) fn key_predicate(
    builder: &mut StatementBuilder,
    dialect: &dyn SqlDialect,
    components: &[KeyComponent<'_>],
    key: &[Value],
) -> Result<String, BuildSqlError> {
    if key.len() != components.len() {
        return Err(BuildSqlError::LengthMismatch {
            expected: components.len(),
            found: key.len(),
        });
    }
    if key.iter().any(|value| matches!(value, Value::Undecodable(_))) {
        return Err(BuildSqlError::UndecodableKey);
    }

    let mut clauses = Vec::with_capacity(components.len());
    for (component, value) in components.iter().zip(key) {
        let (column_sql, target) = match component {
            KeyComponent::Column(column) => (dialect.quote_identifier(&column.name), BindTarget::Column(column)),
            KeyComponent::EngineRowId(part) => (
                dialect
                    .engine_row_id_column(*part)
                    .ok_or(BuildSqlError::NoRowIdentity)?,
                BindTarget::EngineRowId(*part),
            ),
        };
        if value.is_null() {
            clauses.push(format!("{column_sql} IS NULL"));
            continue;
        }
        let marker = builder.bind(dialect, value.clone(), target)?;
        clauses.push(format!("{column_sql} = {marker}"));
    }
    Ok(clauses.join(" AND "))
}
