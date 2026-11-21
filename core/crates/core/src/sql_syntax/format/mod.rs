// Reformatting a SQL script without changing what it says.

mod significant_tokens;

use std::ops::Range;

use crate::sql_syntax::SqlGrammar;
use crate::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptTokenKind};

use self::significant_tokens::significant_tokens;

// sqlformat has its own lexer, which does not know every dialect: it reads `//` as an operator, ends a nested block
// comment at the first `*/`, treats a backslash as an escape inside quotes, takes `$$` for a keyword, and spaces `+=`,
// `b'01'` and `GROUP_CONCAT(`. So each statement is checked against its own tokens afterwards, and one that came back
// different is written out as typed.
pub fn format_script(text: &str, grammar: SqlGrammar, settings: LexicalSettings) -> String {
    let plan = ScriptPlan::build(text, grammar, settings);
    let mut out = String::with_capacity(text.len());
    let mut cursor = 0usize;
    for statement in plan.statements() {
        let range = statement.range.clone();
        if range.start < cursor || range.end > text.len() {
            continue;
        }
        // Terminators, GO and DELIMITER lines and the blank lines around them are the user's.
        out.push_str(text.get(cursor..range.start).unwrap_or_default());
        let source = text.get(range.clone()).unwrap_or_default();
        out.push_str(&format_statement(source, grammar, settings));
        cursor = range.end;
    }
    out.push_str(text.get(cursor..).unwrap_or_default());
    out
}

// The formatted script and where byte `caret` lands in it. A format changes only blanks, so the caret keeps the
// characters around it: one touching the next character stays before it, one in blanks after a character after that.
pub fn format_with_caret(text: &str, grammar: SqlGrammar, settings: LexicalSettings, caret: usize) -> (String, usize) {
    let formatted = format_script(text, grammar, settings);
    let caret = map_caret(text, &formatted, grammar, settings, caret);
    (formatted, caret)
}

// The selected bytes of `text` formatted, or as they are when the result would change the whole text's tokens: a
// selection can start inside a comment or a string its own text cannot show.
pub fn format_selection(text: &str, grammar: SqlGrammar, settings: LexicalSettings, range: Range<usize>) -> String {
    let Some(source) = text.get(range.clone()) else {
        return String::new();
    };
    let formatted = format_script(source, grammar, settings);
    let mut replaced = text.to_owned();
    replaced.replace_range(range, &formatted);
    if significant_tokens(&replaced, grammar, settings) == significant_tokens(text, grammar, settings) {
        formatted
    } else {
        source.to_owned()
    }
}

fn format_statement(source: &str, grammar: SqlGrammar, settings: LexicalSettings) -> String {
    if source.trim().is_empty() {
        return source.to_owned();
    }
    let options = sqlformat::FormatOptions {
        indent: sqlformat::Indent::Spaces(4),
        // sqlformat's reserved list uppercases STATUS and LEVEL, ordinary identifiers on ClickHouse and case-sensitive
        // table names on MySQL under Linux.
        uppercase: None,
        lines_between_queries: 1,
        dialect: format_dialect(grammar),
        ..sqlformat::FormatOptions::default()
    };
    let formatted = sqlformat::format(source, &sqlformat::QueryParams::None, &options);
    if significant_tokens(&formatted, grammar, settings) == significant_tokens(source, grammar, settings) {
        formatted
    } else {
        source.to_owned()
    }
}

fn format_dialect(grammar: SqlGrammar) -> sqlformat::Dialect {
    match grammar {
        SqlGrammar::PostgreSql => sqlformat::Dialect::PostgreSql,
        SqlGrammar::MsSql => sqlformat::Dialect::SQLServer,
        _ => sqlformat::Dialect::Generic,
    }
}

