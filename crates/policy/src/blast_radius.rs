use sqlparser::ast::{
    Delete, Expr, FromTable, Insert, SetExpr, Statement, TableFactor, TableObject, TableWithJoins, UpdateTableFromKind,
};
use sqlparser::dialect::{Dialect, GenericDialect, MsSqlDialect, MySqlDialect, PostgreSqlDialect, SQLiteDialect};
use sqlparser::parser::Parser;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlastRadiusResult {
    pub count_sql: String,
    pub tables: Vec<String>,
}

/// What it takes to learn how many rows a mutation would affect.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BlastRadiusRewrite {
    /// The row count is already known from the parsed statement; running a
    /// query would only add a needless round trip and audit record.
    Known(u64),
    /// Run `count_sql` against the database to learn the row count.
    CountQuery(BlastRadiusResult),
}

/// Rewrite an UPDATE, DELETE, or INSERT into something the guard can use to
/// measure blast radius before executing. Returns `None` when the statement
/// is not a single one of those or cannot be rewritten safely; callers must
/// treat `None` as "unknown", not "zero rows".
pub fn count_sql_for_mutation(sql: &str, driver_id: &str) -> Option<BlastRadiusRewrite> {
    let dialect = dialect_for(driver_id);
    let statements = Parser::parse_sql(dialect.as_ref(), sql.trim()).ok()?;
    analyze_blast_radius(&statements, driver_id).0
}

pub(crate) fn analyze_blast_radius(
    statements: &[Statement],
    driver_id: &str,
) -> (Option<BlastRadiusRewrite>, Vec<Option<u64>>) {
    if statements.len() == 1 {
        let rewrite = rewrite_for_statement(&statements[0], driver_id);
        let known_rows = match &rewrite {
            Some(BlastRadiusRewrite::Known(rows)) => Some(*rows),
            _ => None,
        };
        return (rewrite, vec![known_rows]);
    }
    let mut total = 0u64;
    let mut all_known = !statements.is_empty();
    let known_rows = statements
        .iter()
        .map(|statement| match rewrite_for_statement(statement, driver_id) {
            Some(BlastRadiusRewrite::Known(rows)) => {
                total += rows;
                Some(rows)
            }
            Some(BlastRadiusRewrite::CountQuery(_)) | None => {
                all_known = false;
                None
            }
        })
        .collect();
    let rewrite = if all_known {
        Some(BlastRadiusRewrite::Known(total))
    } else {
        None
    };
    (rewrite, known_rows)
}

fn rewrite_for_statement(statement: &Statement, driver_id: &str) -> Option<BlastRadiusRewrite> {
    match statement {
        Statement::Update {
            table, from, selection, ..
        } => {
            let mut sources = vec![table.clone()];
            if let Some(extra) = from {
                let (UpdateTableFromKind::BeforeSet(more) | UpdateTableFromKind::AfterSet(more)) = extra;
                sources.extend(more.clone());
            }
            let tables = sources.iter().flat_map(table_names_from_with_joins).collect();
            Some(BlastRadiusRewrite::CountQuery(build_count_sql(
                &sources,
                selection.as_ref(),
                tables,
                driver_id,
            )))
        }
        Statement::Delete(Delete {
            from, using, selection, ..
        }) => {
            let list = match from {
                FromTable::WithFromKeyword(t) | FromTable::WithoutKeyword(t) => t,
            };
            let mut sources = list.clone();
            if let Some(more) = using {
                sources.extend(more.clone());
            }
            let tables = sources.iter().flat_map(table_names_from_with_joins).collect();
            Some(BlastRadiusRewrite::CountQuery(build_count_sql(
                &sources,
                selection.as_ref(),
                tables,
                driver_id,
            )))
        }
        Statement::Insert(insert) => count_sql_for_insert(insert, driver_id),
        _ => None,
    }
}

/// `INSERT ... VALUES (...), (...)` is counted from the literal row list, no
/// database round trip needed. `INSERT ... SELECT ...` wraps the source
/// query so its row count is measured the same way a bulk `INSERT ... SELECT
/// * FROM huge_table` would actually affect `huge_table`'s row count.
fn count_sql_for_insert(insert: &Insert, driver_id: &str) -> Option<BlastRadiusRewrite> {
    let tables = match &insert.table {
        TableObject::TableName(name) => vec![name.to_string()],
        TableObject::TableFunction(f) => vec![f.name.to_string()],
    };
    let Some(source) = &insert.source else {
        return Some(BlastRadiusRewrite::Known(1));
    };
    if let SetExpr::Values(values) = source.body.as_ref() {
        return Some(BlastRadiusRewrite::Known(values.rows.len() as u64));
    }
    Some(BlastRadiusRewrite::CountQuery(BlastRadiusResult {
        count_sql: format!(
            "SELECT {} FROM ({source}) AS blast_radius_estimate",
            count_fn(driver_id)
        ),
        tables,
    }))
}

