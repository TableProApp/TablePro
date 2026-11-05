use crate::column::{ColumnInfo, ColumnKind, ColumnOrigin, ColumnType, ResultColumn};
use crate::meta::TableRef;
use crate::sql_syntax::{
    SourceItem, SourceRefusal, SourceTable, SqlGrammar, same_name, source_columns_for_result, source_table,
};
use crate::value::Value;

use super::parse_literal_text;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ResultLock {
    NotOneSelect,
    MoreThanOneTable,
    Collapsed,
    // No origin, or one that is not the table the statement names: a view, a temporary table, an engine that reports none.
    Untraced,
    NoPrimaryKey,
    KeyNotShown,
    ColumnsChanged,
}

impl From<SourceRefusal> for ResultLock {
    fn from(refusal: SourceRefusal) -> Self {
        match refusal {
            SourceRefusal::NotOneSelect => Self::NotOneSelect,
            SourceRefusal::MoreThanOneTable => Self::MoreThanOneTable,
            SourceRefusal::Collapsed => Self::Collapsed,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResultSource {
    pub table: TableRef,
    statement: SourceTable,
    grammar: SqlGrammar,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResultTarget {
    pub table: TableRef,
    // For each result column, the catalog column it writes; `None` locks the cell.
    pub positions: Vec<Option<usize>>,
}

// The statement decides whether its rows are one table's; the driver's origins prove which table.
pub fn result_source(sql: &str, grammar: SqlGrammar, columns: &[ResultColumn]) -> Result<ResultSource, ResultLock> {
    let statement = source_table(sql, grammar)?;
    let mut origins = columns.iter().filter_map(|column| column.origin.as_ref());
    let table = origins.next().map(|origin| &origin.table).ok_or(ResultLock::Untraced)?;
    if origins.any(|origin| origin.table != *table) || !names_table(&statement.table, table, grammar) {
        return Err(ResultLock::Untraced);
    }
    Ok(ResultSource {
        table: table.clone(),
        statement,
        grammar,
    })
}

pub fn result_target(
    source: &ResultSource,
    result: &[ResultColumn],
    catalog: &[ColumnInfo],
) -> Result<ResultTarget, ResultLock> {
    let names: Vec<String> = result.iter().map(|column| column.name.clone()).collect();
    let parsed = source_columns_for_result(&source.statement, catalog, &names).ok_or(ResultLock::ColumnsChanged)?;
    let mut positions = Vec::with_capacity(result.len());
    for (column, parsed) in result.iter().zip(parsed) {
        let traced = match (parsed, &column.origin) {
            (Some(position), Some(origin)) => {
                let named = catalog
                    .get(position)
                    .is_some_and(|info| same_name(&info.name, &origin.column, source.grammar));
                if !named {
                    return Err(ResultLock::Untraced);
                }
                Some(position)
            }
            _ => None,
        };
        // The second copy of a column would write over the first one's edit in the same statement.
        let first = traced.filter(|position| !positions.contains(&Some(*position)));
        positions.push(first);
    }
    let mut keys = catalog
        .iter()
        .enumerate()
        .filter(|(_, info)| info.primary_key)
        .peekable();
    if keys.peek().is_none() {
        return Err(ResultLock::NoPrimaryKey);
    }
    if keys.any(|(index, _)| !positions.contains(&Some(index))) {
        return Err(ResultLock::KeyNotShown);
    }
    Ok(ResultTarget {
        table: source.table.clone(),
        positions,
    })
}

// For an engine that reports no origins: once the driver resolved the statement's table on its own connection, the statement says which columns are that table's.
pub fn parsed_origins(statement: &SourceTable, table: &TableRef, names: &[String]) -> Vec<Option<ColumnOrigin>> {
    let wildcards = statement
        .items
        .iter()
        .filter(|item| matches!(item, SourceItem::Wildcard))
        .count();
    let others = statement.items.len() - wildcards;
    let spread = match names.len().checked_sub(others) {
        Some(spread) if wildcards == 0 && spread == 0 => 0,
        Some(spread) if wildcards > 0 && spread % wildcards == 0 => spread / wildcards,
        _ => return vec![None; names.len()],
    };
    let mut origins = Vec::with_capacity(names.len());
    for item in &statement.items {
        match item {
            SourceItem::Column(name) => origins.push(Some(ColumnOrigin::new(table.clone(), name.name.clone()))),
            SourceItem::Expression => origins.push(None),
            SourceItem::Wildcard => {
                let start = origins.len();
                origins.extend(
                    names[start..start + spread]
                        .iter()
                        .map(|name| Some(ColumnOrigin::new(table.clone(), name.clone()))),
                );
            }
        }
    }
    origins
}

// PostgreSQL's editor reads every value as text; a key or a copied value has to bind as the column's own type.
pub fn value_for_column(value: &Value, column: &ColumnType) -> Option<Value> {
    let Value::Text(text) = value else {
        return Some(value.clone());
    };
    match &column.kind {
        ColumnKind::Text { .. } => Some(value.clone()),
        ColumnKind::Bytes { .. } => postgres_bytea(text).map(Value::Bytes),
        _ => parse_literal_text(text, column).ok(),
    }
}

fn postgres_bytea(text: &str) -> Option<Vec<u8>> {
    let hex = text.strip_prefix("\\x")?;
    if hex.len() % 2 != 0 {
        return None;
    }
    hex.as_bytes()
        .chunks_exact(2)
        .map(|pair| {
            let digit = |byte: u8| char::from(byte).to_digit(16);
            Some(u8::try_from(digit(pair[0])? * 16 + digit(pair[1])?).ok()?)
        })
        .collect()
}

fn names_table(statement: &TableRef, origin: &TableRef, grammar: SqlGrammar) -> bool {
    if !same_name(&statement.name, &origin.name, grammar) {
        return false;
    }
    match (&statement.schema, &origin.schema) {
        (None, _) => true,
        (Some(written), Some(resolved)) => same_name(written, resolved, grammar),
        (Some(written), None) => {
            matches!(grammar, SqlGrammar::Sqlite | SqlGrammar::DuckDb) && written.eq_ignore_ascii_case("main")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::column::{ColumnDefault, IntegerKind, IntegerWidth, ReadForm, TextLength};

    fn typed(name: &str, kind: ColumnKind) -> ColumnType {
        ColumnType {
            name: name.to_owned(),
            kind,
            catalog: None,
            dynamic_storage: false,
            read_form: ReadForm::Native,
        }
    }

    fn int() -> ColumnType {
        typed(
            "integer",
            ColumnKind::Integer(IntegerKind {
                width: IntegerWidth::W32,
                signed: true,
            }),
        )
    }

    fn text() -> ColumnType {
        typed(
            "text",
            ColumnKind::Text {
                length: TextLength::Unbounded,
            },
        )
    }

    fn table() -> TableRef {
        TableRef::new(Some("public".to_owned()), "t")
    }

    fn traced(name: &str, column: &str) -> ResultColumn {
        ResultColumn::new(name, text()).with_origin(Some(ColumnOrigin::new(table(), column)))
    }

    fn untraced(name: &str) -> ResultColumn {
        ResultColumn::new(name, text())
    }

    fn info(name: &str, primary_key: bool) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: text(),
            nullable: !primary_key,
            primary_key,
            is_auto_increment: false,
            is_generated: false,
            partition_scoped: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn catalog() -> Vec<ColumnInfo> {
        vec![info("id", true), info("a", false), info("b", false)]
    }

    fn target(sql: &str, result: &[ResultColumn]) -> Result<ResultTarget, ResultLock> {
        let source = result_source(sql, SqlGrammar::PostgreSql, result)?;
        result_target(&source, result, &catalog())
    }

    #[test]
    fn a_whole_table_maps_every_column() {
        let result = [traced("id", "id"), traced("a", "a"), traced("b", "b")];

        let found = target("SELECT * FROM t", &result).expect("editable");

        assert_eq!(found.table, table());
        assert_eq!(found.positions, vec![Some(0), Some(1), Some(2)]);
    }

    #[test]
    fn a_renamed_column_writes_its_own_column_and_an_expression_locks() {
        let result = [traced("x", "a"), traced("id", "id"), untraced("?column?")];

        let found = target("SELECT a AS x, id, b + 1 FROM t", &result).expect("editable");

        assert_eq!(found.positions, vec![Some(1), Some(0), None]);
    }

    #[test]
    fn a_column_shown_twice_is_written_once() {
        let result = [traced("id", "id"), traced("a", "a"), traced("a", "a")];

        let found = target("SELECT id, a, a FROM t", &result).expect("editable");

        assert_eq!(found.positions, vec![Some(0), Some(1), None]);
    }

    #[test]
    fn rows_without_their_whole_key_are_locked() {
        let result = [traced("a", "a")];

        assert_eq!(target("SELECT a FROM t", &result), Err(ResultLock::KeyNotShown));
        let keyless = vec![info("a", false)];
        let source = result_source("SELECT a FROM t", SqlGrammar::PostgreSql, &result).expect("traced");
        assert_eq!(result_target(&source, &result, &keyless), Err(ResultLock::NoPrimaryKey));
    }

    #[test]
    fn a_result_without_origins_is_untraced() {
        let result = [untraced("id"), untraced("a")];

        assert_eq!(
            result_source("SELECT id, a FROM t", SqlGrammar::PostgreSql, &result),
            Err(ResultLock::Untraced)
        );
    }

    #[test]
    fn origins_that_name_another_table_than_the_statement_are_untraced() {
        let through_view = [traced("id", "id"), traced("a", "a")];
        assert_eq!(
            result_source("SELECT * FROM v", SqlGrammar::Sqlite, &through_view),
            Err(ResultLock::Untraced)
        );
        let mixed = [
            traced("id", "id"),
            ResultColumn::new("c", text()).with_origin(Some(ColumnOrigin::new(TableRef::unqualified("u"), "c"))),
        ];
        assert_eq!(
            result_source("SELECT * FROM t", SqlGrammar::PostgreSql, &mixed),
            Err(ResultLock::Untraced)
        );
        assert_eq!(
            result_source("SELECT * FROM other.t", SqlGrammar::PostgreSql, &through_view),
            Err(ResultLock::Untraced)
        );
    }

    #[test]
    fn the_statement_refuses_before_the_origins_are_read() {
        let result = [traced("id", "id")];

        for (sql, lock) in [
            ("SELECT t.id FROM t JOIN u ON u.id = t.id", ResultLock::MoreThanOneTable),
            ("SELECT DISTINCT id FROM t", ResultLock::Collapsed),
            ("SELECT id FROM t; SELECT 1", ResultLock::NotOneSelect),
        ] {
            assert_eq!(result_source(sql, SqlGrammar::PostgreSql, &result), Err(lock), "{sql}");
        }
    }

    #[test]
    fn a_schema_the_statement_leaves_out_is_the_one_the_server_resolved() {
        let result = [traced("id", "id")];

        assert!(result_source("SELECT id FROM public.t", SqlGrammar::PostgreSql, &result).is_ok());
        assert!(result_source("SELECT id FROM t", SqlGrammar::PostgreSql, &result).is_ok());
        let main =
            [ResultColumn::new("id", text()).with_origin(Some(ColumnOrigin::new(TableRef::unqualified("t"), "id")))];
        assert!(result_source("SELECT id FROM main.t", SqlGrammar::Sqlite, &main).is_ok());
        assert!(result_source("SELECT id FROM other.t", SqlGrammar::Sqlite, &main).is_err());
    }

    #[test]
    fn a_table_changed_since_the_run_is_noticed() {
        let result = [traced("id", "id"), traced("a", "a"), traced("b", "b")];
        let source = result_source("SELECT * FROM t", SqlGrammar::PostgreSql, &result).expect("traced");

        let reordered = vec![info("a", false), info("id", true), info("b", false)];

        assert_eq!(
            result_target(&source, &result, &reordered),
            Err(ResultLock::ColumnsChanged)
        );
    }

    #[test]
    fn an_origin_that_disagrees_with_the_statement_is_untraced() {
        let result = [traced("id", "a"), traced("a", "id")];

        assert_eq!(target("SELECT id, a FROM t", &result), Err(ResultLock::Untraced));
        let swapped = [traced("a", "id"), traced("id", "a")];
        assert_eq!(
            target("SELECT id AS a, a AS id FROM t", &swapped).map(|found| found.positions),
            Ok(vec![Some(0), Some(1)])
        );
    }

    #[test]
    fn parsed_origins_spread_a_wildcard_over_the_columns_it_read() {
        let statement = source_table("SELECT a AS x, *, b + 1 FROM t", SqlGrammar::DuckDb).expect("one table");
        let names = ["x", "id", "a", "b", "next"].map(str::to_owned);

        let origins = parsed_origins(&statement, &table(), &names);

        let columns: Vec<Option<&str>> = origins
            .iter()
            .map(|origin| origin.as_ref().map(|origin| origin.column.as_str()))
            .collect();
        assert_eq!(columns, vec![Some("a"), Some("id"), Some("a"), Some("b"), None]);
        let unsplit = source_table("SELECT *, * FROM t", SqlGrammar::DuckDb).expect("one table");
        assert_eq!(parsed_origins(&unsplit, &table(), &names), vec![None; 5]);
    }

    #[test]
    fn server_text_becomes_the_columns_type() {
        assert_eq!(
            value_for_column(&Value::Text("42".to_owned()), &int()),
            Some(Value::Int(42))
        );
        assert_eq!(
            value_for_column(&Value::Text("x".to_owned()), &text()),
            Some(Value::Text("x".to_owned()))
        );
        assert_eq!(value_for_column(&Value::Text("forty".to_owned()), &int()), None);
        let bytes = typed(
            "bytea",
            ColumnKind::Bytes {
                length: TextLength::Unbounded,
            },
        );
        assert_eq!(
            value_for_column(&Value::Text("\\x01ff".to_owned()), &bytes),
            Some(Value::Bytes(vec![1, 255]))
        );
        assert_eq!(value_for_column(&Value::Int(7), &int()), Some(Value::Int(7)));
    }
}
