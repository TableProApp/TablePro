use std::iter::Peekable;
use std::ops::Range;

use super::SqlGrammar;
use super::script::{LexicalSettings, ScriptPlan, ScriptToken, ScriptTokenKind};

const KINDS: [&str; 5] = ["FUNCTION", "PROC", "PROCEDURE", "TRIGGER", "SEQUENCE"];

/// `sql` ending in exactly one `;`, so a definition pasted after another
/// statement runs as its own.
pub fn terminated(sql: &str) -> String {
    format!("{};", sql.trim_end().trim_end_matches(';').trim_end())
}

/// `sql`, the CREATE of a routine, a sequence or a trigger as the server
/// keeps it, with `quoted_schema.` put before the object's name when the
/// text names no schema, and before a SQL Server trigger's table too:
/// SQL Server keeps a module's last CREATE or ALTER as it was written,
/// and SQLite drops the schema from what it stores. Run elsewhere, an
/// unqualified name lands in the session's default schema. Text of any
/// other shape comes back unchanged. This is the header rewrite SQL
/// Server's own scripting does on stored module text.
pub fn qualify_created_name(sql: &str, grammar: SqlGrammar, quoted_schema: &str) -> String {
    let plan = ScriptPlan::build(sql, grammar, LexicalSettings::default_for(grammar));
    let mut header = Header {
        sql,
        grammar,
        tokens: plan
            .tokens(0..sql.len())
            .filter(|token| !token.kind.is_trivia())
            .peekable(),
    };
    let mut at = header.unqualified_names().unwrap_or_default();
    at.sort_unstable();
    let mut qualified = sql.to_owned();
    for start in at.into_iter().rev() {
        qualified.insert_str(start, &format!("{quoted_schema}."));
    }
    qualified
}

/// Whether any way the editor may read `sql` finds a client directive in
/// it: a SQL Server module can hold a line that is only `GO`, and the
/// server keeps it as part of the body, but the editor would end a batch
/// there and run what follows on its own. `true` when the text names too
/// many versions to try every reading.
pub fn holds_client_directive(sql: &str, grammar: SqlGrammar) -> bool {
    ScriptPlan::server_readings(sql, grammar).is_none_or(|mut plans| {
        plans.any(|plan| {
            plan.tokens(0..sql.len())
                .any(|token| token.kind == ScriptTokenKind::Directive)
        })
    })
}

/// `create`, a MySQL routine or trigger as `SHOW CREATE` gives it, framed
/// in `DELIMITER ;;` as mysqldump writes it: the editor, as the mysql
/// client, ends a statement at each `;`, which a body holds. `None` when
/// the editor would still not read it back as the one statement, as a
/// body that ends a string in `\` under `NO_BACKSLASH_ESCAPES` would not.
pub fn mysql_program_script(create: &str) -> Option<String> {
    let create = create.trim_end().trim_end_matches(';').trim_end();
    let script = format!("DELIMITER ;;\n{create};;\nDELIMITER ;\n");
    let plan = ScriptPlan::build(
        &script,
        SqlGrammar::MySql,
        LexicalSettings::default_for(SqlGrammar::MySql),
    );
    let batches: Vec<&str> = plan
        .batches()
        .iter()
        .filter_map(|batch| script.get(batch.range.clone()))
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .collect();
    (plan.diagnostics().is_empty() && batches == [create]).then_some(script)
}

struct Header<'a, I: Iterator<Item = ScriptToken>> {
    sql: &'a str,
    grammar: SqlGrammar,
    tokens: Peekable<I>,
}

