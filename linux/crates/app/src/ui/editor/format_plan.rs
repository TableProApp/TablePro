use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan};

use super::significant_tokens::significant_tokens;

/// Reformat every statement the formatter can read, and leave the rest
/// exactly as it was.
///
/// sqlformat has its own lexer, and it does not know every dialect the
/// app connects to: it reads `//` as an operator, ends a nested block
/// comment at the first `*/`, treats a backslash as an escape inside
/// quotes, and takes `$$` for a keyword. Reformatting through it can
/// therefore change what a statement means. Each statement is checked
/// against its own tokens afterwards, and one that came back different
/// is written out as the user typed it.
pub fn format_script(text: &str, grammar: SqlGrammar, settings: LexicalSettings) -> String {
    let plan = ScriptPlan::build(text, grammar, settings);
    let mut out = String::with_capacity(text.len());
    let mut cursor = 0usize;
    for statement in plan.statements() {
        let range = statement.range.clone();
        if range.start < cursor || range.end > text.len() {
            continue;
        }
        // Whatever sits between statements is the user's: terminators,
        // GO lines, DELIMITER lines and the blank lines around them.
        out.push_str(text.get(cursor..range.start).unwrap_or_default());
        let source = text.get(range.clone()).unwrap_or_default();
        out.push_str(&format_statement(source, grammar, settings));
        cursor = range.end;
    }
    out.push_str(text.get(cursor..).unwrap_or_default());
    out
}

fn format_statement(source: &str, grammar: SqlGrammar, settings: LexicalSettings) -> String {
    if source.trim().is_empty() {
        return source.to_owned();
    }
    let options = sqlformat::FormatOptions {
        indent: sqlformat::Indent::Spaces(4),
        // sqlformat's reserved list uppercases STATUS and LEVEL, which
        // are ordinary identifiers on ClickHouse and case-sensitive
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

#[cfg(test)]
mod tests {
    use super::*;

    fn format(text: &str, grammar: SqlGrammar) -> String {
        format_script(text, grammar, LexicalSettings::default_for(grammar))
    }

    #[test]
    fn plain_select_is_reflowed_case_preserved() {
        let out = format("select a, b from t where a = 1", SqlGrammar::PostgreSql);

        assert!(out.contains("\n"), "the statement was not reflowed: {out}");
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
        // sqlformat has no `//` comment, so it pulls the comma up onto
        // the comment's line, where ClickHouse would never see it.
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
        // MySQL needs a space after `--` before it is a comment, so
        // `1--1` is a subtraction. A space inserted there would turn
        // the rest of the line into a comment.
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
    fn an_empty_script_stays_empty() {
        assert_eq!(format("", SqlGrammar::PostgreSql), "");
        assert_eq!(format("   \n\n", SqlGrammar::PostgreSql), "   \n\n");
    }
}
