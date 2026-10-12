#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use proptest::prelude::*;
use tablepro_policy::classify;

const DRIVERS: [&str; 6] = ["postgres", "mysql", "sqlite", "mssql", "duckdb", "clickhouse"];

fn driver() -> impl Strategy<Value = &'static str> {
    prop::sample::select(DRIVERS.to_vec())
}

fn write_statement() -> impl Strategy<Value = String> {
    prop::sample::select(vec![
        "UPDATE t SET a = 1 WHERE id = 1",
        "DELETE FROM t WHERE id = 1",
        "INSERT INTO t (a) VALUES (1)",
        "DROP TABLE t",
        "TRUNCATE TABLE t",
        "ALTER TABLE t ADD COLUMN b int",
    ])
    .prop_map(str::to_string)
}

fn noise() -> impl Strategy<Value = String> {
    prop::sample::select(vec![" ", "  ", "\n", "\t", " /**/ ", " /* x */ ", " -- c\n"]).prop_map(str::to_string)
}

fn mangle(statement: &str, seps: &[String], upper: &[bool]) -> String {
    let mut out = String::new();
    for (i, word) in statement.split(' ').enumerate() {
        if i > 0 {
            out.push_str(&seps[i % seps.len()]);
        }
        if upper[i % upper.len()] {
            out.push_str(&word.to_uppercase());
        } else {
            out.push_str(&word.to_lowercase());
        }
    }
    out
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(3000))]

    #[test]
    fn classification_never_panics_on_arbitrary_text(sql in ".{0,200}", driver in driver()) {
        let _ = classify(&sql, driver);
    }

    #[test]
    fn a_write_stays_a_write_under_case_whitespace_and_comment_changes(
        statement in write_statement(),
        seps in prop::collection::vec(noise(), 1..6),
        upper in prop::collection::vec(any::<bool>(), 1..6),
        driver in driver(),
    ) {
        let sql = mangle(&statement, &seps, &upper);
        prop_assert!(classify(&sql, driver).class.is_write(), "{driver}: {sql:?}");
    }

    #[test]
    fn a_read_followed_by_a_write_is_never_a_plain_read(
        write in write_statement(),
        seps in prop::collection::vec(noise(), 1..4),
        driver in driver(),
    ) {
        let sql = format!("SELECT 1{};{}{}", seps[0], seps[seps.len() - 1], write);
        let facts = classify(&sql, driver);
        prop_assert!(facts.class.is_write() || facts.is_multi_statement, "{driver}: {sql:?} -> {:?}", facts.class);
    }

    #[test]
    fn anything_that_fails_to_parse_is_treated_as_a_write(sql in "[ -~]{0,60}", driver in driver()) {
        let facts = classify(&sql, driver);
        if facts.parse_error.is_some() {
            prop_assert!(facts.class.is_write(), "{driver}: {sql:?}");
        }
    }
}