fn build_count_sql(
    from: &[TableWithJoins],
    selection: Option<&Expr>,
    tables: Vec<String>,
    driver_id: &str,
) -> BlastRadiusResult {
    let table_sql = from.iter().map(ToString::to_string).collect::<Vec<_>>().join(", ");
    let where_sql = selection.map(|s| format!(" WHERE {s}")).unwrap_or_default();
    BlastRadiusResult {
        count_sql: format!("SELECT {} FROM {table_sql}{where_sql}", count_fn(driver_id)),
        tables,
    }
}

fn count_fn(driver_id: &str) -> &'static str {
    if driver_id == "mssql" {
        "COUNT_BIG(*)"
    } else {
        "count(*)"
    }
}

fn table_names_from_with_joins(twj: &TableWithJoins) -> Vec<String> {
    let mut out = table_names_from_factor(&twj.relation);
    for join in &twj.joins {
        out.extend(table_names_from_factor(&join.relation));
    }
    out
}

fn table_names_from_factor(factor: &TableFactor) -> Vec<String> {
    match factor {
        TableFactor::Table { name, .. } => vec![name.to_string()],
        _ => Vec::new(),
    }
}

fn dialect_for(driver_id: &str) -> Box<dyn Dialect> {
    match driver_id {
        "postgres" => Box::new(PostgreSqlDialect {}),
        "mysql" => Box::new(MySqlDialect {}),
        "sqlite" => Box::new(SQLiteDialect {}),
        "mssql" => Box::new(MsSqlDialect {}),
        _ => Box::new(GenericDialect {}),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn count_query(sql: &str, driver_id: &str) -> BlastRadiusResult {
        match count_sql_for_mutation(sql, driver_id).unwrap() {
            BlastRadiusRewrite::CountQuery(result) => result,
            BlastRadiusRewrite::Known(rows) => panic!("expected a count query, got a known count of {rows}"),
        }
    }

    #[test]
    fn rewrite_delete_with_where() {
        let r = count_query("DELETE FROM payments WHERE status = 'x'", "postgres");
        let sql = r.count_sql.to_lowercase();
        assert!(sql.contains("count"), "{sql}");
        assert!(sql.contains("payments"), "{sql}");
        assert!(sql.contains("where"), "{sql}");
    }

    #[test]
    fn rewrite_update() {
        let r = count_query("UPDATE t SET a = 1 WHERE id = 2", "postgres");
        assert!(r.count_sql.to_lowercase().contains("count"));
        assert!(r.tables.iter().any(|t| t.contains('t')));
    }

    #[test]
    fn select_returns_none() {
        assert!(count_sql_for_mutation("SELECT * FROM t", "postgres").is_none());
    }

    #[test]
    fn an_update_join_is_not_dropped_from_the_count() {
        let r = count_query("UPDATE a JOIN b ON a.id = b.id SET a.x = 1 WHERE b.flag = 1", "mysql");
        let sql = r.count_sql.to_lowercase();
        assert!(sql.contains("join b"), "{sql}");
        assert!(r.tables.iter().any(|t| t == "a"));
        assert!(r.tables.iter().any(|t| t == "b"));
    }

    #[test]
    fn a_delete_using_clause_is_not_dropped_from_the_count() {
        let r = count_query("DELETE FROM a USING b WHERE a.id = b.id", "postgres");
        let sql = r.count_sql.to_lowercase();
        assert!(sql.contains('b'), "{sql}");
        assert!(r.tables.iter().any(|t| t == "b"));
    }

    #[test]
    fn an_update_from_clause_is_not_dropped_from_the_count() {
        let r = count_query("UPDATE a SET x = 1 FROM b WHERE a.id = b.id", "postgres");
        let sql = r.count_sql.to_lowercase();
        assert!(sql.contains('b'), "{sql}");
        assert!(r.tables.iter().any(|t| t == "b"));
    }

    #[test]
    fn insert_values_is_a_known_count_with_no_query() {
        let rewrite = count_sql_for_mutation("INSERT INTO t (a) VALUES (1), (2), (3)", "postgres").unwrap();
        assert_eq!(rewrite, BlastRadiusRewrite::Known(3));
    }

    #[test]
    fn insert_select_is_rewritten_into_a_count_query() {
        let r = count_query("INSERT INTO t SELECT * FROM huge_table", "postgres");
        let sql = r.count_sql.to_lowercase();
        assert!(sql.contains("count"), "{sql}");
        assert!(sql.contains("huge_table"), "{sql}");
    }

    #[test]
    fn a_batch_of_literal_insert_values_sums_to_a_known_count() {
        let rewrite = count_sql_for_mutation(
            "INSERT INTO t (a) VALUES (1);\nINSERT INTO t (a) VALUES (2), (3)",
            "postgres",
        )
        .unwrap();
        assert_eq!(rewrite, BlastRadiusRewrite::Known(3));
    }

    #[test]
    fn a_batch_mixing_a_known_and_an_unknown_statement_stays_unknown() {
        let rewrite = count_sql_for_mutation(
            "INSERT INTO t (a) VALUES (1);\nUPDATE t SET a = 2 WHERE id = 1",
            "postgres",
        );
        assert!(rewrite.is_none());
    }
}