impl<'a, I: Iterator<Item = ScriptToken>> Header<'a, I> {
    /// Where an unqualified name starts: the object's, then a SQL Server
    /// trigger's table. `None` when the text does not open as expected.
    fn unqualified_names(&mut self) -> Option<Vec<usize>> {
        let verb = self.word(&["CREATE", "ALTER"])?;
        if verb.eq_ignore_ascii_case("CREATE") && self.word(&["OR"]).is_some() {
            self.word(&["ALTER", "REPLACE"])?;
        }
        let _ = self.word(&["TEMP", "TEMPORARY"]);
        let kind = self.word(&KINDS)?;
        if self.word(&["IF"]).is_some() {
            self.word(&["NOT"])?;
            self.word(&["EXISTS"])?;
        }
        let name = self.unqualified_name()?;
        if self.grammar != SqlGrammar::MsSql || !kind.eq_ignore_ascii_case("TRIGGER") {
            return Some(name.into_iter().collect());
        }
        self.word(&["ON"])?;
        // A DDL trigger fires ON DATABASE or ON ALL SERVER and takes no
        // schema at all.
        if self.peek_word(&["DATABASE", "ALL"]) {
            return Some(Vec::new());
        }
        let table = self.unqualified_name()?;
        Some(name.into_iter().chain(table).collect())
    }

    /// The start of a one-part name, `None` inside for one with a schema.
    fn unqualified_name(&mut self) -> Option<Option<usize>> {
        let first = self.name()?;
        let mut parts = 1;
        while self.punct(".") {
            self.name()?;
            parts += 1;
        }
        Some((parts == 1).then_some(first.start))
    }

    fn name(&mut self) -> Option<Range<usize>> {
        let is_name = match self.tokens.peek()?.kind {
            ScriptTokenKind::Word | ScriptTokenKind::QuotedIdentifier => true,
            // SQLite takes a string where a name goes.
            ScriptTokenKind::StringLiteral => self.grammar == SqlGrammar::Sqlite,
            _ => false,
        };
        if !is_name {
            return None;
        }
        self.tokens.next().map(|token| token.range)
    }

