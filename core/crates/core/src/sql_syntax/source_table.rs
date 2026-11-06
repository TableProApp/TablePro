use sqlparser::ast::{
    Expr, GroupByExpr, Ident, ObjectName, ObjectNamePart, OrderByKind, Query, Select, SelectFlavor, SelectItem,
    SelectItemQualifiedWildcardKind, SetExpr, Statement, TableFactor, WildcardAdditionalOptions,
};
use sqlparser::parser::Parser;

use super::SqlGrammar;
use super::parse_type::RECURSION_LIMIT;
use super::script::{LexicalSettings, ScriptPlan, ScriptTokenKind};
use crate::column::ColumnInfo;
use crate::meta::TableRef;

// Editing needs a table read row for row; shapes whose identity cannot be proved are refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SourceTable {
    pub table: TableRef,
    pub items: Vec<SourceItem>,
    grammar: SqlGrammar,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SourceItem {
    Column(SourceName),
    Wildcard,
    Expression,
}

// Unquoted names are resolved using the grammar before matching catalog columns.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SourceName {
    pub name: String,
    pub quoted: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SourceRefusal {
    NotOneSelect,
    MoreThanOneTable,
    Collapsed,
}

pub fn source_table(sql: &str, grammar: SqlGrammar) -> Result<SourceTable, SourceRefusal> {
    let query = parse_query(sql, grammar)?;
    single_table_query(&query, grammar)
}

fn parse_query(sql: &str, grammar: SqlGrammar) -> Result<Box<Query>, SourceRefusal> {
    let dialect = grammar.parser_dialect().ok_or(SourceRefusal::NotOneSelect)?;
    let plan = ScriptPlan::build(sql, grammar, LexicalSettings::default_for(grammar));
    if !plan.diagnostics().is_empty()
        || plan.tokens(0..sql.len()).any(|token| {
            matches!(
                token.kind,
                ScriptTokenKind::ExecutableMarker | ScriptTokenKind::Directive | ScriptTokenKind::Unterminated
            )
        })
    {
        return Err(SourceRefusal::NotOneSelect);
    }
    let mut statements = Parser::new(dialect)
        .with_recursion_limit(RECURSION_LIMIT)
        .try_with_sql(sql)
        .and_then(|mut parser| parser.parse_statements())
        .map_err(|_| SourceRefusal::NotOneSelect)?
        .into_iter();
    let Some(Statement::Query(query)) = statements.next() else {
        return Err(SourceRefusal::NotOneSelect);
    };
    match statements.next() {
        None => Ok(query),
        Some(_) => Err(SourceRefusal::NotOneSelect),
    }
}

fn plain_select(query: &Query) -> Result<&Select, SourceRefusal> {
    if query.with.is_some() {
        return Err(SourceRefusal::MoreThanOneTable);
    }
    if query.for_clause.is_some() || query.format_clause.is_some() || !query.pipe_operators.is_empty() {
        return Err(SourceRefusal::NotOneSelect);
    }
    if let Some(order) = &query.order_by {
        let OrderByKind::Expressions(expressions) = &order.kind else {
            return Err(SourceRefusal::Collapsed);
        };
        if order.interpolate.is_some()
            || expressions
                .iter()
                .any(|item| item.with_fill.is_some() || !row_expression(&item.expr))
        {
            return Err(SourceRefusal::Collapsed);
        }
    }
    let select = match query.body.as_ref() {
        SetExpr::Select(select) => select,
        SetExpr::SetOperation { .. } | SetExpr::Query(_) => return Err(SourceRefusal::MoreThanOneTable),
        _ => return Err(SourceRefusal::NotOneSelect),
    };
    let plain_grouping = matches!(&select.group_by, GroupByExpr::Expressions(expressions, modifiers)
        if expressions.is_empty() && modifiers.is_empty());
    if select.distinct.is_some() || !plain_grouping || select.having.is_some() || select.qualify.is_some() {
        return Err(SourceRefusal::Collapsed);
    }
    if select.into.is_some()
        || select.exclude.is_some()
        || !select.lateral_views.is_empty()
        || !select.connect_by.is_empty()
        || select.value_table_mode.is_some()
        || select.flavor != SelectFlavor::Standard
    {
        return Err(SourceRefusal::NotOneSelect);
    }
    Ok(select)
}

