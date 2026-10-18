//! SQLite's value corpus. A value reads as the storage class SQLite
//! keeps it in, whatever the column declares, so the declared types
//! here are the ones real schemas use.

use tablepro_test_support::conformance::{CorpusColumn, ValueCorpusEngine};

use crate::conformance_engine::SqliteEngine;

impl ValueCorpusEngine for SqliteEngine {
    fn value_corpus(&self) -> Vec<CorpusColumn> {
        vec![
            CorpusColumn::new("v INTEGER")
                .shows("9223372036854775807", "9223372036854775807")
                .shows("-9223372036854775808", "-9223372036854775808")
                .null(),
            CorpusColumn::new("v REAL")
                .shows("0.1", "0.1")
                .shows("-2.5e-5", "-0.000025")
                .shows("1", "1"),
            CorpusColumn::new("v TEXT")
                .shows("'naïve café'", "naïve café")
                .shows("'日本語のテキスト'", "日本語のテキスト")
                .shows("'🦀 emoji 👩‍💻'", "🦀 emoji 👩‍💻")
                .shows("''", "")
                .shows("'it''s'", "it's")
                .shows("'line' || char(10) || 'break'", "line\nbreak")
                .null(),
            CorpusColumn::new("v BLOB")
                .shows("X'DEADBEEF'", "0xdeadbeef")
                .shows("X''", "0x"),
            CorpusColumn::new("v NUMERIC")
                .shows("'1.50'", "1.5")
                .shows("'12'", "12"),
            CorpusColumn::new("v DECIMAL(10, 2)").shows("-12.5", "-12.5"),
            CorpusColumn::new("v DATETIME")
                .shows("'2024-02-29 12:00:00.123'", "2024-02-29 12:00:00.123")
                .shows("'2024-03-10T02:30:00-08:00'", "2024-03-10T02:30:00-08:00"),
            CorpusColumn::new("v BOOLEAN").shows("1", "1").shows("0", "0"),
            CorpusColumn::new("v JSON").shows(r#"'{"b": 1, "a": [1, 2.50]}'"#, r#"{"b": 1, "a": [1, 2.50]}"#),
            CorpusColumn::new("v")
                .shows("42", "42")
                .shows("'text'", "text")
                .shows("X'01'", "0x01")
                .shows("1.5", "1.5"),
        ]
    }
}

tablepro_test_support::value_corpus_suite! {
    engine: SqliteEngine,
    docker: false,
}
