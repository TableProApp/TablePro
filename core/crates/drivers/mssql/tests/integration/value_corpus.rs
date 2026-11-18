use tablepro_test_support::conformance::{ValueCorpus, ValueCorpusEngine};

use crate::conformance_engine::MssqlEngine;

impl ValueCorpusEngine for MssqlEngine {
    fn value_corpus(&self) -> ValueCorpus {
        ValueCorpus::Mssql
    }
}

mod suite {
    use crate::conformance_engine::MssqlEngine;

    tablepro_test_support::value_corpus_suite! {
        engine: MssqlEngine,
        docker: true,
    }
}
