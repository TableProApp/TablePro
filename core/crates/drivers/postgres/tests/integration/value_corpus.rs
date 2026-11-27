use tablepro_test_support::conformance::{ValueCorpus, ValueCorpusEngine};

use crate::conformance_engine::PgEngine;

impl ValueCorpusEngine for PgEngine {
    fn value_corpus(&self) -> ValueCorpus {
        ValueCorpus::Postgres
    }
}

mod suite {
    use crate::conformance_engine::PgEngine;

    tablepro_test_support::value_corpus_suite! {
        engine: PgEngine,
        docker: true,
    }
}