    fn word(&mut self, words: &[&str]) -> Option<&'a str> {
        let sql = self.sql;
        let token = self.tokens.peek()?;
        let text = sql.get(token.range.clone())?;
        let found = token.kind == ScriptTokenKind::Word && words.iter().any(|word| text.eq_ignore_ascii_case(word));
        found.then(|| {
            self.tokens.next();
            text
        })
    }

    fn peek_word(&mut self, words: &[&str]) -> bool {
        let sql = self.sql;
        self.tokens.peek().is_some_and(|token| {
            token.kind == ScriptTokenKind::Word
                && sql
                    .get(token.range.clone())
                    .is_some_and(|text| words.iter().any(|word| text.eq_ignore_ascii_case(word)))
        })
    }

    fn punct(&mut self, punct: &str) -> bool {
        let sql = self.sql;
        let found = self
            .tokens
            .peek()
            .is_some_and(|token| token.kind == ScriptTokenKind::Punct && sql.get(token.range.clone()) == Some(punct));
        if found {
            self.tokens.next();
        }
        found
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mssql(sql: &str) -> String {
        qualify_created_name(sql, SqlGrammar::MsSql, "[sales]")
    }

    fn sqlite(sql: &str) -> String {
        qualify_created_name(sql, SqlGrammar::Sqlite, "\"archive\"")
    }

    #[test]
    fn one_semicolon_ends_the_text() {
        assert_eq!(
            terminated("CREATE FUNCTION f()\n$function$\n"),
            "CREATE FUNCTION f()\n$function$;"
        );
        assert_eq!(terminated("CREATE TRIGGER t ON x ;\n"), "CREATE TRIGGER t ON x;");
        assert_eq!(terminated("SELECT 1"), "SELECT 1;");
    }

    #[test]
    fn an_unqualified_routine_gets_the_schema() {
        assert_eq!(
            mssql("CREATE PROCEDURE p AS SELECT 1"),
            "CREATE PROCEDURE [sales].p AS SELECT 1"
        );
        assert_eq!(
            mssql("/* note */\r\ncreate   proc [p]\nAS SELECT 1"),
            "/* note */\r\ncreate   proc [sales].[p]\nAS SELECT 1"
        );
        assert_eq!(
            mssql("CREATE OR ALTER FUNCTION f() RETURNS int AS BEGIN RETURN 1 END"),
            "CREATE OR ALTER FUNCTION [sales].f() RETURNS int AS BEGIN RETURN 1 END"
        );
        assert_eq!(
            mssql("ALTER PROCEDURE p AS SELECT 2"),
            "ALTER PROCEDURE [sales].p AS SELECT 2",
            "the server keeps the last ALTER as written"
        );
        assert_eq!(
            mssql("alter trigger tr ON orders AFTER INSERT AS SELECT 1"),
            "alter trigger [sales].tr ON [sales].orders AFTER INSERT AS SELECT 1"
        );
    }

    #[test]
    fn a_qualified_name_is_left_as_written() {
        for sql in [
            "CREATE PROCEDURE dbo.p AS SELECT 1",
            "CREATE PROCEDURE [dbo] . [p] AS SELECT 1",
            "CREATE FUNCTION db.dbo.f() RETURNS int AS BEGIN RETURN 1 END",
        ] {
            assert_eq!(mssql(sql), sql);
        }
    }

    #[test]
    fn a_sql_server_trigger_gets_the_schema_on_its_name_and_its_table() {
        assert_eq!(
            mssql("CREATE TRIGGER tr ON orders AFTER INSERT AS SELECT 1"),
            "CREATE TRIGGER [sales].tr ON [sales].orders AFTER INSERT AS SELECT 1"
        );
        assert_eq!(
            mssql("CREATE TRIGGER sales.tr ON [orders] AFTER INSERT AS SELECT 1"),
            "CREATE TRIGGER sales.tr ON [sales].[orders] AFTER INSERT AS SELECT 1"
        );
        let ddl = "CREATE TRIGGER audit ON DATABASE FOR CREATE_TABLE AS SELECT 1";
        assert_eq!(mssql(ddl), ddl);
    }

    #[test]
    fn a_sqlite_trigger_gets_the_schema_on_its_name_only() {
        assert_eq!(
            sqlite("CREATE TRIGGER audit AFTER DELETE ON old BEGIN SELECT 1; END"),
            "CREATE TRIGGER \"archive\".audit AFTER DELETE ON old BEGIN SELECT 1; END"
        );
        assert_eq!(
            sqlite("CREATE TRIGGER IF  NOT EXISTS \"x y\" AFTER INSERT ON t BEGIN SELECT 1; END"),
            "CREATE TRIGGER IF  NOT EXISTS \"archive\".\"x y\" AFTER INSERT ON t BEGIN SELECT 1; END"
        );
        assert_eq!(
            sqlite("CREATE TRIGGER 'x' AFTER INSERT ON t BEGIN SELECT 1; END"),
            "CREATE TRIGGER \"archive\".'x' AFTER INSERT ON t BEGIN SELECT 1; END"
        );
    }

    #[test]
    fn a_go_line_in_a_module_is_a_client_directive() {
        let split = "CREATE PROCEDURE p AS SELECT 1\nGO\nALTER ROLE db_owner ADD MEMBER someone";
        assert!(holds_client_directive(split, SqlGrammar::MsSql));
        assert!(!holds_client_directive(
            "CREATE PROCEDURE p AS SELECT 'GO'\n-- GO\n",
            SqlGrammar::MsSql
        ));
        let overloads = "CREATE FUNCTION f(int) RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql;\n\n\
                         CREATE FUNCTION f(text) RETURNS text AS $$ SELECT 'x' $$ LANGUAGE sql;";
        assert!(!holds_client_directive(overloads, SqlGrammar::PostgreSql));
        assert!(holds_client_directive("DELIMITER ;;\nSELECT 1;;", SqlGrammar::MySql));
    }

    #[test]
    fn a_mysql_program_is_one_statement_to_the_editor() {
        let body = "CREATE DEFINER=`root`@`%` PROCEDURE `p`()\nBEGIN\n  SELECT 'a;b';\n  SELECT 2;\nEND";

        let script = mysql_program_script(&format!("{body};")).expect("a script");

        assert_eq!(script, format!("DELIMITER ;;\n{body};;\nDELIMITER ;\n"));
        assert_eq!(mysql_program_script("CREATE PROCEDURE `p`() SELECT '\\'"), None);
    }

    #[test]
    fn text_of_another_shape_is_left_alone() {
        for sql in ["SELECT 1", "CREATE TABLE t (id int)", "CREATE TRIGGER", ""] {
            assert_eq!(mssql(sql), sql);
        }
    }
}
