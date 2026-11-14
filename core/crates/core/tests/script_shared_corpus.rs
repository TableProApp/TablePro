//! The macOS app reads scripts with its own Swift lexer, and its tests
//! run this same corpus, so both read each case where the engine does.

use serde::Deserialize;
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptReadError, ScriptReader, ScriptUnitKind};

#[derive(Deserialize)]
struct Corpus {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    dialect: String,
    sql: String,
    statements: Vec<String>,
    batches: Option<Vec<Batch>>,
}

#[derive(Deserialize, Clone, PartialEq, Debug)]
struct Batch {
    text: String,
    repeat: u32,
}

fn grammar(dialect: &str) -> Option<SqlGrammar> {
    match dialect {
        "postgresql" => Some(SqlGrammar::PostgreSql),
        "mysql" => Some(SqlGrammar::MySql),
        "sqlite" => Some(SqlGrammar::Sqlite),
        "mssql" => Some(SqlGrammar::MsSql),
        "clickhouse" => Some(SqlGrammar::ClickHouse),
        "duckdb" => Some(SqlGrammar::DuckDb),
        "cql" => Some(SqlGrammar::Cql),
        _ => None,
    }
}

fn cases() -> serde_json::Result<Vec<Case>> {
    let corpus: Corpus = serde_json::from_str(include_str!("fixtures/sql_script_corpus.json"))?;
    Ok(corpus.cases)
}

fn read_in_pieces(grammar: SqlGrammar, text: &str, piece: usize) -> Result<Vec<Batch>, ScriptReadError> {
    let mut reader = ScriptReader::new(grammar);
    let mut units = Vec::new();
    let mut start = 0;
    while start < text.len() {
        let mut end = (start + piece).min(text.len());
        while !text.is_char_boundary(end) {
            end += 1;
        }
        units.extend(reader.push(&text[start..end])?);
        start = end;
    }
    units.extend(reader.finish()?);
    Ok(units
        .into_iter()
        .filter(|unit| unit.kind == ScriptUnitKind::Run)
        .map(|unit| Batch {
            text: unit.text,
            repeat: unit.repeat,
        })
        .collect())
}

#[test]
fn every_dialect_the_corpus_names_has_a_grammar() {
    let unknown: Vec<String> = cases()
        .expect("the corpus")
        .into_iter()
        .filter(|case| grammar(&case.dialect).is_none())
        .map(|case| case.dialect)
        .collect();
    assert!(unknown.is_empty(), "{unknown:?}");
}

#[test]
fn the_plan_splits_each_case_where_the_engine_does() {
    let mut misread = Vec::new();
    for case in cases().expect("the corpus") {
        let Some(grammar) = grammar(&case.dialect) else {
            continue;
        };
        let plan = ScriptPlan::build(&case.sql, grammar, LexicalSettings::default_for(grammar));
        let statements: Vec<&str> = plan
            .statements()
            .iter()
            .map(|statement| statement.text(&case.sql))
            .collect();
        if statements != case.statements {
            misread.push(format!("{}: {statements:?}", case.name));
        }
        if let Some(batches) = &case.batches {
            let read: Vec<Batch> = plan
                .batches()
                .iter()
                .map(|batch| Batch {
                    text: case.sql[batch.range.clone()].to_owned(),
                    repeat: batch.repeat.get(),
                })
                .collect();
            if &read != batches {
                misread.push(format!("{} batches: {read:?}", case.name));
            }
        }
    }
    assert!(misread.is_empty(), "{misread:#?}");
}

#[test]
fn the_reader_sends_each_case_as_the_client_does_however_it_is_cut() {
    let mut misread = Vec::new();
    for case in cases().expect("the corpus") {
        let Some(grammar) = grammar(&case.dialect) else {
            continue;
        };
        let expected = case.batches.clone().unwrap_or_else(|| {
            case.statements
                .iter()
                .map(|text| Batch {
                    text: text.clone(),
                    repeat: 1,
                })
                .collect()
        });
        for piece in [1, 2, 7, case.sql.len().max(1)] {
            let read = read_in_pieces(grammar, &case.sql, piece).expect("a script the reader holds");
            if read != expected {
                misread.push(format!("{} in pieces of {piece}: {read:?}", case.name));
            }
        }
    }
    assert!(misread.is_empty(), "{misread:#?}");
}
