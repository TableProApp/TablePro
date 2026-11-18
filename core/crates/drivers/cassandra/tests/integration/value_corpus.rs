use tablepro_test_support::conformance::{ValueCorpus, ValueCorpusEngine};

use crate::conformance_engine::CqlEngine;
use crate::support::Server;

impl<S: Server> ValueCorpusEngine for CqlEngine<S> {
    fn value_corpus(&self) -> ValueCorpus {
        ValueCorpus::Cassandra
    }
}

mod cassandra_suite {
    use crate::conformance_engine::CqlEngine;
    use crate::support::CassandraServer;

    tablepro_test_support::value_corpus_suite! {
        engine: CqlEngine<CassandraServer>,
        docker: true,
    }
}

mod scylla_suite {
    use crate::conformance_engine::CqlEngine;
    use crate::support::ScyllaServer;

    tablepro_test_support::value_corpus_suite! {
        engine: CqlEngine<ScyllaServer>,
        docker: true,
    }
}