fn single_table_query(query: &Query, grammar: SqlGrammar) -> Result<SourceTable, SourceRefusal> {
    let select = plain_select(query)?;
    let [from] = select.from.as_slice() else {
        return Err(match select.from.is_empty() {
            true => SourceRefusal::NotOneSelect,
            false => SourceRefusal::MoreThanOneTable,
        });
    };
    if !from.joins.is_empty() {
        return Err(SourceRefusal::MoreThanOneTable);
    }
    let TableFactor::Table {
        name,
        alias,
        args: None,
        version: None,
        with_ordinality: false,
        partitions,
        json_path: None,
        sample: None,
        ..
    } = &from.relation
    else {
        return Err(SourceRefusal::MoreThanOneTable);
    };
    if !partitions.is_empty() || alias.as_ref().is_some_and(|alias| !alias.columns.is_empty()) {
        return Err(SourceRefusal::MoreThanOneTable);
    }
    let parts = identifiers(name).ok_or(SourceRefusal::MoreThanOneTable)?;
    let (schema, table) = match parts.as_slice() {
        [table] => (None, (*table).clone()),
        [schema, table] => (Some((*schema).clone()), (*table).clone()),
        _ => return Err(SourceRefusal::MoreThanOneTable),
    };
    let qualifiers: Vec<&Ident> = alias.as_ref().map_or_else(|| vec![&table], |alias| vec![&alias.name]);
    let items = select
        .projection
        .iter()
        .map(|item| source_item(item, &qualifiers, schema.as_ref(), grammar))
        .collect::<Result<Vec<_>, _>>()?;
    if grammar == SqlGrammar::ClickHouse && alias_shadows_a_column(&select.projection, &items, grammar) {
        return Err(SourceRefusal::Collapsed);
    }
    Ok(SourceTable {
        table: TableRef::new(
            schema.map(|ident| resolved_name(&ident, grammar)),
            resolved_name(&table, grammar),
        ),
        items,
        grammar,
    })
}

fn identifiers(name: &ObjectName) -> Option<Vec<&Ident>> {
    name.0
        .iter()
        .map(|part| match part {
            ObjectNamePart::Identifier(ident) => Some(ident),
            ObjectNamePart::Function(_) => None,
        })
        .collect()
}

// A `*` of another relation would put columns the table does not have in the grid, so it refuses the statement.
fn source_item(
    item: &SelectItem,
    qualifiers: &[&Ident],
    schema: Option<&Ident>,
    grammar: SqlGrammar,
) -> Result<SourceItem, SourceRefusal> {
    match item {
        SelectItem::UnnamedExpr(expr) | SelectItem::ExprWithAlias { expr, .. } => match row_expression(expr) {
            true => Ok(column(expr, qualifiers, schema, grammar)),
            false => Err(SourceRefusal::Collapsed),
        },
        SelectItem::ExprWithAliases { .. } => Err(SourceRefusal::Collapsed),
        SelectItem::Wildcard(options) => match plain_wildcard(options) {
            true => Ok(SourceItem::Wildcard),
            false => Err(SourceRefusal::NotOneSelect),
        },
        SelectItem::QualifiedWildcard(SelectItemQualifiedWildcardKind::ObjectName(name), options) => {
            let parts = identifiers(name).ok_or(SourceRefusal::MoreThanOneTable)?;
            match (
                plain_wildcard(options),
                names_the_table(&parts, qualifiers, schema, grammar),
            ) {
                (true, true) => Ok(SourceItem::Wildcard),
                (false, _) => Err(SourceRefusal::NotOneSelect),
                (true, false) => Err(SourceRefusal::MoreThanOneTable),
            }
        }
        SelectItem::QualifiedWildcard(SelectItemQualifiedWildcardKind::Expr(_), _) => {
            Err(SourceRefusal::MoreThanOneTable)
        }
    }
}

