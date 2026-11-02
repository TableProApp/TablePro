//! DuckDB's value corpus: its integers to 128 bits, decimals at their
//! scale, temporal values at their extremes, and the nested types a
//! table tab and an editor run read as DuckDB's own text. A UNION is not
//! here: its text names no member, so it has no SQL literal to export,
//! and `decode.rs` reads it.

use tablepro_test_support::conformance::{CorpusColumn, ValueCorpusEngine};

use crate::duckdb_engine::DuckDbEngine;

impl ValueCorpusEngine for DuckDbEngine {
    fn value_corpus(&self) -> Vec<CorpusColumn> {
        let mut corpus = numbers();
        corpus.extend(texts());
        corpus.extend(temporal());
        corpus.extend(nested());
        corpus
    }
}

fn numbers() -> Vec<CorpusColumn> {
    vec![
        CorpusColumn::new("v BOOLEAN")
            .shows("true", "true")
            .shows("false", "false")
            .null(),
        CorpusColumn::new("v TINYINT").shows("-128", "-128").shows("127", "127"),
        CorpusColumn::new("v UTINYINT").shows("255", "255"),
        CorpusColumn::new("v INTEGER")
            .shows("2147483647", "2147483647")
            .shows("-2147483648", "-2147483648"),
        CorpusColumn::new("v BIGINT")
            .shows("9223372036854775807", "9223372036854775807")
            .shows("-9223372036854775808", "-9223372036854775808"),
        CorpusColumn::new("v UBIGINT").shows("18446744073709551615", "18446744073709551615"),
        CorpusColumn::new("v HUGEINT")
            .shows(
                "170141183460469231731687303715884105727",
                "170141183460469231731687303715884105727",
            )
            .shows(
                "-170141183460469231731687303715884105728",
                "-170141183460469231731687303715884105728",
            ),
        CorpusColumn::new("v UHUGEINT").shows(
            "340282366920938463463374607431768211455",
            "340282366920938463463374607431768211455",
        ),
        CorpusColumn::new("v FLOAT").shows("1.5", "1.5").shows("0.1", "0.1"),
        CorpusColumn::new("v DOUBLE")
            .shows("0.1", "0.1")
            .shows("-2.5e-5", "-0.000025")
            .shows("'nan'::DOUBLE", "NaN")
            .shows("'-inf'::DOUBLE", "-Infinity"),
        CorpusColumn::new("v DECIMAL(18,3)")
            .shows("1.5", "1.500")
            .shows("-0.001", "-0.001")
            .null(),
        CorpusColumn::new("v DECIMAL(38,10)")
            .shows(
                "1234567890123456789012345678.1234567890",
                "1234567890123456789012345678.1234567890",
            )
            .shows("-12.5", "-12.5000000000"),
    ]
}

fn texts() -> Vec<CorpusColumn> {
    vec![
        CorpusColumn::new("v VARCHAR")
            .shows("'naïve café'", "naïve café")
            .shows("'日本語のテキスト'", "日本語のテキスト")
            .shows("'🦀 emoji 👩‍💻'", "🦀 emoji 👩‍💻")
            .shows("''", "")
            .shows("'it''s'", "it's")
            .shows("'line' || chr(10) || 'break'", "line\nbreak")
            .null(),
        CorpusColumn::new("v BLOB")
            .shows("'\\xDE\\xAD\\xBE\\xEF'::BLOB", "0xdeadbeef")
            .shows("''::BLOB", "0x"),
        CorpusColumn::new("v UUID").shows(
            "'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'",
            "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11",
        ),
        CorpusColumn::new("v JSON").shows(r#"'{"b": 1, "a": [1, 2.50]}'"#, r#"{"b": 1, "a": [1, 2.50]}"#),
        CorpusColumn::new("v BIT").shows("'10101'", "10101").shows("'0'", "0"),
        CorpusColumn::new("v ENUM('sad', 'ok', 'happy')").shows("'happy'", "happy"),
    ]
}

fn temporal() -> Vec<CorpusColumn> {
    vec![
        CorpusColumn::new("v DATE")
            .shows("'2024-02-29'", "2024-02-29")
            .shows("'0044-03-15 (BC)'", "0044-03-15 BC")
            .shows("'infinity'", "infinity")
            .shows("'-infinity'", "-infinity"),
        CorpusColumn::new("v TIME")
            .shows("'12:30:00.123456'", "12:30:00.123456")
            .shows("'00:00:00'", "00:00:00"),
        CorpusColumn::new("v TIMESTAMP")
            .shows("'2024-02-29 12:00:00.123'", "2024-02-29 12:00:00.123")
            .shows("'1999-12-31 23:59:59'", "1999-12-31 23:59:59")
            .shows("'infinity'", "infinity"),
        CorpusColumn::new("v TIMESTAMP_NS").shows("'2024-01-01 00:00:00.123456789'", "2024-01-01 00:00:00.123456789"),
        CorpusColumn::new("v TIMESTAMP_S").shows("'2024-01-01 00:00:01'", "2024-01-01 00:00:01"),
        CorpusColumn::new("v TIMESTAMPTZ")
            .shows("'2024-03-10 10:30:00+02'", "2024-03-10 08:30:00+00:00")
            .shows("'2024-07-01 00:00:00.5+00'", "2024-07-01 00:00:00.5+00:00"),
        CorpusColumn::new("v INTERVAL")
            .shows("INTERVAL '1 year 2 months 3 days 04:05:06.789'", "P1Y2M3DT4H5M6.789S")
            .shows("INTERVAL '-1 day'", "P-1D"),
        // Arrow carries the time alone, so an editor run cannot read it.
        CorpusColumn::new("v TIMETZ").shows_apart(
            "'12:30:00+05:30'",
            "12:30:00+05:30",
            "<unreadable TIME WITH TIME ZONE>",
        ),
    ]
}

fn nested() -> Vec<CorpusColumn> {
    vec![
        CorpusColumn::new("v INTEGER[]")
            .shows("[1, 2, NULL]", "[1, 2, NULL]")
            .shows("[]", "[]"),
        CorpusColumn::new("v VARCHAR[]").shows("['a', 'b c', '', 'it''s', 'x,y']", "[a, b c, '', 'it\\'s', 'x,y']"),
        CorpusColumn::new("v INTEGER[3]").shows("[1, 2, 3]", "[1, 2, 3]"),
        CorpusColumn::new("v STRUCT(a INTEGER, b VARCHAR)")
            .shows("{'a': 1, 'b': 'x y'}", "{'a': 1, 'b': x y}")
            .null(),
        CorpusColumn::new("v MAP(VARCHAR, INTEGER)").shows("MAP {'k1': 1, 'k 2': NULL}", "{k1=1, k 2=NULL}"),
        CorpusColumn::new("v STRUCT(d DECIMAL(10,2), t TIMESTAMP, l DOUBLE[])").shows(
            "{'d': 1.5, 't': TIMESTAMP '2024-01-01 10:00:00', 'l': [1.0, 0.1]}",
            "{'d': 1.50, 't': '2024-01-01 10:00:00', 'l': [1.0, 0.1]}",
        ),
    ]
}

tablepro_test_support::value_corpus_suite! {
    engine: DuckDbEngine,
    docker: false,
}
