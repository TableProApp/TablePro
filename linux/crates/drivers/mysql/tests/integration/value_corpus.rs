//! The value corpus on MySQL and MariaDB: the types a real schema holds,
//! at their extremes, and the text the grid shows for each.
//!
//! sqlx gives a result column no fractional digits and no BIT length,
//! so an editor run shows the fraction a value has and a BIT in the
//! whole bytes it arrived in. A browse page takes both from the
//! catalogue.

use tablepro_test_fixtures::MysqlFlavour;
use tablepro_test_support::conformance::{CorpusColumn, ValueCorpusEngine};

use crate::conformance_engine::{MySqlEngine, Server};

impl<S: Server> ValueCorpusEngine for MySqlEngine<S> {
    fn value_corpus(&self) -> Vec<CorpusColumn> {
        let flavoured = match S::FLAVOUR {
            // MySQL keeps JSON in a binary form of its own, so it prints
            // the document again, keys sorted and numbers normalised, as
            // the mysql client shows it.
            MysqlFlavour::Mysql => vec![
                CorpusColumn::new("v JSON")
                    .shows(
                        r#"'{"b": 1, "a": [1, 2.50, "x"], "ü": null}'"#,
                        r#"{"a": [1, 2.5, "x"], "b": 1, "ü": null}"#,
                    )
                    .shows("'[]'", "[]")
                    .null(),
                CorpusColumn::new("v BINARY(16)").shows(
                    "UUID_TO_BIN('123e4567-e89b-12d3-a456-426614174000')",
                    "0x123e4567e89b12d3a456426614174000",
                ),
            ],
            // MariaDB's JSON is LONGTEXT with a check, kept as written.
            MysqlFlavour::Mariadb => vec![
                CorpusColumn::new("v JSON")
                    .shows(r#"'{"b": 1, "a": [1, 2.50, "x"]}'"#, r#"{"b": 1, "a": [1, 2.50, "x"]}"#)
                    .null(),
                CorpusColumn::new("v UUID")
                    .shows(
                        "'123e4567-e89b-12d3-a456-426614174000'",
                        "123e4567-e89b-12d3-a456-426614174000",
                    )
                    .null(),
                CorpusColumn::new("v INET6").shows("'::ffff:192.0.2.1'", "::ffff:192.0.2.1"),
            ],
        };
        [common(), flavoured].concat()
    }
}

fn common() -> Vec<CorpusColumn> {
    vec![
        CorpusColumn::new("v DATETIME(6)")
            .shows_apart(
                "'1000-01-01 00:00:00'",
                "1000-01-01 00:00:00.000000",
                "1000-01-01 00:00:00",
            )
            .shows("'9999-12-31 23:59:59.999999'", "9999-12-31 23:59:59.999999")
            .shows_apart(
                "'2024-02-29 12:00:00.5'",
                "2024-02-29 12:00:00.500000",
                "2024-02-29 12:00:00.5",
            )
            .null(),
        CorpusColumn::new("v DATETIME").shows("'2024-03-10 02:30:00'", "2024-03-10 02:30:00"),
        // Browse pins its session to UTC and reads an instant; the
        // editor reads the wall time in the server's zone, UTC here.
        CorpusColumn::new("v TIMESTAMP(3) NULL")
            .shows_apart(
                "'1970-01-01 00:00:01'",
                "1970-01-01 00:00:01.000+00:00",
                "1970-01-01 00:00:01",
            )
            .shows_apart(
                "'2038-01-19 03:14:07.999'",
                "2038-01-19 03:14:07.999+00:00",
                "2038-01-19 03:14:07.999",
            )
            .null(),
        CorpusColumn::new("v DATE")
            .shows("'1000-01-01'", "1000-01-01")
            .shows("'9999-12-31'", "9999-12-31")
            .shows("'2024-02-29'", "2024-02-29"),
        CorpusColumn::new("v TIME(6)")
            .shows_apart("'-838:59:59'", "-838:59:59.000000", "-838:59:59")
            .shows_apart("'838:59:59'", "838:59:59.000000", "838:59:59")
            .shows("'00:00:00.000001'", "00:00:00.000001"),
        CorpusColumn::new("v YEAR").shows("1901", "1901").shows("2155", "2155"),
        CorpusColumn::new("v DECIMAL(65, 30)")
            .shows(
                "12345678901234567890123456789012345.123456789012345678901234567890",
                "12345678901234567890123456789012345.123456789012345678901234567890",
            )
            .shows("-0.000000000000000000000000000001", "-0.000000000000000000000000000001")
            .shows("0", "0.000000000000000000000000000000"),
        CorpusColumn::new("v DECIMAL(10, 2)")
            .shows("-12345678.9", "-12345678.90")
            .shows("0.5", "0.50")
            .null(),
        CorpusColumn::new("v BIGINT UNSIGNED").shows("18446744073709551615", "18446744073709551615"),
        CorpusColumn::new("v BIGINT").shows("-9223372036854775808", "-9223372036854775808"),
        CorpusColumn::new("v TINYINT UNSIGNED").shows("255", "255"),
        CorpusColumn::new("v FLOAT").shows("1.5", "1.5").shows("-0.25", "-0.25"),
        CorpusColumn::new("v DOUBLE")
            .shows("0.1", "0.1")
            .shows("-2.5e-5", "-0.000025"),
        CorpusColumn::new("v VARCHAR(100)")
            .shows("'naïve café'", "naïve café")
            .shows("'日本語のテキスト'", "日本語のテキスト")
            .shows("'🦀 emoji 👩‍💻'", "🦀 emoji 👩‍💻")
            .shows("''", "")
            .shows("'it''s'", "it's")
            .shows("'back\\\\slash'", "back\\slash")
            .null(),
        CorpusColumn::new("v VARCHAR(20) CHARACTER SET latin1").shows("'café'", "café"),
        CorpusColumn::new("v CHAR(5)").shows("'ab'", "ab"),
        CorpusColumn::new("v TEXT").shows("'line\\nbreak'", "line\nbreak"),
        CorpusColumn::new("v VARBINARY(8)")
            .shows("X'DEADBEEF'", "0xdeadbeef")
            .shows("X''", "0x"),
        CorpusColumn::new("v BINARY(4)").shows("X'01'", "0x01000000"),
        CorpusColumn::new("v BLOB").shows("X'00FF'", "0x00ff"),
        CorpusColumn::new("v BIT(10)").shows_apart("b'1010101010'", "1010101010", "0000001010101010"),
        CorpusColumn::new("v BIT(1)")
            .shows_apart("b'1'", "1", "00000001")
            .shows_apart("b'0'", "0", "00000000"),
        CorpusColumn::new("v ENUM('a', 'b c')").shows("'b c'", "b c").null(),
        CorpusColumn::new("v SET('x', 'y', 'z')").shows("'x,z'", "x,z"),
    ]
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