fn column(expr: &Expr, qualifiers: &[&Ident], schema: Option<&Ident>, grammar: SqlGrammar) -> SourceItem {
    let (qualifier, name): (&[Ident], &Ident) = match expr {
        Expr::Identifier(ident) => (&[], ident),
        Expr::CompoundIdentifier(parts) => match parts.split_last() {
            Some((name, qualifier)) => (qualifier, name),
            None => return SourceItem::Expression,
        },
        Expr::Nested(inner) => return column(inner, qualifiers, schema, grammar),
        _ => return SourceItem::Expression,
    };
    let qualifier: Vec<&Ident> = qualifier.iter().collect();
    if !qualifier.is_empty() && !names_the_table(&qualifier, qualifiers, schema, grammar) {
        return SourceItem::Expression;
    }
    if qualifier.is_empty() && name.quote_style.is_none() && value_keyword(&name.value, grammar) {
        return SourceItem::Expression;
    }
    SourceItem::Column(SourceName {
        name: resolved_name(name, grammar),
        quoted: name.quote_style.is_some(),
    })
}

// ClickHouse substitutes a select-list alias for a column of the same name anywhere in the query, so `2 AS id, id AS k`
// reads 2 into k.
fn alias_shadows_a_column(projection: &[SelectItem], items: &[SourceItem], grammar: SqlGrammar) -> bool {
    projection.iter().enumerate().any(|(index, item)| {
        let SelectItem::ExprWithAlias { alias, .. } = item else {
            return false;
        };
        let alias = resolved_name(alias, grammar);
        items
            .iter()
            .enumerate()
            .any(|(other, item)| other != index && matches!(item, SourceItem::Column(column) if column.name == alias))
    })
}

// PostgreSQL reads these bare words as functions even where the table has a column of that name.
fn value_keyword(name: &str, grammar: SqlGrammar) -> bool {
    const POSTGRES: [&str; 12] = [
        "current_catalog",
        "current_date",
        "current_role",
        "current_schema",
        "current_time",
        "current_timestamp",
        "current_user",
        "localtime",
        "localtimestamp",
        "session_user",
        "system_user",
        "user",
    ];
    grammar == SqlGrammar::PostgreSql && POSTGRES.iter().any(|keyword| keyword.eq_ignore_ascii_case(name))
}

fn names_the_table(parts: &[&Ident], qualifiers: &[&Ident], schema: Option<&Ident>, grammar: SqlGrammar) -> bool {
    match parts {
        [name] => qualifiers.iter().any(|qualifier| same_ident(qualifier, name, grammar)),
        [part_schema, name] => {
            schema.is_some_and(|schema| same_ident(schema, part_schema, grammar))
                && qualifiers.iter().any(|qualifier| same_ident(qualifier, name, grammar))
        }
        _ => false,
    }
}

fn resolved_name(ident: &Ident, grammar: SqlGrammar) -> String {
    if ident.quote_style.is_none() && matches!(grammar, SqlGrammar::PostgreSql | SqlGrammar::Cql) {
        ident.value.to_ascii_lowercase()
    } else {
        ident.value.clone()
    }
}

// Names the server already resolved: an engine that folds case or compares by collation finds either spelling.
pub fn same_name(left: &str, right: &str, grammar: SqlGrammar) -> bool {
    match grammar {
        SqlGrammar::MySql | SqlGrammar::Sqlite | SqlGrammar::DuckDb | SqlGrammar::MsSql => {
            left.eq_ignore_ascii_case(right)
        }
        SqlGrammar::PostgreSql | SqlGrammar::ClickHouse | SqlGrammar::Cql | SqlGrammar::Redis | SqlGrammar::Mongo => {
            left == right
        }
    }
}

