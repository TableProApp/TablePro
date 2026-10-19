//! Keyset (seek) pagination helpers for large OFFSET values.

use crate::query::Value;
use crate::sql_dialect::{placeholder_for, quote_ident};

/// When browse offset exceeds this threshold and primary-key columns are
/// known, prefer seeking by the last-seen PK values instead of OFFSET.
pub const KEYSET_OFFSET_THRESHOLD: u64 = 10_000;

/// Build a keyset predicate `(pk0, pk1, …) > (v0, v1, …)` expanded into
/// portable SQL that works across Postgres, MySQL, SQLite, and MSSQL.
///
/// Returns `(sql_fragment, bind_params)`. The fragment has no leading
/// `AND` / `WHERE`; callers prepend as needed. Placeholders start at
/// `placeholder_start` (0-based index into the driver's placeholder
/// scheme).
///
/// Requires `pk_columns.len() == last_values.len()` and non-empty.
pub fn keyset_where_clause(
    driver_id: &str,
    pk_columns: &[&str],
    last_values: &[Value],
    placeholder_start: usize,
) -> Result<(String, Vec<Value>), KeysetError> {
    keyset_where_comparison(driver_id, pk_columns, last_values, placeholder_start, ">")
}

pub fn keyset_before_where_clause(
    driver_id: &str,
    pk_columns: &[&str],
    first_values: &[Value],
    placeholder_start: usize,
) -> Result<(String, Vec<Value>), KeysetError> {
    keyset_where_comparison(driver_id, pk_columns, first_values, placeholder_start, "<")
}

fn keyset_where_comparison(
    driver_id: &str,
    pk_columns: &[&str],
    boundary_values: &[Value],
    placeholder_start: usize,
    comparison: &str,
) -> Result<(String, Vec<Value>), KeysetError> {
    if pk_columns.is_empty() {
        return Err(KeysetError::EmptyKeys);
    }
    if pk_columns.len() != boundary_values.len() {
        return Err(KeysetError::LengthMismatch {
            columns: pk_columns.len(),
            values: boundary_values.len(),
        });
    }
    if driver_id == "postgres"
        && pk_columns.len() > 1
        && boundary_values.iter().all(|value| !matches!(value, Value::Null))
    {
        let columns = pk_columns
            .iter()
            .map(|column| quote_ident(driver_id, column))
            .collect::<Vec<_>>()
            .join(", ");
        let values = (placeholder_start..placeholder_start + boundary_values.len())
            .map(|index| placeholder_for(driver_id, index))
            .collect::<Vec<_>>()
            .join(", ");
        return Ok((format!("({columns}) {comparison} ({values})"), boundary_values.to_vec()));
    }

    // (a, b, c) > (x, y, z) expands to:
    //   a > x
    //   OR (a = x AND b > y)
    //   OR (a = x AND b = y AND c > z)
    // NULL PK components use IS NULL / IS NOT NULL carefully: a NULL
    // last value means "seek past NULL" is undefined for strict >; we
    // treat NULL last values as unmatched equality only (IS NULL) and
    // never emit `col > NULL`.
    let mut or_arms: Vec<String> = Vec::with_capacity(pk_columns.len());
    let mut params: Vec<Value> = Vec::new();
    let mut placeholder_idx = placeholder_start;

    for depth in 0..pk_columns.len() {
        if matches!(boundary_values[depth], Value::Null) {
            continue;
        }
        let mut and_parts: Vec<String> = Vec::with_capacity(depth + 1);
        for eq_i in 0..depth {
            let ident = quote_ident(driver_id, pk_columns[eq_i]);
            if matches!(boundary_values[eq_i], Value::Null) {
                and_parts.push(format!("{ident} IS NULL"));
            } else {
                and_parts.push(format!("{ident} = {}", placeholder_for(driver_id, placeholder_idx)));
                placeholder_idx += 1;
                params.push(boundary_values[eq_i].clone());
            }
        }

        let ident = quote_ident(driver_id, pk_columns[depth]);
        and_parts.push(format!(
            "{ident} {comparison} {}",
            placeholder_for(driver_id, placeholder_idx)
        ));
        placeholder_idx += 1;
        params.push(boundary_values[depth].clone());

        if let [only] = and_parts.as_slice() {
            or_arms.push(only.clone());
        } else {
            or_arms.push(format!("({})", and_parts.join(" AND ")));
        }
    }

    if or_arms.is_empty() {
        return Err(KeysetError::AllNullKeys);
    }

    let sql = if let [only] = or_arms.as_slice() {
        only.clone()
    } else {
        format!("({})", or_arms.join(" OR "))
    };
    Ok((sql, params))
}

