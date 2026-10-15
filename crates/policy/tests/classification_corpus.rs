#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_policy::classify;

fn describe(driver: &str, sql: &str) -> String {
    let facts = classify(sql, driver);
    format!(
        "{driver}|{sql}|{:?}|{}|{}|{}|{}|{}",
        facts.class,
        facts.tables.join(","),
        facts.has_where,
        facts.contains_unscoped_dml,
        facts.is_multi_statement,
        facts.parse_error.is_some()
    )
}

#[test]
fn the_statement_corpus_classifies_as_recorded() {
    let mut mismatches = Vec::new();
    for line in include_str!("classification_corpus.txt").lines() {
        let fields: Vec<&str> = line.split('|').collect();
        let (driver, sql) = (fields[0], fields[1]);
        let actual = describe(driver, sql);
        if actual != line {
            mismatches.push(format!("expected: {line}\n  actual: {actual}"));
        }
    }
    assert!(
        mismatches.is_empty(),
        "{} statement(s) classify differently from the recorded corpus:\n{}",
        mismatches.len(),
        mismatches.join("\n")
    );
}

#[test]
fn every_recorded_write_class_is_still_refused_as_read_only() {
    for line in include_str!("classification_corpus.txt").lines() {
        let fields: Vec<&str> = line.split('|').collect();
        let class = fields[fields.len() - 6];
        let writes = classify(fields[1], fields[0]).writes();
        let expected = !matches!(class, "Select" | "Transaction");
        assert_eq!(writes, expected, "{line}");
    }
}
