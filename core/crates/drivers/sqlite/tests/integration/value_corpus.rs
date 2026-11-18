use tablepro_test_support::conformance::{ValueCorpus, ValueCorpusEngine};

use crate::sqlite_engine::SqliteEngine;

impl ValueCorpusEngine for SqliteEngine {
    fn value_corpus(&self) -> ValueCorpus {
        ValueCorpus::Sqlite
    }
}

tablepro_test_support::value_corpus_suite! {
    engine: SqliteEngine,
    docker: false,
}
