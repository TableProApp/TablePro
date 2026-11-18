use tablepro_test_support::conformance::{ValueCorpus, ValueCorpusEngine};

use crate::duckdb_engine::DuckDbEngine;

impl ValueCorpusEngine for DuckDbEngine {
    fn value_corpus(&self) -> ValueCorpus {
        ValueCorpus::Duckdb
    }
}

tablepro_test_support::value_corpus_suite! {
    engine: DuckDbEngine,
    docker: false,
}
