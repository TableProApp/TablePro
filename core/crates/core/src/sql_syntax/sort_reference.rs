use sqlparser::ast::{Expr, SelectItem, SetExpr, Statement, WildcardAdditionalOptions};
use sqlparser::parser::Parser;

use super::SqlGrammar;
use super::parse_type::RECURSION_LIMIT;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SortReference {
    Name,
    // From 1, as ORDER BY counts.
    Position(usize),
}

// None when the ORDER BY could name the column neither way, so the host sorts the rows it holds.
pub fn sort_reference(sql: &str, grammar: SqlGrammar, columns: &[String], column: usize) -> Option<SortReference> {
    let name = columns.get(column)?;
    let unique = !name.is_empty() && columns.iter().filter(|other| same_name(other, name)).count() == 1;
    if unique && is_plain_column(sql, grammar, columns.len(), column, name) {
        return Some(SortReference::Name);
    }
    orders_by_position(grammar).then_some(SortReference::Position(column + 1))
}

// MySQL deprecates positions, and ClickHouse reads them only under enable_positional_arguments. Either would sort
// by the constant, without an error, on a server that does not read the number as a position.
fn orders_by_position(grammar: SqlGrammar) -> bool {
    matches!(
        grammar,
        SqlGrammar::PostgreSql | SqlGrammar::Sqlite | SqlGrammar::MsSql | SqlGrammar::DuckDb
    )
}

