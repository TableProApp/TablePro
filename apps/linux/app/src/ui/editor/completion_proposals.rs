use std::ops::Range;

use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{
    LexicalSettings, OpenConstruct, ScriptDiagnostic, ScriptPlan, ScriptTokenKind,
};

use super::completion::{SchemaIndex, Scope, candidate_sql, scope_at};
use super::completion_identifiers::split_table_reference;

pub(super) struct Candidates {
    pub range: Range<usize>,
    pub values: Vec<(String, String)>,
}

pub(super) fn candidates(sql: &str, cursor: usize, index: &SchemaIndex) -> Candidates {
    let grammar = index.grammar.unwrap_or(SqlGrammar::PostgreSql);
    let Some(mut range) = replacement_range(sql, cursor, grammar) else {
        return Candidates {
            range: cursor..cursor,
            values: Vec::new(),
        };
    };
    let quoted = sql[range.start..].starts_with(['"', '`', '[']);
    let scope = scope_at(sql, range.start, index);
    if scope == Scope::Tables {
        range.start = qualified_start(sql, range.start, grammar);
    }
    let mut values = candidate_sql(sql, range.start, index);
    if !quoted && !matches!(scope, Scope::ColumnsOf(_)) {
        values.extend(super::SQL_KEYWORDS.split_whitespace().map(str::to_string));
    }
    let prefix = normalized(&sql[range.start..cursor]);
    let values = values
        .into_iter()
        .filter(|value| {
            normalized(value).starts_with(&prefix)
                || split_table_reference(value, index.grammar)
                    .is_some_and(|(_, name)| normalized(&name).starts_with(&prefix))
        })
        .map(|value| {
            let label = split_table_reference(&value, index.grammar)
                .filter(|(schema, _)| schema.is_none() && value.starts_with(['"', '`', '[']))
                .map(|(_, name)| name)
                .unwrap_or_else(|| value.clone());
            (label, value)
        })
        .collect();
    Candidates { range, values }
}

fn normalized(text: &str) -> String {
    text.chars()
        .filter(|character| !matches!(character, '\"' | '`' | '[' | ']'))
        .collect::<String>()
        .to_lowercase()
}

fn replacement_range(sql: &str, cursor: usize, grammar: SqlGrammar) -> Option<Range<usize>> {
    let plan = ScriptPlan::build(sql, grammar, LexicalSettings::default_for(grammar));
    let token = plan
        .tokens(0..sql.len())
        .find(|token| {
            token.range.start == cursor
                && matches!(
                    token.kind,
                    ScriptTokenKind::Word | ScriptTokenKind::QuotedIdentifier | ScriptTokenKind::Unterminated
                )
        })
        .or_else(|| {
            plan.tokens(0..sql.len())
                .find(|token| token.range.start < cursor && token.range.end >= cursor)
        });
    let Some(token) = token else {
        return Some(cursor..cursor);
    };
    match token.kind {
        ScriptTokenKind::Word | ScriptTokenKind::QuotedIdentifier => Some(token.range),
        ScriptTokenKind::Unterminated if token.range.start == cursor => None,
        ScriptTokenKind::Unterminated
            if plan.diagnostics().iter().any(|diagnostic| {
                matches!(
                    diagnostic,
                    ScriptDiagnostic::Unterminated { construct: OpenConstruct::QuotedIdentifier, start }
                        if *start == token.range.start
                )
            }) =>
        {
            Some(token.range.start..cursor)
        }
        ScriptTokenKind::Whitespace
        | ScriptTokenKind::Punct
        | ScriptTokenKind::OpenParen
        | ScriptTokenKind::CloseParen
        | ScriptTokenKind::Semicolon => Some(cursor..cursor),
        _ => None,
    }
}

