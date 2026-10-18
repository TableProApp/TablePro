//! PostgreSQL's value corpus: the types a real schema holds, at their
//! extremes, and the text the grid shows for each.
//!
//! A browse page reads values in binary and the grid writes them out; an
//! editor run uses the simple query protocol, so it shows the server's
//! own text, as psql does. Where the two spell a value differently, the
//! value names both.

use tablepro_test_support::conformance::{CorpusColumn, ValueCorpusEngine};

use crate::conformance_engine::PgEngine;

impl ValueCorpusEngine for PgEngine {
    fn value_corpus(&self) -> Vec<CorpusColumn> {
        [temporal(), numbers(), documents(), other_types()].concat()
    }
}

fn temporal() -> Vec<CorpusColumn> {
    vec![
        // An instant reads back in UTC whatever offset it was written
        // with; the server's zone is UTC too.
        CorpusColumn::new("v timestamptz")
            .shows_apart(
                "'2024-03-10 02:30:00-08'",
                "2024-03-10 10:30:00+00:00",
                "2024-03-10 10:30:00+00",
            )
            .shows_apart(
                "'2024-06-15 12:00:00.5+05:45'",
                "2024-06-15 06:15:00.5+00:00",
                "2024-06-15 06:15:00.5+00",
            )
            .shows_apart(
                "'1969-12-31 23:59:59.999999+00'",
                "1969-12-31 23:59:59.999999+00:00",
                "1969-12-31 23:59:59.999999+00",
            )
            .shows_apart(
                "'0001-01-01 00:00:00+00'",
                "0001-01-01 00:00:00+00:00",
                "0001-01-01 00:00:00+00",
            )
            .shows_apart(
                "'4713-01-01 00:00:00+00 BC'",
                "4713-01-01 00:00:00+00:00 BC",
                "4713-01-01 00:00:00+00 BC",
            )
            .shows("'infinity'", "infinity")
            .shows("'-infinity'", "-infinity")
            .null(),
        CorpusColumn::new("v timestamp(3)")
            .shows("'2024-02-29 23:59:59.999'", "2024-02-29 23:59:59.999")
            .shows_apart(
                "'2000-01-01 00:00:00'",
                "2000-01-01 00:00:00.000",
                "2000-01-01 00:00:00",
            )
            .shows("'1900-01-01 00:00:00.001'", "1900-01-01 00:00:00.001"),
        CorpusColumn::new("v timestamp")
            .shows("'294276-12-31 23:59:59.999999'", "294276-12-31 23:59:59.999999")
            .shows("'1999-12-31 23:59:59.5'", "1999-12-31 23:59:59.5"),
        CorpusColumn::new("v date")
            .shows("'2024-02-29'", "2024-02-29")
            .shows("'0001-01-01'", "0001-01-01")
            .shows("'4713-01-01 BC'", "4713-01-01 BC")
            .shows("'5874897-12-31'", "5874897-12-31")
            .shows("'infinity'", "infinity")
            .null(),
        CorpusColumn::new("v time(6)")
            .shows_apart("'00:00:00'", "00:00:00.000000", "00:00:00")
            .shows("'23:59:59.999999'", "23:59:59.999999")
            .shows_apart("'24:00:00'", "24:00:00.000000", "24:00:00"),
        CorpusColumn::new("v timetz")
            .shows("'12:34:56+05:30'", "12:34:56+05:30")
            .shows("'00:00:00.25-15:59'", "00:00:00.25-15:59"),
        CorpusColumn::new("v interval")
            .shows_apart(
                "'1 year 2 mons 3 days 04:05:06.789'",
                "P1Y2M3DT4H5M6.789S",
                "1 year 2 mons 3 days 04:05:06.789",
            )
            .shows_apart("'-1 day +02:00:00'", "P-1DT2H", "-1 days +02:00:00")
            .shows_apart("'0'", "PT0S", "00:00:00"),
    ]
}

