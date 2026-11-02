use std::ffi::CString;

use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptTokenKind};

const CORPUS: &[&str] = &[
    "SELECT 1; SELECT 'a;b'; -- trailing\nSELECT \"c;d\" /* ; */;",
    "CREATE TRIGGER t AFTER INSERT ON a BEGIN\n  INSERT INTO log VALUES (1);\n  UPDATE a SET n = n + 1;\nEND;\nSELECT 1;",
    "CREATE TEMP TRIGGER t AFTER INSERT ON a BEGIN SELECT CASE WHEN 1 THEN 2 END; END; SELECT 3;",
    "EXPLAIN QUERY PLAN CREATE TEMPORARY TRIGGER t BEGIN SELECT 1; END ; SELECT 2;",
    "SELECT [a;b] FROM t; SELECT [x]]; SELECT `e;f`, $end, end1;",
    "CREATE TABLE t (end INTEGER); CREATE TRIGGER x BEGIN SELECT 1; SELECT 2; end;",
];

fn plan_is_complete(text: &str) -> bool {
    let plan = ScriptPlan::build(
        text,
        SqlGrammar::Sqlite,
        LexicalSettings::default_for(SqlGrammar::Sqlite),
    );
    if !plan.diagnostics().is_empty() {
        return false;
    }
    let Some(last) = plan
        .tokens(0..text.len())
        .filter(|token| !token.kind.is_trivia())
        .last()
    else {
        return false;
    };
    last.kind == ScriptTokenKind::Semicolon
        && plan
            .statement_at(last.range.start)
            .is_none_or(|statement| statement.range.end <= last.range.start)
}

#[test]
fn script_plan_matches_sqlite3_complete() {
    for text in CORPUS {
        for end in (0..=text.len()).filter(|&end| text.is_char_boundary(end)) {
            let prefix = &text[..end];
            let c_prefix = CString::new(prefix).unwrap();
            // SAFETY: c_prefix is a valid NUL-terminated string that outlives the call.
            let sqlite_complete = unsafe { libsqlite3_sys::sqlite3_complete(c_prefix.as_ptr()) } != 0;
            assert_eq!(plan_is_complete(prefix), sqlite_complete, "{prefix:?}");
        }
    }
}
