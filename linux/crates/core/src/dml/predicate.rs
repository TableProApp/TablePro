use crate::dialect::{BindTarget, SqlDialect};
use crate::statement::BoundParam;
use crate::value::Value;

use super::{BuildSqlError, KeyComponent};

/// The WHERE clause that names one row, and the parameters it binds.
///
/// A NULL key part renders `IS NULL` with no marker: `= NULL` is never
/// true, so binding it would silently match nothing.
pub(super) fn key_predicate(
    dialect: &dyn SqlDialect,
    components: &[KeyComponent<'_>],
    key: &[Value],
    first_ordinal: usize,
) -> Result<(String, Vec<BoundParam>), BuildSqlError> {
    if key.len() != components.len() {
        return Err(BuildSqlError::LengthMismatch {
            expected: components.len(),
            found: key.len(),
        });
    }

    let mut clauses = Vec::with_capacity(components.len());
    let mut params = Vec::new();
    for (component, value) in components.iter().zip(key) {
        if matches!(value, Value::Undecodable(_)) {
            return Err(BuildSqlError::UndecodableKey);
        }
        let column_sql = match component {
            KeyComponent::Column(column) => dialect.quote_identifier(&column.name),
            KeyComponent::EngineRowId(part) => dialect
                .engine_row_id_column(*part)
                .ok_or(BuildSqlError::NoRowIdentity)?,
        };
        if value.is_null() {
            clauses.push(format!("{column_sql} IS NULL"));
            continue;
        }
        let target = match component {
            KeyComponent::Column(column) => BindTarget::Column(column),
            KeyComponent::EngineRowId(part) => BindTarget::EngineRowId(*part),
        };
        let placeholder = dialect.placeholder(first_ordinal + params.len(), value.clone(), target)?;
        clauses.push(format!("{column_sql} = {}", placeholder.sql));
        if let Some(param) = placeholder.param {
            params.push(param);
        }
    }
    Ok((clauses.join(" AND "), params))
}