fn same_ident(left: &Ident, right: &Ident, grammar: SqlGrammar) -> bool {
    let (left, right) = (resolved_name(left, grammar), resolved_name(right, grammar));
    match grammar {
        SqlGrammar::Sqlite | SqlGrammar::DuckDb => left.eq_ignore_ascii_case(&right),
        _ => left == right,
    }
}

// A function may aggregate or return several rows, including one whose name looks scalar.
fn row_expression(expr: &Expr) -> bool {
    match expr {
        Expr::Identifier(_) | Expr::CompoundIdentifier(_) | Expr::Value(_) | Expr::TypedString(_) => true,
        Expr::Nested(expr)
        | Expr::UnaryOp { expr, .. }
        | Expr::IsFalse(expr)
        | Expr::IsNotFalse(expr)
        | Expr::IsTrue(expr)
        | Expr::IsNotTrue(expr)
        | Expr::IsNull(expr)
        | Expr::IsNotNull(expr)
        | Expr::IsUnknown(expr)
        | Expr::IsNotUnknown(expr) => row_expression(expr),
        Expr::BinaryOp { left, right, .. }
        | Expr::IsDistinctFrom(left, right)
        | Expr::IsNotDistinctFrom(left, right) => row_expression(left) && row_expression(right),
        Expr::Between { expr, low, high, .. } => row_expression(expr) && row_expression(low) && row_expression(high),
        Expr::InList { expr, list, .. } => row_expression(expr) && list.iter().all(row_expression),
        Expr::Case {
            operand,
            conditions,
            else_result,
            ..
        } => {
            operand.as_deref().is_none_or(row_expression)
                && conditions
                    .iter()
                    .all(|branch| row_expression(&branch.condition) && row_expression(&branch.result))
                && else_result.as_deref().is_none_or(row_expression)
        }
        _ => false,
    }
}

// REPLACE, RENAME, EXCLUDE and the like change which columns a `*` stands for.
fn plain_wildcard(options: &WildcardAdditionalOptions) -> bool {
    options.opt_ilike.is_none()
        && options.opt_exclude.is_none()
        && options.opt_except.is_none()
        && options.opt_replace.is_none()
        && options.opt_rename.is_none()
        && options.opt_alias.is_none()
}

// A wildcard reads the columns a `*` shows, which leaves out MySQL's INVISIBLE and ClickHouse's MATERIALIZED and ALIAS
// ones, so it maps by the exact names it read; a name the catalog no longer has means the table changed since.
pub fn source_columns_for_result(
    source: &SourceTable,
    columns: &[ColumnInfo],
    result_names: &[String],
) -> Option<Vec<Option<usize>>> {
    let wildcards = source
        .items
        .iter()
        .filter(|item| matches!(item, SourceItem::Wildcard))
        .count();
    let spread = result_names.len().checked_sub(source.items.len() - wildcards)?;
    let per_wildcard = match wildcards {
        0 if spread == 0 => 0,
        0 => return None,
        _ if spread % wildcards == 0 => spread / wildcards,
        _ => return None,
    };
    let mut mapped = Vec::with_capacity(result_names.len());
    for item in &source.items {
        match item {
            SourceItem::Wildcard => {
                let names = result_names.get(mapped.len()..mapped.len() + per_wildcard)?;
                for name in names {
                    let mut named = columns.iter().enumerate().filter(|(_, column)| column.name == *name);
                    match (named.next(), named.next()) {
                        (Some((position, _)), None) => mapped.push(Some(position)),
                        _ => return None,
                    }
                }
            }
            SourceItem::Expression => mapped.push(None),
            // A name the table lacks may be a word the engine reads as a function; the driver's origin says which.
            SourceItem::Column(name) => mapped.push(column_position(columns, name, source.grammar)),
        }
    }
    Some(mapped)
}