// Unquoted names fold case on most engines, so two names that differ only in case may still clash.
fn same_name(a: &str, b: &str) -> bool {
    a == b || a.to_lowercase() == b.to_lowercase()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Item<'a> {
    // An unqualified column or an alias: what an ORDER BY name finds first on every engine.
    Named(&'a str),
    // `t.col`, which SQLite's ORDER BY looks up in the FROM tables, where a join can hold two.
    Qualified(&'a str),
    Wildcard,
    QualifiedWildcard,
    Expression,
}

fn is_plain_column(sql: &str, grammar: SqlGrammar, width: usize, column: usize, name: &str) -> bool {
    let Some(dialect) = grammar.parser_dialect() else {
        return false;
    };
    let Ok(statements) = Parser::new(dialect)
        .with_recursion_limit(RECURSION_LIMIT)
        .try_with_sql(sql)
        .and_then(|mut parser| parser.parse_statements())
    else {
        return false;
    };
    let [Statement::Query(query)] = statements.as_slice() else {
        return false;
    };
    let Some(projection) = projection(&query.body) else {
        return false;
    };
    let items: Vec<Item<'_>> = projection.iter().map(item).collect();
    match item_at(&items, width, column) {
        Some(Item::Named(item)) => same_name(item, name),
        // MySQL looks an ORDER BY name up in the select list before the FROM tables.
        Some(Item::Qualified(item)) => grammar == SqlGrammar::MySql && same_name(item, name),
        Some(Item::Wildcard) => true,
        _ => false,
    }
}

// The leftmost SELECT of a set operation names its columns.
fn projection(body: &SetExpr) -> Option<&[SelectItem]> {
    match body {
        SetExpr::Select(select) => Some(&select.projection),
        SetExpr::Query(query) => projection(&query.body),
        SetExpr::SetOperation { left, .. } => projection(left),
        _ => None,
    }
}

fn item(item: &SelectItem) -> Item<'_> {
    match item {
        SelectItem::UnnamedExpr(Expr::Identifier(ident)) => Item::Named(&ident.value),
        SelectItem::UnnamedExpr(Expr::CompoundIdentifier(parts)) => {
            parts.last().map_or(Item::Expression, |last| Item::Qualified(&last.value))
        }
        SelectItem::ExprWithAlias { alias, .. } => Item::Named(&alias.value),
        SelectItem::Wildcard(options) if plain_wildcard(options) => Item::Wildcard,
        SelectItem::QualifiedWildcard(..) => Item::QualifiedWildcard,
        _ => Item::Expression,
    }
}

// REPLACE and RENAME give a name another value or a value another name.
fn plain_wildcard(options: &WildcardAdditionalOptions) -> bool {
    options.opt_replace.is_none() && options.opt_rename.is_none() && options.opt_alias.is_none()
}

// A wildcard spans as many columns as the result has beyond the other items; with two, only the items outside them
// have a known place.
fn item_at<'a>(items: &[Item<'a>], width: usize, column: usize) -> Option<Item<'a>> {
    let wildcards: Vec<usize> = items
        .iter()
        .enumerate()
        .filter(|(_, item)| matches!(item, Item::Wildcard | Item::QualifiedWildcard))
        .map(|(index, _)| index)
        .collect();
    let (Some(&first), Some(&last)) = (wildcards.first(), wildcards.last()) else {
        return (items.len() == width).then(|| items.get(column).copied()).flatten();
    };
    let after = items.len() - last - 1;
    let spanned = width.checked_sub(first + after)?;
    if column < first {
        return items.get(column).copied();
    }
    if column >= first + spanned {
        return items.get(column - spanned + (last - first) + 1).copied();
    }
    match first == last {
        true => items.get(first).copied(),
        false => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(names: &[&str]) -> Vec<String> {
        names.iter().map(|name| (*name).to_owned()).collect()
    }

    fn reference(grammar: SqlGrammar, sql: &str, columns: &[&str], column: usize) -> Option<SortReference> {
        sort_reference(sql, grammar, &names(columns), column)
    }

    const POSITIONAL: [SqlGrammar; 4] = [
        SqlGrammar::PostgreSql,
        SqlGrammar::Sqlite,
        SqlGrammar::MsSql,
        SqlGrammar::DuckDb,
    ];
    const NAMES_ONLY: [SqlGrammar; 2] = [SqlGrammar::MySql, SqlGrammar::ClickHouse];

    #[test]
    fn a_unique_plain_column_is_named_on_every_engine() {
        for grammar in POSITIONAL.into_iter().chain(NAMES_ONLY) {
            assert_eq!(
                reference(grammar, "SELECT id, name FROM people", &["id", "name"], 1),
                Some(SortReference::Name),
                "{grammar:?}"
            );
            assert_eq!(
                reference(grammar, "SELECT upper(name) AS shout FROM people", &["shout"], 0),
                Some(SortReference::Name),
                "{grammar:?}: an alias"
            );
        }
        assert_eq!(
            reference(SqlGrammar::PostgreSql, "SELECT ID FROM people", &["id"], 0),
            Some(SortReference::Name),
            "PostgreSQL folds the unquoted name"
        );
    }

    #[test]
    fn a_duplicate_name_is_ordered_by_its_position_where_the_engine_takes_one() {
        let sql = "SELECT a.id, b.id FROM a JOIN b ON b.a_id = a.id";
        for grammar in POSITIONAL {
            assert_eq!(
                reference(grammar, sql, &["id", "id"], 1),
                Some(SortReference::Position(2)),
                "{grammar:?}"
            );
            assert_eq!(
                reference(grammar, "SELECT * FROM a JOIN b ON b.a_id = a.id", &["id", "ID", "a_id"], 0),
                Some(SortReference::Position(1)),
                "{grammar:?}: names that differ only in case"
            );
        }
        for grammar in NAMES_ONLY {
            assert_eq!(reference(grammar, sql, &["id", "id"], 1), None, "{grammar:?}");
        }
    }

    #[test]
    fn an_unnamed_expression_is_ordered_by_its_position_where_the_engine_takes_one() {
        for grammar in POSITIONAL {
            assert_eq!(
                reference(grammar, "SELECT name, count(*) FROM people GROUP BY name", &["name", "count"], 1),
                Some(SortReference::Position(2)),
                "{grammar:?}"
            );
            assert_eq!(
                reference(grammar, "SELECT 1 + 1", &[""], 0),
                Some(SortReference::Position(1)),
                "{grammar:?}: a column the engine left unnamed"
            );
        }
        for grammar in NAMES_ONLY {
            assert_eq!(
                reference(grammar, "SELECT name, count(*) FROM people GROUP BY name", &["name", "count(*)"], 1),
                None,
                "{grammar:?}"
            );
        }
    }

    #[test]
    fn a_qualified_column_is_named_only_where_the_select_list_is_searched_first() {
        let sql = "SELECT p.name FROM people p JOIN pets q ON q.owner = p.id";
        assert_eq!(
            reference(SqlGrammar::MySql, sql, &["name"], 0),
            Some(SortReference::Name)
        );
        assert_eq!(
            reference(SqlGrammar::Sqlite, sql, &["name"], 0),
            Some(SortReference::Position(1))
        );
        assert_eq!(reference(SqlGrammar::ClickHouse, sql, &["name"], 0), None);
    }

    #[test]
    fn a_wildcard_spans_the_columns_around_the_other_items() {
        let sql = "SELECT 1 AS one, *, length(name) FROM people";
        let columns = ["one", "id", "name", "length"];
        for (column, expected) in [
            (0, SortReference::Name),
            (1, SortReference::Name),
            (2, SortReference::Name),
            (3, SortReference::Position(4)),
        ] {
            assert_eq!(
                reference(SqlGrammar::Sqlite, sql, &columns, column),
                Some(expected),
                "{column}"
            );
        }
        assert_eq!(
            reference(SqlGrammar::Sqlite, "SELECT p.* FROM people p", &["id"], 0),
            Some(SortReference::Position(1)),
            "a table's wildcard names columns SQLite looks up among every table"
        );
        assert_eq!(
            reference(SqlGrammar::PostgreSql, "SELECT a.*, b.* FROM a, b", &["x", "y", "z"], 1),
            Some(SortReference::Position(2)),
            "where two wildcards meet is not known"
        );
        assert_eq!(
            reference(SqlGrammar::DuckDb, "SELECT * REPLACE (id + 1 AS id) FROM t", &["id"], 0),
            Some(SortReference::Position(1))
        );
    }

    #[test]
    fn a_union_takes_its_names_from_the_first_select() {
        let sql = "SELECT name FROM people UNION SELECT title FROM books";
        assert_eq!(
            reference(SqlGrammar::MsSql, sql, &["name"], 0),
            Some(SortReference::Name)
        );
        assert_eq!(
            reference(SqlGrammar::PostgreSql, "WITH t AS (SELECT 1 AS n) SELECT n FROM t", &["n"], 0),
            Some(SortReference::Name)
        );
    }

    #[test]
    fn a_statement_the_parser_cannot_read_is_never_named() {
        assert_eq!(
            reference(SqlGrammar::Sqlite, "SELECT name FROM people WHERE", &["name"], 0),
            Some(SortReference::Position(1))
        );
        assert_eq!(
            reference(SqlGrammar::MySql, "SELECT name FROM people WHERE", &["name"], 0),
            None
        );
        assert_eq!(
            reference(SqlGrammar::PostgreSql, "SELECT 1; SELECT 2", &["?column?"], 0),
            Some(SortReference::Position(1))
        );
        assert_eq!(reference(SqlGrammar::PostgreSql, "SELECT 1", &["a"], 3), None);
    }
}
