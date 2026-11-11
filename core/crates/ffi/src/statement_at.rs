use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan};

// UTF-16 offsets, which is how the host's own text counts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct StatementSpan {
    pub start: u32,
    pub end: u32,
}

// The statement the caret is in, or the last one that starts before it, as the Linux editor's Run Statement picks it.
pub(crate) fn statement_at(sql: &str, caret: u32, grammar: SqlGrammar) -> Option<StatementSpan> {
    let plan = ScriptPlan::build(sql, grammar, LexicalSettings::default_for(grammar));
    let byte = byte_at_unit(sql, usize::try_from(caret).ok()?);
    let statement = plan.statement_at(byte)?;
    Some(StatementSpan {
        start: units_before(sql, statement.range.start)?,
        end: units_before(sql, statement.range.end)?,
    })
}

// A unit inside a surrogate pair belongs to the character the pair makes.
fn byte_at_unit(text: &str, unit: usize) -> usize {
    let mut units = 0;
    for (byte, c) in text.char_indices() {
        units += c.len_utf16();
        if units > unit {
            return byte;
        }
    }
    text.len()
}

fn units_before(text: &str, byte: usize) -> Option<u32> {
    let units: usize = text
        .char_indices()
        .take_while(|(start, _)| *start < byte)
        .map(|(_, c)| c.len_utf16())
        .sum();
    u32::try_from(units).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn picked(sql: &str, caret: u32, grammar: SqlGrammar) -> Option<String> {
        let span = statement_at(sql, caret, grammar)?;
        let units: Vec<u16> = sql.encode_utf16().collect();
        Some(String::from_utf16_lossy(&units[span.start as usize..span.end as usize]))
    }

    #[test]
    fn the_caret_picks_the_statement_it_sits_in() {
        let sql = "SELECT 1; DELETE FROM t";

        assert_eq!(picked(sql, 4, SqlGrammar::PostgreSql).as_deref(), Some("SELECT 1"));
        assert_eq!(
            picked(sql, 20, SqlGrammar::PostgreSql).as_deref(),
            Some("DELETE FROM t")
        );
    }

    #[test]
    fn a_caret_after_a_terminator_or_past_the_end_picks_the_statement_before_it() {
        let sql = "SELECT 1;\n\nSELECT 2;";

        assert_eq!(picked(sql, 9, SqlGrammar::Sqlite).as_deref(), Some("SELECT 1"));
        assert_eq!(picked(sql, 10, SqlGrammar::Sqlite).as_deref(), Some("SELECT 1"));
        assert_eq!(picked(sql, 9999, SqlGrammar::Sqlite).as_deref(), Some("SELECT 2"));
    }

    #[test]
    fn a_semicolon_inside_a_string_is_not_a_boundary() {
        let sql = "INSERT INTO t VALUES ('a;b'); SELECT 2";

        assert_eq!(
            picked(sql, 24, SqlGrammar::MySql).as_deref(),
            Some("INSERT INTO t VALUES ('a;b')")
        );
    }

    #[test]
    fn a_dollar_quoted_body_is_one_statement() {
        let sql = "CREATE FUNCTION f() RETURNS int AS $$ SELECT 1; $$ LANGUAGE sql;\nSELECT 2;";

        let statement = picked(sql, 40, SqlGrammar::PostgreSql).unwrap_or_default();

        assert!(statement.starts_with("CREATE FUNCTION"), "{statement}");
        assert!(statement.ends_with("LANGUAGE sql"), "{statement}");
    }

    #[test]
    fn a_mysql_procedure_between_delimiter_lines_is_one_statement() {
        let sql = "DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END//\nDELIMITER ;\nSELECT 3;";

        assert_eq!(
            picked(sql, 40, SqlGrammar::MySql).as_deref(),
            Some("CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END")
        );
    }

    #[test]
    fn a_sql_server_batch_runs_whole_up_to_its_go_line() {
        let sql = "SELECT 1; SELECT 2\nGO\nSELECT 3";

        assert_eq!(picked(sql, 3, SqlGrammar::MsSql).as_deref(), Some("SELECT 1; SELECT 2"));
        assert_eq!(picked(sql, 24, SqlGrammar::MsSql).as_deref(), Some("SELECT 3"));
    }

    #[test]
    fn offsets_count_utf16_units_past_characters_outside_the_basic_plane() {
        // The emoji is two UTF-16 units and four UTF-8 bytes.
        let sql = "SELECT '😀'; SELECT 'tên'";

        let span = statement_at(sql, 14, SqlGrammar::PostgreSql);

        assert_eq!(span, Some(StatementSpan { start: 13, end: 25 }));
        assert_eq!(picked(sql, 14, SqlGrammar::PostgreSql).as_deref(), Some("SELECT 'tên'"));
        assert_eq!(picked(sql, 8, SqlGrammar::PostgreSql).as_deref(), Some("SELECT '😀'"));
    }

    #[test]
    fn text_with_no_statement_has_none() {
        assert_eq!(statement_at("", 0, SqlGrammar::PostgreSql), None);
        assert_eq!(
            statement_at("  \n -- only a comment\n", 3, SqlGrammar::PostgreSql),
            None
        );
    }
}
