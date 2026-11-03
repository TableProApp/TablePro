use std::ops::Range;

use crate::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptTokenKind};
use crate::sql_syntax::{SqlGrammar, StatementAccess, statement_access};

// None for a write or a script: running either again for a sort would repeat it.
pub fn with_order_by(sql: &str, grammar: SqlGrammar, order: &str) -> Option<String> {
    if !grammar.is_sql() || grammar == SqlGrammar::Cql || order.trim().is_empty() {
        return None;
    }
    let plan = ScriptPlan::build(sql, grammar, LexicalSettings::default_for(grammar));
    let [statement] = plan.statements() else {
        return None;
    };
    if !plan.diagnostics().is_empty() || statement_access(sql, grammar) != StatementAccess::Read {
        return None;
    }

    let mut tokens = Vec::new();
    for token in plan.tokens(statement.range.clone()) {
        match token.kind {
            kind if kind.is_trivia() => {}
            // What a MySQL executable comment holds runs on some servers only.
            ScriptTokenKind::ExecutableMarker | ScriptTokenKind::Directive | ScriptTokenKind::Unterminated => {
                return None;
            }
            kind => tokens.push((kind, token.range)),
        }
    }
    while tokens
        .last()
        .is_some_and(|(kind, _)| *kind == ScriptTokenKind::Semicolon)
    {
        tokens.pop();
    }
    let (first, last) = (tokens.first()?, tokens.last()?);
    if !opens_query(first.0, word(sql, &first.1), grammar) {
        return None;
    }

    let top_level = top_level_words(sql, &tokens);
    let tail = top_level
        .iter()
        .find(|&&index| starts_row_limit(sql, &tokens, index))
        .copied();
    let head_end = tail.unwrap_or(tokens.len());
    let order_start = top_level
        .iter()
        .take_while(|&&index| index < head_end)
        .filter(|&&index| {
            tokens
                .get(index)
                .is_some_and(|(_, range)| word(sql, range).eq_ignore_ascii_case("ORDER"))
        })
        .filter(|&&index| {
            tokens
                .get(index + 1)
                .is_some_and(|(_, range)| word(sql, range).eq_ignore_ascii_case("BY"))
        })
        .last()
        .copied();
    let kept = order_start.unwrap_or(head_end);
    let head = &tokens[..kept];
    let (head_first, head_last) = (head.first()?, head.last()?);

    let mut sorted = format!(
        "{} ORDER BY {}",
        sql.get(head_first.1.start..head_last.1.end)?,
        order.trim()
    );
    if let Some(tail) = tail {
        sorted.push(' ');
        sorted.push_str(sql.get(tokens.get(tail)?.1.start..last.1.end)?);
    }
    Some(sorted)
}

// SHOW, EXPLAIN and the like read too, but take no ORDER BY.
fn opens_query(kind: ScriptTokenKind, text: &str, grammar: SqlGrammar) -> bool {
    let verbs: &[&str] = match grammar {
        SqlGrammar::MsSql => &["SELECT", "WITH"],
        _ => &["SELECT", "WITH", "VALUES", "TABLE"],
    };
    kind == ScriptTokenKind::OpenParen
        || (kind == ScriptTokenKind::Word && verbs.iter().any(|verb| text.eq_ignore_ascii_case(verb)))
}

fn top_level_words(sql: &str, tokens: &[(ScriptTokenKind, Range<usize>)]) -> Vec<usize> {
    let mut depth = 0usize;
    let mut words = Vec::new();
    for (index, (kind, range)) in tokens.iter().enumerate() {
        match kind {
            ScriptTokenKind::OpenParen => depth += 1,
            ScriptTokenKind::CloseParen => depth = depth.saturating_sub(1),
            ScriptTokenKind::Word if depth == 0 && !word(sql, range).is_empty() => words.push(index),
            _ => {}
        }
    }
    words
}

// MySQL does not reserve OFFSET, so what follows the word tells the clause from a column of that name.
fn starts_row_limit(sql: &str, tokens: &[(ScriptTokenKind, Range<usize>)], index: usize) -> bool {
    let Some((_, this)) = tokens.get(index) else {
        return false;
    };
    let this = word(sql, this);
    let Some((_, next)) = tokens.get(index + 1) else {
        return false;
    };
    let next = word(sql, next);
    if this.eq_ignore_ascii_case("FETCH") {
        return next.eq_ignore_ascii_case("FIRST") || next.eq_ignore_ascii_case("NEXT");
    }
    if !this.eq_ignore_ascii_case("LIMIT") && !this.eq_ignore_ascii_case("OFFSET") {
        return false;
    }
    next.starts_with(|first: char| first.is_ascii_digit() || matches!(first, '?' | ':' | '$' | '@'))
        || next.eq_ignore_ascii_case("ALL")
}

