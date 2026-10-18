//! ClickHouse's value corpus: the types a real schema holds, at their
//! extremes, and the text the grid shows for each.

use tablepro_test_support::conformance::{CorpusColumn, ValueCorpusEngine};

use crate::conformance_engine::ClickHouseEngine;

impl ValueCorpusEngine for ClickHouseEngine {
    fn value_corpus(&self) -> Vec<CorpusColumn> {
        vec![
            // A DateTime prints the wall time of its column's zone.
            CorpusColumn::new("COLUMN v Nullable(DateTime('Asia/Kolkata'))")
                .shows("'2024-03-10 02:30:00'", "2024-03-10 02:30:00")
                .shows("'1970-01-01 05:30:00'", "1970-01-01 05:30:00")
                .null(),
            // Nanoseconds in an Int64 end in 2262.
            CorpusColumn::new("COLUMN v DateTime64(9, 'UTC')")
                .shows("'1900-01-01 00:00:00.000000001'", "1900-01-01 00:00:00.000000001")
                .shows("'2262-04-11 23:47:16.854775807'", "2262-04-11 23:47:16.854775807")
                .shows("'2024-02-29 12:00:00'", "2024-02-29 12:00:00.000000000"),
            CorpusColumn::new("COLUMN v DateTime64(3)")
                .shows("'2024-01-01 00:00:00.5'", "2024-01-01 00:00:00.500")
                .shows("'2299-12-31 23:59:59.999'", "2299-12-31 23:59:59.999"),
            CorpusColumn::new("COLUMN v Date")
                .shows("'1970-01-01'", "1970-01-01")
                .shows("'2149-06-06'", "2149-06-06"),
            CorpusColumn::new("COLUMN v Date32")
                .shows("'1900-01-01'", "1900-01-01")
                .shows("'2299-12-31'", "2299-12-31"),
            CorpusColumn::new("COLUMN v Decimal(76, 38)")
                .shows(
                    "toDecimal256('-12345678901234567890123456789012345678.12345678901234567890123456789012345678', 38)",
                    "-12345678901234567890123456789012345678.12345678901234567890123456789012345678",
                )
                .shows("0", "0.00000000000000000000000000000000000000"),
            CorpusColumn::new("COLUMN v Nullable(Decimal(9, 2))")
                .shows("-1.5", "-1.50")
                .null(),
            CorpusColumn::new("COLUMN v Int128").shows(
                "-170141183460469231731687303715884105728",
                "-170141183460469231731687303715884105728",
            ),
            CorpusColumn::new("COLUMN v UInt256").shows(
                "'115792089237316195423570985008687907853269984665640564039457584007913129639935'",
                "115792089237316195423570985008687907853269984665640564039457584007913129639935",
            ),
            CorpusColumn::new("COLUMN v UInt64").shows("18446744073709551615", "18446744073709551615"),
            CorpusColumn::new("COLUMN v Float64")
                .shows("0.1", "0.1")
                .shows("nan", "NaN")
                .shows("-inf", "-Infinity"),
            CorpusColumn::new("COLUMN v Float32").shows("1.5", "1.5"),
            CorpusColumn::new("COLUMN v Bool").shows("true", "true").shows("false", "false"),
            CorpusColumn::new("COLUMN v Nullable(UUID)")
                .shows(
                    "'123e4567-e89b-12d3-a456-426614174000'",
                    "123e4567-e89b-12d3-a456-426614174000",
                )
                .null(),
            CorpusColumn::new("COLUMN v IPv4").shows("'192.168.0.1'", "192.168.0.1"),
            CorpusColumn::new("COLUMN v IPv6").shows("'2001:db8::1'", "2001:db8::1"),
            CorpusColumn::new("COLUMN v Enum8('a' = 1, 'b c' = 2)").shows("'b c'", "b c"),
            CorpusColumn::new("COLUMN v Nullable(String)")
                .shows("'naïve café'", "naïve café")
                .shows("'日本語のテキスト'", "日本語のテキスト")
                .shows("'🦀 emoji 👩‍💻'", "🦀 emoji 👩‍💻")
                .shows("''", "")
                .shows("'it\\'s'", "it's")
                .shows("'line\\nbreak'", "line\nbreak")
                .null(),
            CorpusColumn::new("COLUMN v LowCardinality(String)").shows("'low'", "low"),
            CorpusColumn::new("COLUMN v FixedString(4)").shows("'ab'", "ab\0\0"),
            // A String holds bytes; ones that are not UTF-8 stay bytes.
            CorpusColumn::new("COLUMN v String").shows("unhex('FF00FE')", "0xff00fe"),
            CorpusColumn::new("COLUMN v Array(Nullable(Int32))").shows("[1, NULL, 3]", r#"["1",null,"3"]"#),
            CorpusColumn::new("COLUMN v Map(String, UInt8)").shows("map('a', 1)", r#"{"a":1}"#),
            CorpusColumn::new("COLUMN v Tuple(String, Int8)").shows("('x', -1)", r#"["x",-1]"#),
        ]
    }
}

mod suite {
    use crate::conformance_engine::ClickHouseEngine;

    tablepro_test_support::value_corpus_suite! {
        engine: ClickHouseEngine,
        docker: true,
    }
}
