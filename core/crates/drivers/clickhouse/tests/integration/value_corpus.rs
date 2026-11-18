use tablepro_test_support::conformance::{ValueCorpus, ValueCorpusEngine};

use crate::conformance_engine::ClickHouseEngine;

impl ValueCorpusEngine for ClickHouseEngine {
    fn value_corpus(&self) -> ValueCorpus {
        ValueCorpus::Clickhouse
    }
}

mod suite {
    use crate::conformance_engine::ClickHouseEngine;

    tablepro_test_support::value_corpus_suite! {
        engine: ClickHouseEngine,
        docker: true,
    }
}
