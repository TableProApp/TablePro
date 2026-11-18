use tablepro_test_fixtures::MysqlFlavour;
use tablepro_test_support::conformance::{ValueCorpus, ValueCorpusEngine};

use crate::conformance_engine::{MySqlEngine, Server};

impl<S: Server> ValueCorpusEngine for MySqlEngine<S> {
    fn value_corpus(&self) -> ValueCorpus {
        match S::FLAVOUR {
            MysqlFlavour::Mysql => ValueCorpus::Mysql,
            MysqlFlavour::Mariadb => ValueCorpus::Mariadb,
        }
    }
}

mod mysql_suite {
    use crate::conformance_engine::{MySqlEngine, MysqlServer};

    tablepro_test_support::value_corpus_suite! {
        engine: MySqlEngine<MysqlServer>,
        docker: true,
    }
}

mod mariadb_suite {
    use crate::conformance_engine::{MariadbServer, MySqlEngine};

    tablepro_test_support::value_corpus_suite! {
        engine: MySqlEngine<MariadbServer>,
        docker: true,
    }
}