fn map_caret(text: &str, formatted: &str, grammar: SqlGrammar, settings: LexicalSettings, caret: usize) -> usize {
    let original = ScriptPlan::build(text, grammar, settings);
    let changed = ScriptPlan::build(formatted, grammar, settings);
    let tokens = original
        .tokens(0..text.len())
        .filter(|token| token.kind != ScriptTokenKind::Whitespace);
    let mapped = changed
        .tokens(0..formatted.len())
        .filter(|token| token.kind != ScriptTokenKind::Whitespace);
    for (token, target) in tokens.zip(mapped) {
        // Spaces inside a token are its contents, not the formatter's indentation.
        if token.range.contains(&caret) {
            return target.range.start + (caret - token.range.start).min(target.range.len());
        }
    }
    let before = text.get(..caret.min(text.len())).unwrap_or(text);
    let kept = before.chars().filter(|c| !c.is_whitespace()).count();
    if kept == 0 {
        // The blanks before the first statement are kept as they are.
        let first = formatted.find(|c: char| !c.is_whitespace()).unwrap_or(formatted.len());
        return before.len().min(first);
    }
    let touches_next = text
        .get(before.len()..)
        .and_then(|rest| rest.chars().next())
        .is_none_or(|next| !next.is_whitespace());
    let mut seen = 0usize;
    for (at, c) in formatted.char_indices() {
        if c.is_whitespace() {
            continue;
        }
        if touches_next && seen == kept {
            return at;
        }
        seen += 1;
        if !touches_next && seen == kept {
            return at + c.len_utf8();
        }
    }
    formatted.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn format(text: &str, grammar: SqlGrammar) -> String {
        format_script(text, grammar, LexicalSettings::default_for(grammar))
    }

    fn format_at(marked: &str, grammar: SqlGrammar) -> String {
        let caret = marked.find('|').expect("a caret mark");
        let text = marked.replacen('|', "", 1);
        let (mut out, at) = format_with_caret(&text, grammar, LexicalSettings::default_for(grammar), caret);
        out.insert(at, '|');
        out
    }

    fn select(source: &str, selection: &str) -> String {
        let start = source.find(selection).expect("the selected text");
        format_selection(
            source,
            SqlGrammar::PostgreSql,
            LexicalSettings::default_for(SqlGrammar::PostgreSql),
            start..start + selection.len(),
        )
    }

    #[test]
    fn plain_select_is_reflowed_case_preserved() {
        let out = format("select a, b from t where a = 1", SqlGrammar::PostgreSql);

        assert!(out.contains('\n'), "the statement was not reflowed: {out}");
        assert!(out.contains("select"), "the keyword case was changed: {out}");
        assert!(!out.contains("SELECT"), "the keyword case was changed: {out}");
    }

    #[test]
    fn format_is_idempotent_for_plain_statements() {
        let once = format("select a, b from t where a = 1", SqlGrammar::PostgreSql);
        let twice = format(&once, SqlGrammar::PostgreSql);

        assert_eq!(once, twice);
    }

    #[test]
    fn dollar_tag_body_is_untouched() {
        let source = "CREATE FUNCTION f() RETURNS int AS $body$ SELECT  1; $body$ LANGUAGE sql";

        let out = format(source, SqlGrammar::PostgreSql);

        assert!(
            out.contains("$body$ SELECT  1; $body$"),
            "the body was rewritten: {out}"
        );
    }

    #[test]
    fn a_comment_that_would_swallow_the_code_after_it_keeps_the_statement_verbatim() {
        // sqlformat has no `//` comment, so it pulls the comma onto the comment's line, where ClickHouse never sees it.
        let source = "SELECT a // x\n, b FROM t";

        assert_eq!(format(source, SqlGrammar::ClickHouse), source);
    }

    #[test]
    fn a_slash_comment_at_the_end_of_a_statement_still_ends_it() {
        let out = format("SELECT 1 // note", SqlGrammar::ClickHouse);

        assert!(out.ends_with("// note"), "the comment stopped ending the line: {out}");
    }

    #[test]
    fn nested_block_comment_kept_verbatim() {
        let source = "SELECT /* outer /* inner */ still outer */ 1";

        assert_eq!(format(source, SqlGrammar::PostgreSql), source);
    }

    #[test]
    fn standard_conforming_backslash_string_kept_verbatim() {
        let source = r"SELECT 'C:\' AS a, 'x'";

        assert_eq!(format(source, SqlGrammar::PostgreSql), source);
    }

    #[test]
    fn mysql_minus_minus_arithmetic_stays_arithmetic() {
        // MySQL needs a space after `--` before it is a comment, so a space there would comment out the rest.
        let out = format("SELECT 1--1", SqlGrammar::MySql);

        assert!(out.contains("--1"), "the operator was broken up: {out}");
        assert!(!out.contains("-- 1"), "the arithmetic became a comment: {out}");
    }

    #[test]
    fn go_lines_preserved() {
        let source = "select 1\nGO\nselect 2\nGO\n";

        let out = format(source, SqlGrammar::MsSql);

        assert_eq!(out.matches("GO").count(), 2, "a batch separator was lost: {out}");
        assert!(out.ends_with("GO\n"), "the trailing separator moved: {out}");
    }

    #[test]
    fn delimiter_procedure_preserved() {
        let source = "DELIMITER $$\nCREATE PROCEDURE p() BEGIN SELECT 1; END$$\nDELIMITER ;\n";

        let out = format(source, SqlGrammar::MySql);

        assert!(out.contains("DELIMITER $$"), "the delimiter line was lost: {out}");
        assert!(out.contains("DELIMITER ;"), "the delimiter reset was lost: {out}");
    }

    #[test]
    fn statements_sqlformat_would_respace_into_something_else_kept_verbatim() {
        let cases = [
            // `+=` would become `+ =`.
            ("SET @x += 1", SqlGrammar::MsSql),
            // A bit literal and a charset introducer would become a column with a string alias.
            ("select b'01', _utf8mb4'x' from t", SqlGrammar::MySql),
            // `@@ version` is not a system variable.
            ("select @@version", SqlGrammar::MySql),
            // `U & '…'` is a bitwise and, not a Unicode escape string.
            (r"select U&'d\0061t'", SqlGrammar::PostgreSql),
            // A string continued on the next line is one string; on one line the two are a syntax error.
            ("select 'a'\n'b'", SqlGrammar::PostgreSql),
            // A query parameter's name, colon and type are one unit.
            ("SELECT {id:UInt32}", SqlGrammar::ClickHouse),
        ];

        for (source, grammar) in cases {
            assert_eq!(format(source, grammar), source, "{grammar:?}");
        }
    }

    #[test]
    fn a_mysql_call_keeps_its_name_against_its_paren() {
        // sqlformat writes `GROUP_CONCAT (a)`, which MySQL reads as a stored function of that name.
        let out = format("SELECT GROUP_CONCAT(a) FROM t", SqlGrammar::MySql);

        assert!(
            out.contains("GROUP_CONCAT(a)"),
            "the call was split from its paren: {out}"
        );
    }

    #[test]
    fn mysql_statements_with_untouched_calls_are_still_formatted() {
        for source in [
            "select count(*), max(a) from t",
            "insert into t (a, b) values (1, 2)",
            "select ifnull(a, 0) from t where a in(1, 2)",
        ] {
            let out = format(source, SqlGrammar::MySql);

            assert!(out.contains('\n'), "the statement was not reflowed: {out}");
        }
    }

    #[test]
    fn an_empty_script_stays_empty() {
        assert_eq!(format("", SqlGrammar::PostgreSql), "");
        assert_eq!(format("   \n\n", SqlGrammar::PostgreSql), "   \n\n");
    }

    #[test]
    fn the_caret_keeps_the_characters_around_it() {
        assert_eq!(
            format_at("select a, b from t where a = 1|", SqlGrammar::PostgreSql),
            format("select a, b from t where a = 1", SqlGrammar::PostgreSql) + "|"
        );
        let touching = format_at("select a, |b from t", SqlGrammar::PostgreSql);
        assert!(touching.contains("|b"), "the caret left the name it was at: {touching}");
        let inside = format_at("select a, bc|d from t", SqlGrammar::PostgreSql);
        assert!(
            inside.contains("bc|d"),
            "the caret left its place in the name: {inside}"
        );
        let after = format_at("select a,|   b from t", SqlGrammar::PostgreSql);
        assert!(after.contains("a,|"), "the caret left the comma it followed: {after}");
        assert_eq!(format_at("|select 1", SqlGrammar::PostgreSql).find('|'), Some(0));
    }

    #[test]
    fn the_caret_stays_put_in_a_statement_kept_as_typed() {
        let source = "SELECT a // x\n, b| FROM t";

        assert_eq!(format_at(source, SqlGrammar::ClickHouse), source);
    }

    #[test]
    fn the_caret_in_blanks_at_the_start_stays_at_the_start() {
        assert_eq!(format_at(" | ", SqlGrammar::PostgreSql), " | ");
        assert_eq!(format_at("|", SqlGrammar::PostgreSql), "|");
    }

    #[test]
    fn the_caret_keeps_spaces_inside_preserved_tokens() {
        for token in ["'a  | b'", "\"a  | b\"", "/* a  | b */", "'😀  | b'"] {
            let source = format!("select {token}, c from t");
            let out = format_at(&source, SqlGrammar::PostgreSql);
            assert!(out.contains(token), "the caret moved inside a token: {out}");
        }
    }

    #[test]
    fn a_selection_inside_a_comment_string_or_body_is_kept_as_it_is() {
        let selection = "select a,b from t";
        for source in [
            format!("-- {selection}"),
            format!("select '{selection}'"),
            format!("/* {selection} */"),
            format!("select $body${selection}$body$"),
        ] {
            assert_eq!(select(&source, selection), selection);
        }
    }

    #[test]
    fn a_selected_statement_is_reflowed_alone() {
        let selection = "select a,b from t";

        let out = select(&format!("select 1; {selection}; select 2"), selection);

        assert_eq!(out, format(selection, SqlGrammar::PostgreSql));
        assert!(out.contains('\n'));
    }
}
