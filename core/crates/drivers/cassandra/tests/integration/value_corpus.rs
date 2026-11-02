//! The CQL value corpus: every native type at its extremes, the
//! collections, and the text the grid shows for each.

use tablepro_test_support::conformance::{CorpusColumn, ValueCorpusEngine};

use crate::conformance_engine::CqlEngine;
use crate::support::Server;

impl<S: Server> ValueCorpusEngine for CqlEngine<S> {
    fn value_corpus(&self) -> Vec<CorpusColumn> {
        vec![
            CorpusColumn::new("v int")
                .shows("-2147483648", "-2147483648")
                .shows("2147483647", "2147483647")
                .null(),
            CorpusColumn::new("v bigint")
                .shows("-9223372036854775808", "-9223372036854775808")
                .shows("9223372036854775807", "9223372036854775807"),
            CorpusColumn::new("v smallint").shows("-32768", "-32768"),
            CorpusColumn::new("v tinyint").shows("127", "127"),
            CorpusColumn::new("v varint").shows(
                "-123456789012345678901234567890123456789",
                "-123456789012345678901234567890123456789",
            ),
            CorpusColumn::new("v decimal")
                .shows("-12345.6789", "-12345.6789")
                .shows("0.10", "0.10")
                .null(),
            CorpusColumn::new("v float").shows("1.5", "1.5"),
            CorpusColumn::new("v double")
                .shows("0.1", "0.1")
                .shows("NaN", "NaN")
                .shows("-Infinity", "-Infinity"),
            CorpusColumn::new("v boolean")
                .shows("true", "true")
                .shows("false", "false"),
            CorpusColumn::new("v text")
                .shows("'naïve café'", "naïve café")
                .shows("'日本語のテキスト'", "日本語のテキスト")
                .shows("'🦀 emoji 👩‍💻'", "🦀 emoji 👩‍💻")
                .shows("''", "")
                .shows("'it''s'", "it's")
                .null(),
            CorpusColumn::new("v ascii").shows("'plain'", "plain"),
            CorpusColumn::new("v blob")
                .shows("0xff00fe", "0xff00fe")
                .shows("0x", "0x"),
            CorpusColumn::new("v uuid")
                .shows(
                    "123e4567-e89b-12d3-a456-426614174000",
                    "123e4567-e89b-12d3-a456-426614174000",
                )
                .null(),
            CorpusColumn::new("v timeuuid").shows(
                "50554d6e-29bb-11e5-b345-feff819cdc9f",
                "50554d6e-29bb-11e5-b345-feff819cdc9f",
            ),
            CorpusColumn::new("v inet")
                .shows("'192.168.0.1'", "192.168.0.1")
                .shows("'2001:db8::1'", "2001:db8::1"),
            CorpusColumn::new("v date")
                .shows("'1970-01-01'", "1970-01-01")
                .shows("'2024-02-29'", "2024-02-29"),
            CorpusColumn::new("v time")
                .shows("'00:00:00'", "00:00:00.000000000")
                .shows("'23:59:59.999999999'", "23:59:59.999999999"),
            CorpusColumn::new("v timestamp")
                .shows("'2024-02-29 12:00:00.123+0000'", "2024-02-29 12:00:00.123+00:00")
                .shows("'1970-01-01 00:00:00+0000'", "1970-01-01 00:00:00.000+00:00"),
            CorpusColumn::new("v duration").shows("1y2mo3d4h5m6s7ms", "P1Y2M3DT4H5M6.007S"),
            CorpusColumn::new("v list<int>").shows("[1, 2, 3]", r#"["1","2","3"]"#),
            CorpusColumn::new("v set<text>").shows("{'b', 'a'}", r#"["a","b"]"#),
            CorpusColumn::new("v map<text, int>").shows("{'a': 1}", "{'a': 1}"),
            CorpusColumn::new("v frozen<tuple<int, text>>").shows("(1, 'x')", r#"["1","x"]"#),
        ]
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