fn word<'a>(sql: &'a str, range: &Range<usize>) -> &'a str {
    sql.get(range.clone()).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sorted(sql: &str) -> Option<String> {
        with_order_by(sql, SqlGrammar::PostgreSql, "\"total\" DESC")
    }

    #[test]
    fn a_plain_select_gets_the_order_at_its_end() {
        assert_eq!(
            sorted("SELECT * FROM orders").as_deref(),
            Some("SELECT * FROM orders ORDER BY \"total\" DESC")
        );
    }

    #[test]
    fn the_order_goes_before_the_row_limit_and_keeps_it() {
        assert_eq!(
            sorted("SELECT * FROM orders LIMIT 100 OFFSET 20").as_deref(),
            Some("SELECT * FROM orders ORDER BY \"total\" DESC LIMIT 100 OFFSET 20")
        );
        assert_eq!(
            sorted("SELECT * FROM orders FETCH FIRST 5 ROWS ONLY").as_deref(),
            Some("SELECT * FROM orders ORDER BY \"total\" DESC FETCH FIRST 5 ROWS ONLY")
        );
    }

    #[test]
    fn the_statements_own_order_is_replaced() {
        assert_eq!(
            sorted("SELECT * FROM orders ORDER BY id LIMIT 10").as_deref(),
            Some("SELECT * FROM orders ORDER BY \"total\" DESC LIMIT 10")
        );
    }

    #[test]
    fn an_order_inside_parentheses_stays() {
        assert_eq!(
            sorted("SELECT id, row_number() OVER (ORDER BY id) FROM (SELECT * FROM t ORDER BY id LIMIT 5) s")
                .as_deref(),
            Some(
                "SELECT id, row_number() OVER (ORDER BY id) FROM (SELECT * FROM t ORDER BY id LIMIT 5) s \
                 ORDER BY \"total\" DESC"
            )
        );
    }

    #[test]
    fn a_column_called_offset_is_not_a_row_limit() {
        assert_eq!(
            with_order_by("SELECT offset, name FROM events", SqlGrammar::MySql, "`name` ASC").as_deref(),
            Some("SELECT offset, name FROM events ORDER BY `name` ASC")
        );
    }

    #[test]
    fn a_trailing_semicolon_and_comment_are_dropped() {
        assert_eq!(
            sorted("SELECT * FROM orders; -- all of them\n").as_deref(),
            Some("SELECT * FROM orders ORDER BY \"total\" DESC")
        );
        assert_eq!(
            sorted("SELECT * FROM orders -- the lot\nLIMIT 5").as_deref(),
            Some("SELECT * FROM orders ORDER BY \"total\" DESC LIMIT 5")
        );
    }

    #[test]
    fn a_union_is_sorted_as_a_whole() {
        assert_eq!(
            sorted("SELECT a FROM x UNION SELECT a FROM y LIMIT 3").as_deref(),
            Some("SELECT a FROM x UNION SELECT a FROM y ORDER BY \"total\" DESC LIMIT 3")
        );
    }

    #[test]
    fn a_with_query_is_sorted() {
        assert_eq!(
            sorted("WITH t AS (SELECT 1 AS total LIMIT 1) SELECT * FROM t").as_deref(),
            Some("WITH t AS (SELECT 1 AS total LIMIT 1) SELECT * FROM t ORDER BY \"total\" DESC")
        );
    }

    #[test]
    fn sql_server_keeps_its_offset_fetch() {
        assert_eq!(
            with_order_by(
                "SELECT * FROM orders ORDER BY id OFFSET 10 ROWS FETCH NEXT 5 ROWS ONLY",
                SqlGrammar::MsSql,
                "[total] DESC"
            )
            .as_deref(),
            Some("SELECT * FROM orders ORDER BY [total] DESC OFFSET 10 ROWS FETCH NEXT 5 ROWS ONLY")
        );
    }

    #[test]
    fn writes_scripts_and_statements_that_take_no_order_are_refused() {
        assert_eq!(sorted("DELETE FROM orders"), None);
        assert_eq!(sorted("SELECT * INTO copy FROM orders"), None);
        assert_eq!(sorted("SELECT 1; SELECT 2"), None);
        assert_eq!(sorted("EXPLAIN SELECT * FROM orders"), None);
        assert_eq!(sorted("SELECT 'open"), None);
        assert_eq!(sorted(""), None);
        assert_eq!(with_order_by("SELECT * FROM t", SqlGrammar::PostgreSql, " "), None);
        assert_eq!(with_order_by("KEYS *", SqlGrammar::Redis, "a ASC"), None);
    }
}