/// ORDER BY clause for keyset paging (ascending PK order), including
/// the leading space. Empty when `pk_columns` is empty.
pub fn keyset_order_by(driver_id: &str, pk_columns: &[&str]) -> String {
    keyset_order_by_direction(driver_id, pk_columns, false)
}

pub fn keyset_order_by_before(driver_id: &str, pk_columns: &[&str]) -> String {
    keyset_order_by_direction(driver_id, pk_columns, true)
}

fn keyset_order_by_direction(driver_id: &str, pk_columns: &[&str], descending: bool) -> String {
    if pk_columns.is_empty() {
        return String::new();
    }
    let direction = if descending { "DESC" } else { "ASC" };
    let parts: Vec<String> = pk_columns
        .iter()
        .map(|c| format!("{} {direction}", quote_ident(driver_id, c)))
        .collect();
    format!(" ORDER BY {}", parts.join(", "))
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum KeysetError {
    #[error("keyset pagination requires at least one primary-key column")]
    EmptyKeys,
    #[error("pk column count {columns} does not match value count {values}")]
    LengthMismatch { columns: usize, values: usize },
    #[error("all primary-key values are NULL; cannot build a keyset seek")]
    AllNullKeys,
}

#[cfg(test)]
mod tests {

    #[test]
    fn a_null_key_after_the_first_binds_exactly_one_value_per_placeholder() {
        let (sql, params) = keyset_where_clause(
            "postgres",
            &["a", "b", "c"],
            &[Value::Int(1), Value::Null, Value::Int(3)],
            0,
        )
        .unwrap();

        assert_eq!(sql, r#"("a" > $1 OR ("a" = $2 AND "b" IS NULL AND "c" > $3))"#);
        assert_eq!(params, vec![Value::Int(1), Value::Int(1), Value::Int(3)]);
    }

    use super::*;

    #[test]
    fn single_pk_postgres() {
        let (sql, params) = keyset_where_clause("postgres", &["id"], &[Value::Int(42)], 0).unwrap();
        assert_eq!(sql, "\"id\" > $1");
        assert_eq!(params, vec![Value::Int(42)]);
    }

    #[test]
    fn previous_keyset_uses_strict_less_than_and_preserves_composite_tie_breakers() {
        let (sql, params) =
            keyset_before_where_clause("postgres", &["tenant_id", "id"], &[Value::Int(7), Value::Int(42)], 2).unwrap();

        assert_eq!(sql, r#"("tenant_id", "id") < ($3, $4)"#);
        assert_eq!(params, vec![Value::Int(7), Value::Int(42)]);
    }

    #[test]
    fn previous_keyset_keeps_null_prefixes_as_is_null() {
        let (sql, params) = keyset_before_where_clause(
            "mysql",
            &["a", "b", "c"],
            &[Value::Int(1), Value::Null, Value::Int(3)],
            0,
        )
        .unwrap();

        assert_eq!(sql, "(`a` < ? OR (`a` = ? AND `b` IS NULL AND `c` < ?))");
        assert_eq!(params, vec![Value::Int(1), Value::Int(1), Value::Int(3)]);
    }

    #[test]
    fn composite_pk_mysql() {
        let (sql, params) =
            keyset_where_clause("mysql", &["a", "b"], &[Value::Int(1), Value::Text("x".into())], 0).unwrap();
        assert_eq!(sql, "(`a` > ? OR (`a` = ? AND `b` > ?))");
        assert_eq!(params, vec![Value::Int(1), Value::Int(1), Value::Text("x".into())]);
    }

    #[test]
    fn placeholder_offset() {
        let (sql, _) = keyset_where_clause("postgres", &["id"], &[Value::Int(7)], 3).unwrap();
        assert_eq!(sql, "\"id\" > $4");
    }

    #[test]
    fn rejects_empty_and_mismatch() {
        assert!(matches!(
            keyset_where_clause("postgres", &[], &[], 0),
            Err(KeysetError::EmptyKeys)
        ));
        assert!(matches!(
            keyset_where_clause("postgres", &["id"], &[], 0),
            Err(KeysetError::LengthMismatch { .. })
        ));
    }

    #[test]
    fn order_by_dialect() {
        assert_eq!(keyset_order_by("postgres", &["id"]), " ORDER BY \"id\" ASC");
        assert_eq!(keyset_order_by("mysql", &["a", "b"]), " ORDER BY `a` ASC, `b` ASC");
        assert_eq!(
            keyset_order_by_before("postgres", &["tenant_id", "id"]),
            " ORDER BY \"tenant_id\" DESC, \"id\" DESC"
        );
    }
}