fn qualified_start(sql: &str, start: usize, grammar: SqlGrammar) -> usize {
    let plan = ScriptPlan::build(sql, grammar, LexicalSettings::default_for(grammar));
    let tokens: Vec<_> = plan.tokens(0..start).filter(|token| !token.kind.is_trivia()).collect();
    let mut start = start;
    for pair in tokens.rchunks_exact(2) {
        let [name, dot] = pair else {
            break;
        };
        if &sql[dot.range.clone()] != "."
            || !matches!(name.kind, ScriptTokenKind::Word | ScriptTokenKind::QuotedIdentifier)
        {
            break;
        }
        start = name.range.start;
    }
    start
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn table_completion_replaces_a_qualified_reference_as_a_whole() {
        let mut index = SchemaIndex::default();
        index.tables = vec!["\"odd.schema\".\"Users\"".into()];
        index.grammar = Some(SqlGrammar::PostgreSql);
        let sql = "SELECT * FROM \"odd.schema\".\"Us\" WHERE true";
        let cursor = sql.find("Us").unwrap() + 1;
        let candidates = candidates(sql, cursor, &index);
        assert_eq!(&sql[candidates.range], "\"odd.schema\".\"Us\"");
        assert_eq!(
            candidates.values,
            vec![("\"odd.schema\".\"Users\"".into(), "\"odd.schema\".\"Users\"".into())]
        );
    }

    #[test]
    fn columns_use_each_engine_delimiters_and_never_offer_unrelated_editor_words() {
        for (grammar, driver) in [
            (SqlGrammar::PostgreSql, "postgres"),
            (SqlGrammar::MySql, "mysql"),
            (SqlGrammar::MsSql, "mssql"),
            (SqlGrammar::Sqlite, "sqlite"),
            (SqlGrammar::ClickHouse, "clickhouse"),
        ] {
            let mut index = SchemaIndex::default();
            index.grammar = Some(grammar);
            index.set_columns("users", vec!["a.b\"` ]".into()]);
            let sql = "SELECT u. FROM users u; SELECT unrelated_editor_word";
            let values = candidates(sql, "SELECT u.".len(), &index).values;
            assert_eq!(values.len(), 1);
            assert_eq!(values[0].1, tablepro_core::sql_dialect::quote_ident(driver, "a.b\"` ]"));
        }
    }

    #[test]
    fn whitespace_after_an_alias_dot_keeps_only_its_columns() {
        let mut index = SchemaIndex::default();
        index.grammar = Some(SqlGrammar::PostgreSql);
        index.set_columns("users", vec!["user_column".into()]);
        index.set_columns("orders", vec!["order_column".into()]);
        let sql = "SELECT u.  FROM users u JOIN orders o ON true";
        let values = candidates(sql, "SELECT u. ".len(), &index).values;
        assert_eq!(values, vec![("user_column".into(), "\"user_column\"".into())]);
    }

    #[test]
    fn unfinished_identifier_quotes_keep_the_exact_reference_for_each_dialect() {
        for (grammar, driver) in [
            (SqlGrammar::PostgreSql, "postgres"),
            (SqlGrammar::MySql, "mysql"),
            (SqlGrammar::MsSql, "mssql"),
            (SqlGrammar::Sqlite, "sqlite"),
            (SqlGrammar::ClickHouse, "clickhouse"),
        ] {
            let mut index = SchemaIndex::default();
            index.grammar = Some(grammar);
            let reference = tablepro_core::sql_dialect::quote_ident(driver, "Users");
            index.tables.push(reference.clone());
            let partial = format!("{}Us", &reference[..1]);
            let sql = format!("SELECT * FROM {partial}");
            let candidates = candidates(&sql, sql.len(), &index);
            assert_eq!(candidates.values, vec![("Users".into(), reference)]);
            assert_eq!(&sql[candidates.range], partial);
        }
    }

    #[test]
    fn a_cursor_at_the_start_of_an_identifier_replaces_its_whole_token() {
        let sql = "SELECT * FROM \"Users\" WHERE true";
        let cursor = "SELECT * FROM ".len();
        let candidates = candidates(sql, cursor, &SchemaIndex::default());
        assert_eq!(&sql[candidates.range], "\"Users\"");
    }

    #[test]
    fn completion_before_an_unfinished_quote_refuses_an_ambiguous_suffix() {
        let mut index = SchemaIndex::default();
        index.tables.push("\"Users\"".into());
        let sql = "SELECT * FROM \"Us WHERE true";
        assert!(candidates(sql, "SELECT * FROM ".len(), &index).values.is_empty());
    }

    #[test]
    fn mysql_unterminated_double_quotes_remain_a_string_literal() {
        let mut index = SchemaIndex::default();
        index.grammar = Some(SqlGrammar::MySql);
        let sql = "SELECT \"SE";
        assert!(candidates(sql, sql.len(), &index).values.is_empty());
    }

    #[test]
    fn literals_and_comments_do_not_offer_sql_identifiers() {
        let index = SchemaIndex::default();
        for sql in [
            "SELECT 'word",
            "SELECT 'word'",
            "SELECT -- word",
            "SELECT /* word",
            "SELECT $$word",
            "SELECT 123",
        ] {
            assert!(candidates(sql, sql.len(), &index).values.is_empty(), "{sql}");
        }
    }
}