fn numbers() -> Vec<CorpusColumn> {
    vec![
        CorpusColumn::new("v numeric(38, 10)")
            .shows("12345678901234567890.1234567890", "12345678901234567890.1234567890")
            .shows("-0.0000000001", "-0.0000000001")
            .shows("1.5", "1.5000000000")
            .shows("0", "0.0000000000")
            .null(),
        CorpusColumn::new("v numeric")
            .shows(
                "-123456789012345678901234567890.123456789",
                "-123456789012345678901234567890.123456789",
            )
            .shows("0.000000000000000000000000000001", "0.000000000000000000000000000001")
            .shows("2.50", "2.50")
            .shows("'NaN'", "NaN")
            .shows("'Infinity'", "Infinity")
            .shows("'-Infinity'", "-Infinity"),
        CorpusColumn::new("v money")
            .shows_apart("-12.34", "-12.34", "-$12.34")
            .shows_apart(
                "92233720368547758.07",
                "92233720368547758.07",
                "$92,233,720,368,547,758.07",
            ),
        CorpusColumn::new("v bigint")
            .shows("-9223372036854775808", "-9223372036854775808")
            .shows("9223372036854775807", "9223372036854775807"),
        CorpusColumn::new("v smallint").shows("-32768", "-32768").null(),
        CorpusColumn::new("v real")
            .shows("1.5", "1.5")
            .shows("-0.1", "-0.1")
            .shows("'NaN'", "NaN")
            .shows("'-Infinity'", "-Infinity"),
        CorpusColumn::new("v double precision")
            .shows("0.1", "0.1")
            .shows_apart("-2.5e-5", "-0.000025", "-2.5e-05")
            .shows("'Infinity'", "Infinity"),
        CorpusColumn::new("v boolean")
            .shows_apart("true", "true", "t")
            .shows_apart("false", "false", "f")
            .null(),
    ]
}

fn documents() -> Vec<CorpusColumn> {
    vec![
        CorpusColumn::new("v jsonb")
            .shows(
                r#"'{"b": 1, "a": [1, 2.50, "x"], "ü": null}'"#,
                r#"{"a": [1, 2.50, "x"], "b": 1, "ü": null}"#,
            )
            .shows("'[]'", "[]")
            .shows(r#"'"just text"'"#, r#""just text""#),
        CorpusColumn::new("v json").shows(r#"'{"b":1,  "a":2}'"#, r#"{"b":1,  "a":2}"#),
        CorpusColumn::new("v uuid")
            .shows(
                "'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'",
                "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11",
            )
            .shows(
                "'A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A12'",
                "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a12",
            )
            .null(),
        CorpusColumn::new("v text")
            .shows("'naïve café'", "naïve café")
            .shows("'日本語のテキスト'", "日本語のテキスト")
            .shows("'🦀 emoji 👩‍💻'", "🦀 emoji 👩‍💻")
            .shows("'עברית RTL'", "עברית RTL")
            .shows("'e\u{301}'", "e\u{301}")
            .shows("''", "")
            .shows("E'tab\\there\\nnew line'", "tab\there\nnew line")
            .shows("'it''s'", "it's")
            .null(),
        CorpusColumn::new("v char(5)").shows("'ab'", "ab   "),
        CorpusColumn::new("v varchar(10)").shows("'ünïcödé'", "ünïcödé"),
        CorpusColumn::new("v bytea")
            .shows_apart("'\\xdeadbeef'", "0xdeadbeef", "\\xdeadbeef")
            .shows_apart("''", "0x", "\\x")
            .null(),
        CorpusColumn::new("v integer[]").shows_apart("'{1,NULL,3}'", r#"["1",null,"3"]"#, "{1,NULL,3}"),
        CorpusColumn::new("v text[]").shows_apart(
            r#"'{"a b","c,d",NULL,""}'"#,
            r#"["a b","c,d",null,""]"#,
            r#"{"a b","c,d",NULL,""}"#,
        ),
    ]
}

fn other_types() -> Vec<CorpusColumn> {
    vec![
        CorpusColumn::new("v inet")
            .shows("'192.168.0.1/24'", "192.168.0.1/24")
            .shows("'::1'", "::1"),
        CorpusColumn::new("v cidr").shows("'10.0.0.0/8'", "10.0.0.0/8"),
        CorpusColumn::new("v macaddr").shows("'08:00:2B:01:02:03'", "08:00:2b:01:02:03"),
        CorpusColumn::new("v corpus_mood")
            .after("CREATE TYPE corpus_mood AS ENUM ('sad', 'ok', 'happy')")
            .shows("'happy'", "happy"),
        CorpusColumn::new("v int4range")
            .shows("'[1,10)'", "[1,10)")
            .shows("'empty'", "empty"),
        CorpusColumn::new("v bit(4)").shows("B'1010'", "1010"),
        CorpusColumn::new("v varbit(8)").shows("B'101'", "101"),
        CorpusColumn::new("v point").shows("'(1.5,-2)'", "(1.5,-2)"),
        CorpusColumn::new("v xml").shows("'<a>1</a>'", "<a>1</a>"),
    ]
}

mod suite {
    use crate::conformance_engine::PgEngine;

    tablepro_test_support::value_corpus_suite! {
        engine: PgEngine,
        docker: true,
    }
}
