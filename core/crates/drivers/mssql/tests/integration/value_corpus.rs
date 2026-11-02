//! SQL Server's value corpus: the types a real schema holds, at their
//! extremes, and the text the grid shows for each.
//!
//! tiberius describes a result column by its wire type alone, with no
//! scale, so an editor run shows the fraction a time value has. A
//! browse page takes the scale from the catalogue.

use tablepro_test_support::conformance::{CorpusColumn, ValueCorpusEngine};

use crate::conformance_engine::MssqlEngine;

impl ValueCorpusEngine for MssqlEngine {
    fn value_corpus(&self) -> Vec<CorpusColumn> {
        vec![
            CorpusColumn::new("v datetime2(7)")
                .shows_apart(
                    "'0001-01-01 00:00:00'",
                    "0001-01-01 00:00:00.0000000",
                    "0001-01-01 00:00:00",
                )
                .shows("'9999-12-31 23:59:59.9999999'", "9999-12-31 23:59:59.9999999")
                .shows_apart(
                    "'2024-02-29 12:00:00.5'",
                    "2024-02-29 12:00:00.5000000",
                    "2024-02-29 12:00:00.5",
                )
                .null(),
            // The offset a value was written with is the one it shows. The
            // server keeps the instant in UTC, which has to stay in range.
            CorpusColumn::new("v datetimeoffset(3)")
                .shows_apart(
                    "'2024-03-10 02:30:00 -08:00'",
                    "2024-03-10 02:30:00.000-08:00",
                    "2024-03-10 02:30:00-08:00",
                )
                .shows_apart(
                    "'0001-01-01 00:00:00 -14:00'",
                    "0001-01-01 00:00:00.000-14:00",
                    "0001-01-01 00:00:00-14:00",
                )
                .shows("'9999-12-31 23:59:59.999 +14:00'", "9999-12-31 23:59:59.999+14:00"),
            CorpusColumn::new("v datetime")
                .shows_apart(
                    "'1753-01-01 00:00:00'",
                    "1753-01-01 00:00:00.000",
                    "1753-01-01 00:00:00",
                )
                .shows("'9999-12-31 23:59:59.997'", "9999-12-31 23:59:59.997")
                .shows("'2024-01-01 12:00:00.123'", "2024-01-01 12:00:00.123"),
            CorpusColumn::new("v smalldatetime").shows("'2079-06-06 23:59:00'", "2079-06-06 23:59:00"),
            CorpusColumn::new("v date")
                .shows("'0001-01-01'", "0001-01-01")
                .shows("'9999-12-31'", "9999-12-31"),
            CorpusColumn::new("v time(7)")
                .shows("'23:59:59.9999999'", "23:59:59.9999999")
                .shows_apart("'00:00:00'", "00:00:00.0000000", "00:00:00"),
            CorpusColumn::new("v decimal(38, 38)").shows(
                "0.99999999999999999999999999999999999999",
                "0.99999999999999999999999999999999999999",
            ),
            CorpusColumn::new("v decimal(38, 0)")
                .shows(
                    "99999999999999999999999999999999999999",
                    "99999999999999999999999999999999999999",
                )
                .shows(
                    "-99999999999999999999999999999999999999",
                    "-99999999999999999999999999999999999999",
                ),
            CorpusColumn::new("v decimal(10, 4)")
                .shows("-1.5", "-1.5000")
                .shows("0", "0.0000")
                .null(),
            // A table tab reads MONEY cast to a decimal. tiberius hands an
            // editor run a float, exact only to about 5.5 * 10^11, past
            // which the cell says it cannot read the value.
            CorpusColumn::new("v money")
                .shows("-12.34", "-12.3400")
                .shows("123456789.1234", "123456789.1234")
                .shows_apart("922337203685477.5807", "922337203685477.5807", "<unreadable money>")
                .shows_apart("-922337203685477.5808", "-922337203685477.5808", "<unreadable money>"),
            CorpusColumn::new("v smallmoney").shows("-214748.3648", "-214748.3648"),
            // SQL Server keeps the first three groups little-endian, so a
            // reader that takes the bytes in order scrambles them.
            CorpusColumn::new("v uniqueidentifier")
                .shows(
                    "'6F9619FF-8B86-D011-B42D-00C04FC964FF'",
                    "6f9619ff-8b86-d011-b42d-00c04fc964ff",
                )
                .null(),
            CorpusColumn::new("v nvarchar(100)")
                .shows("N'naïve café'", "naïve café")
                .shows("N'日本語のテキスト'", "日本語のテキスト")
                .shows("N'🦀 emoji 👩‍💻'", "🦀 emoji 👩‍💻")
                .shows("N''", "")
                .shows("N'it''s'", "it's")
                .null(),
            CorpusColumn::new("v varchar(50) COLLATE Latin1_General_CI_AS").shows("'café'", "café"),
            CorpusColumn::new("v nchar(5)").shows("N'ab'", "ab   "),
            CorpusColumn::new("v nvarchar(max)").shows("N'line' + NCHAR(10) + N'break'", "line\nbreak"),
            CorpusColumn::new("v varbinary(max)")
                .shows("0xDEADBEEF", "0xdeadbeef")
                .shows("0x", "0x"),
            CorpusColumn::new("v binary(4)").shows("0x01", "0x01000000"),
            CorpusColumn::new("v bit").shows("1", "true").shows("0", "false").null(),
            CorpusColumn::new("v tinyint").shows("255", "255"),
            CorpusColumn::new("v bigint").shows("-9223372036854775808", "-9223372036854775808"),
            CorpusColumn::new("v real").shows("1.5", "1.5").shows("-0.1", "-0.1"),
            CorpusColumn::new("v float")
                .shows("0.1", "0.1")
                .shows("-2.5e-5", "-0.000025"),
            CorpusColumn::new("v xml").shows("'<a>1</a>'", "<a>1</a>"),
        ]
    }
}

mod suite {
    use crate::conformance_engine::MssqlEngine;

    tablepro_test_support::value_corpus_suite! {
        engine: MssqlEngine,
        docker: true,
    }
}