// SQL Server's catalog collation is not available here, so only exact names can be proved.
fn column_position(columns: &[ColumnInfo], name: &SourceName, grammar: SqlGrammar) -> Option<usize> {
    let insensitive = matches!(grammar, SqlGrammar::MySql | SqlGrammar::Sqlite | SqlGrammar::DuckDb);
    let mut matches = columns.iter().enumerate().filter(|(_, column)| {
        if insensitive {
            column.name.eq_ignore_ascii_case(&name.name)
        } else {
            column.name == name.name
        }
    });
    match (matches.next(), matches.next()) {
        (Some((position, _)), None) => Some(position),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use crate::column::{ColumnDefault, ColumnType};

    use super::*;

    fn source(sql: &str) -> Option<SourceTable> {
        source_table(sql, SqlGrammar::PostgreSql).ok()
    }

    fn named(name: &str) -> SourceItem {
        SourceItem::Column(SourceName {
            name: name.to_owned(),
            quoted: false,
        })
    }

    fn source_columns(source: &SourceTable, columns: &[ColumnInfo], width: usize) -> Option<Vec<Option<usize>>> {
        let names: Vec<String> = (0..width).map(|index| format!("column {index}")).collect();
        source_columns_for_result(source, columns, &names)
    }

    fn info(name: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: ColumnType::untyped_text("text"),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            partition_scoped: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    #[test]
    fn a_select_from_one_table_names_it_and_its_columns() {
        let found = source("SELECT id, name AS who, 1 + 1 FROM people WHERE id > 1 ORDER BY name LIMIT 10");

        assert_eq!(
            found,
            Some(SourceTable {
                table: TableRef::unqualified("people"),
                items: vec![named("id"), named("name"), SourceItem::Expression],
                grammar: SqlGrammar::PostgreSql,
            })
        );
    }

    #[test]
    fn a_schema_and_an_alias_qualify_the_same_table() {
        let found = source("SELECT p.id, app.people.note, p.* FROM app.people AS p").expect("one table");

        assert_eq!(found.table, TableRef::new(Some("app".to_owned()), "people"));
        assert_eq!(
            found.items,
            vec![named("id"), SourceItem::Expression, SourceItem::Wildcard]
        );
        assert_eq!(
            source("SELECT people.id FROM app.people").map(|found| found.items),
            Some(vec![named("id")])
        );
        assert_eq!(
            source("SELECT other.id FROM people").map(|found| found.items),
            Some(vec![SourceItem::Expression]),
            "a column of another relation"
        );
    }

    #[test]
    fn every_shape_that_reads_more_than_one_table_row_for_row_has_none() {
        for sql in [
            "SELECT * FROM a JOIN b ON a.id = b.id",
            "SELECT * FROM a, b",
            "SELECT * FROM (SELECT * FROM a) AS s",
            "WITH s AS (SELECT * FROM a) SELECT * FROM s",
            "SELECT * FROM a UNION SELECT * FROM b",
            "SELECT DISTINCT name FROM a",
            "SELECT name, count(*) FROM a GROUP BY name",
            "SELECT id FROM a HAVING id > 1",
            "SELECT 1",
            "SELECT * FROM generate_series(1, 3)",
            "SELECT * FROM a AS t(x, y)",
            "SELECT * FROM a; SELECT * FROM b",
            "UPDATE a SET id = 1",
            "SELECT b.* FROM a",
            "SELECT * FROM cat.app.people",
            "SELEC * FROM a",
        ] {
            assert_eq!(source(sql), None, "{sql}");
        }
    }

    #[test]
    fn each_refusal_names_why_the_rows_are_not_one_tables() {
        let refusal = |sql| source_table(sql, SqlGrammar::PostgreSql).err();
        for sql in [
            "SELECT * FROM a JOIN b ON a.id = b.id",
            "SELECT * FROM a, b",
            "SELECT * FROM (SELECT * FROM a) AS s",
            "WITH s AS (SELECT * FROM a) SELECT * FROM s",
            "SELECT * FROM a UNION SELECT * FROM b",
            "SELECT * FROM generate_series(1, 3)",
            "SELECT b.* FROM a",
        ] {
            assert_eq!(refusal(sql), Some(SourceRefusal::MoreThanOneTable), "{sql}");
        }
        for sql in [
            "SELECT DISTINCT name FROM a",
            "SELECT name, count(*) FROM a GROUP BY name",
            "SELECT id, upper(name) FROM a",
        ] {
            assert_eq!(refusal(sql), Some(SourceRefusal::Collapsed), "{sql}");
        }
        for sql in [
            "SELECT 1",
            "UPDATE a SET id = 1",
            "SELECT * FROM a; SELECT * FROM b",
            "SELEC * FROM a",
        ] {
            assert_eq!(refusal(sql), Some(SourceRefusal::NotOneSelect), "{sql}");
        }
    }

    #[test]
    fn words_postgresql_reads_as_functions_are_expressions() {
        let found = source("SELECT id, current_role, \"user\", CURRENT_SCHEMA FROM people").expect("one table");

        assert_eq!(
            found.items,
            vec![
                named("id"),
                SourceItem::Expression,
                SourceItem::Column(SourceName {
                    name: "user".to_owned(),
                    quoted: true,
                }),
                SourceItem::Expression,
            ]
        );
    }

    #[test]
    fn a_clickhouse_alias_that_names_another_items_column_refuses_the_read() {
        let clickhouse = |sql| source_table(sql, SqlGrammar::ClickHouse);

        assert_eq!(
            clickhouse("SELECT 2 AS id, id AS k, a FROM t"),
            Err(SourceRefusal::Collapsed)
        );
        assert!(clickhouse("SELECT id AS id, a AS x FROM t").is_ok());
        assert!(source_table("SELECT 2 AS id, id AS k FROM t", SqlGrammar::PostgreSql).is_ok());
    }

    #[test]
    fn a_locking_read_still_reads_one_table() {
        assert!(source("SELECT * FROM a WHERE id = 1 FOR UPDATE").is_some());
        assert!(source_table("SELECT TOP 5 * FROM a", SqlGrammar::MsSql).is_ok());
        assert_eq!(
            source_table("SELECT * FROM a FOR JSON AUTO", SqlGrammar::MsSql),
            Err(SourceRefusal::NotOneSelect)
        );
    }

    #[test]
    fn engines_without_sql_have_no_source() {
        assert_eq!(
            source_table("SELECT * FROM a", SqlGrammar::Redis),
            Err(SourceRefusal::NotOneSelect)
        );
        assert_eq!(
            source_table("db.a.find()", SqlGrammar::Mongo),
            Err(SourceRefusal::NotOneSelect)
        );
    }

    #[test]
    fn a_wildcard_maps_the_columns_it_read_by_name() {
        let columns = [info("id"), info("name"), info("hidden"), info("note")];
        let star = source("SELECT *, 1 + 1 FROM people").expect("one table");
        let picked = source("SELECT NAME, \"id\" FROM people").expect("one table");
        let read = ["id", "name", "note", "?column?"].map(str::to_owned);

        assert_eq!(
            source_columns_for_result(&star, &columns, &read),
            Some(vec![Some(0), Some(1), Some(3), None]),
            "a column a star leaves out is skipped"
        );
        let renamed = ["id", "label", "note", "?column?"].map(str::to_owned);
        assert_eq!(
            source_columns_for_result(&star, &columns, &renamed),
            None,
            "the table changed since"
        );
        assert_eq!(source_columns(&picked, &columns, 2), Some(vec![Some(1), Some(0)]));
    }

    #[test]
    fn a_quoted_name_matches_only_as_spelled() {
        let columns = [info("Name"), info("name")];
        let quoted = source("SELECT \"Name\" FROM people").expect("one table");
        let folded = source("SELECT NAME FROM people").expect("one table");
        let missing = source("SELECT \"NAME\" FROM people").expect("one table");

        assert_eq!(source_columns(&quoted, &columns, 1), Some(vec![Some(0)]));
        assert_eq!(
            source_columns(&folded, &columns, 1),
            Some(vec![Some(1)]),
            "unquoted names fold before lookup"
        );
        assert_eq!(source_columns(&missing, &columns, 1), Some(vec![None]));
    }

    #[test]
    fn unquoted_identifiers_fold_before_catalog_lookup() {
        for grammar in [SqlGrammar::PostgreSql, SqlGrammar::Cql] {
            let found = source_table("SELECT Name FROM App.People", grammar).expect("one table");
            assert_eq!(found.table, TableRef::new(Some("app".to_owned()), "people"));
            assert_eq!(
                source_columns(&found, &[info("Name"), info("name")], 1),
                Some(vec![Some(1)])
            );
            assert_eq!(source_columns(&found, &[info("Name")], 1), Some(vec![None]));

            let quoted = source_table("SELECT \"Name\" FROM \"App\".\"People\"", grammar).expect("one table");
            assert_eq!(quoted.table, TableRef::new(Some("App".to_owned()), "People"));
            assert_eq!(
                source_columns(&quoted, &[info("Name"), info("name")], 1),
                Some(vec![Some(0)])
            );
        }
    }

    #[test]
    fn qualifiers_follow_the_same_folding_as_their_declarations() {
        let found = source("SELECT \"p\".Name FROM People AS P").expect("one table");
        assert_eq!(found.items, vec![named("name")]);
        let found = source("SELECT P.Name FROM People AS \"P\"").expect("one table");
        assert_eq!(found.items, vec![SourceItem::Expression]);
    }

    #[test]
    fn case_insensitive_columns_match_even_when_quoted() {
        for grammar in [SqlGrammar::Sqlite, SqlGrammar::DuckDb] {
            let found = source_table("SELECT \"NAME\" FROM people", grammar).expect("one table");
            assert_eq!(source_columns(&found, &[info("name")], 1), Some(vec![Some(0)]));
            assert_eq!(
                source_columns(&found, &[info("name"), info("Name")], 1),
                Some(vec![None])
            );
        }
        let found = source_table("SELECT `NAME` FROM people", SqlGrammar::MySql).expect("one table");
        assert_eq!(source_columns(&found, &[info("name")], 1), Some(vec![Some(0)]));
    }

    #[test]
    fn case_sensitive_and_unknown_collations_never_guess() {
        for grammar in [SqlGrammar::ClickHouse, SqlGrammar::MsSql] {
            let found = source_table("SELECT Name FROM people", grammar).expect("one table");
            assert_eq!(source_columns(&found, &[info("name")], 1), Some(vec![None]));
            assert_eq!(
                source_columns(&found, &[info("Name"), info("name")], 1),
                Some(vec![Some(0)])
            );
        }
    }

    #[test]
    fn expressions_that_may_collapse_or_expand_rows_are_refused() {
        for grammar in [SqlGrammar::Sqlite, SqlGrammar::PostgreSql, SqlGrammar::MySql] {
            for sql in [
                "SELECT id, count(*) FROM people",
                "SELECT id, 1 + count(*) FROM people",
                "SELECT id, CASE WHEN id = 1 THEN count(*) ELSE 0 END FROM people",
                "SELECT id, custom_aggregate(name) FROM people",
                "SELECT id, generate_series(1, 2) FROM people",
                "SELECT id, upper(name) FROM people",
                "SELECT id, (SELECT count(*) FROM people) FROM people",
                "SELECT id FROM people ORDER BY count(*)",
                "SELECT id, CAST(id AS custom_type) FROM people",
            ] {
                assert_eq!(
                    source_table(sql, grammar),
                    Err(SourceRefusal::Collapsed),
                    "{grammar:?}: {sql}"
                );
            }
        }
    }

    #[test]
    fn scalar_operators_do_not_change_row_identity() {
        for sql in [
            "SELECT id, name, 1 + 1 FROM people",
            "SELECT id, CASE WHEN id = 1 THEN 'one' ELSE 'other' END FROM people",
            "SELECT id, -id FROM people",
            "SELECT id, name IS NULL FROM people",
        ] {
            let found = source(sql).expect("scalar expressions preserve rows");
            assert_eq!(found.items.last(), Some(&SourceItem::Expression));
        }
    }

    #[test]
    fn gap_filling_cannot_invent_editable_rows() {
        assert_eq!(
            source_table("SELECT id FROM people ORDER BY id WITH FILL", SqlGrammar::ClickHouse),
            Err(SourceRefusal::Collapsed),
        );
    }

    #[test]
    fn executable_comments_do_not_hide_a_different_read() {
        for sql in [
            "SELECT id /*! , count(*) */ FROM people",
            "SELECT id /*M! , count(*) */ FROM people",
            "SELECT 1 /*! INTO @x */",
        ] {
            assert!(source_table(sql, SqlGrammar::MySql).is_err(), "{sql}");
        }
    }

    #[test]
    fn wildcard_names_reject_same_width_reordering_and_renaming() {
        let found = source("SELECT * FROM people").expect("one table");
        let read = ["id", "name", "note"].map(str::to_owned);

        assert_eq!(
            source_columns_for_result(&found, &[info("id"), info("name"), info("note")], &read),
            Some(vec![Some(0), Some(1), Some(2)]),
        );
        assert_eq!(
            source_columns_for_result(&found, &[info("name"), info("id"), info("note")], &read),
            Some(vec![Some(1), Some(0), Some(2)]),
            "a reordered table maps each cell to the column it was read from",
        );
        assert_eq!(
            source_columns_for_result(&found, &[info("id"), info("label"), info("note")], &read),
            None,
            "the old name cannot be mapped to a newly named column",
        );
        assert_eq!(
            source_columns_for_result(&found, &[info("id"), info("Name"), info("note")], &read),
            None,
            "wildcard headers carry the exact catalog spelling",
        );
    }

    #[test]
    fn every_wildcard_segment_is_checked_without_restricting_explicit_aliases() {
        let found = source("SELECT name AS person, p.*, id + 1 AS next, p.* FROM people AS p").expect("one table");
        let columns = [info("id"), info("name"), info("note")];
        let mut read = ["person", "id", "name", "note", "next", "id", "name", "note"].map(str::to_owned);
        assert_eq!(
            source_columns_for_result(&found, &columns, &read),
            Some(vec![
                Some(1),
                Some(0),
                Some(1),
                Some(2),
                None,
                Some(0),
                Some(1),
                Some(2)
            ]),
        );
        read[0] = "display name".to_owned();
        read[4] = "computed alias".to_owned();
        assert!(source_columns_for_result(&found, &columns, &read).is_some());
        read.swap(5, 6);
        assert_eq!(
            source_columns_for_result(&found, &columns, &read).map(|mapped| mapped[5..7].to_vec()),
            Some(vec![Some(1), Some(0)]),
            "each cell maps to the column its header names"
        );
    }

    #[test]
    fn a_result_without_wildcards_keeps_its_aliases_and_checks_its_width() {
        let found = source("SELECT name AS id, id AS name, 1 + 1 AS note FROM people").expect("one table");
        let columns = [info("id"), info("name")];
        let read = ["id", "name", "note"].map(str::to_owned);
        assert_eq!(
            source_columns_for_result(&found, &columns, &read),
            Some(vec![Some(1), Some(0), None]),
        );
        assert_eq!(source_columns_for_result(&found, &columns, &read[..2]), None);
    }
}
