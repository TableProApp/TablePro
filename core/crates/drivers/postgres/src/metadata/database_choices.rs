use tablepro_core::DriverError;
use tablepro_core::ddl::{DatabaseChoices, DatabaseDefaults};
use tokio_postgres::{Client, Row};

use super::{decode_error, text_rows};

/// The `pg_` roles are the server's own and are given nothing a user
/// makes.
pub(super) const OWNERS_SQL: &str = "\
SELECT r.rolname::text
FROM pg_catalog.pg_roles r
WHERE NOT pg_catalog.starts_with(r.rolname, 'pg_')
ORDER BY 1";

pub(super) const TEMPLATES_SQL: &str = "\
SELECT d.datname::text
FROM pg_catalog.pg_database d
WHERE d.datistemplate
ORDER BY 1";

/// The operating system's locales as initdb found them. An ICU
/// collation's name is no locale the libc provider takes.
pub(super) const LOCALES_SQL: &str = "\
SELECT DISTINCT c.collcollate::text
FROM pg_catalog.pg_collation c
WHERE c.collprovider = 'c' AND c.collcollate IS NOT NULL AND c.collcollate <> ''
ORDER BY 1";

/// A database left without an owner belongs to its creator, and one
/// left without an encoding or locale takes template1's.
pub(super) const DEFAULTS_SQL: &str = "\
SELECT CURRENT_USER::text,
       (SELECT pg_catalog.pg_encoding_to_char(d.encoding)::text
        FROM pg_catalog.pg_database d WHERE d.datname = 'template1'),
       (SELECT d.datcollate::text FROM pg_catalog.pg_database d WHERE d.datname = 'template1')";

/// Every encoding the character set table marks as a server encoding
/// (https://www.postgresql.org/docs/current/multibyte.html, the
/// "Server?" column). The client-only ones, such as SJIS and BIG5, are
/// refused by CREATE DATABASE.
const SERVER_ENCODINGS: [&str; 35] = [
    "EUC_CN",
    "EUC_JP",
    "EUC_JIS_2004",
    "EUC_KR",
    "EUC_TW",
    "ISO_8859_5",
    "ISO_8859_6",
    "ISO_8859_7",
    "ISO_8859_8",
    "KOI8R",
    "KOI8U",
    "LATIN1",
    "LATIN2",
    "LATIN3",
    "LATIN4",
    "LATIN5",
    "LATIN6",
    "LATIN7",
    "LATIN8",
    "LATIN9",
    "LATIN10",
    "MULE_INTERNAL",
    "SQL_ASCII",
    "UTF8",
    "WIN866",
    "WIN874",
    "WIN1250",
    "WIN1251",
    "WIN1252",
    "WIN1253",
    "WIN1254",
    "WIN1255",
    "WIN1256",
    "WIN1257",
    "WIN1258",
];

pub(crate) async fn database_choices(client: &Client) -> Result<DatabaseChoices, DriverError> {
    // Every query is sent before the first answer is awaited, so all of
    // them run inside the flight's transaction, ahead of its COMMIT.
    let (owners, templates, locales, defaults) = futures_util::try_join!(
        text_rows(client, OWNERS_SQL, &[]),
        text_rows(client, TEMPLATES_SQL, &[]),
        text_rows(client, LOCALES_SQL, &[]),
        text_rows(client, DEFAULTS_SQL, &[]),
    )?;
    let defaults = defaults
        .first()
        .ok_or_else(|| DriverError::Protocol("the database defaults read returned no row".to_owned()))?;
    let field = decode_error("pg_database");
    Ok(DatabaseChoices {
        owners: names(&owners, "pg_roles")?,
        templates: names(&templates, "pg_database")?,
        encodings: SERVER_ENCODINGS.iter().map(|&encoding| encoding.to_owned()).collect(),
        locales: names(&locales, "pg_collation")?,
        defaults: DatabaseDefaults {
            owner: defaults.try_get(0).map_err(&field)?,
            encoding: defaults.try_get(1).map_err(&field)?,
            locale: defaults.try_get(2).map_err(&field)?,
            ..DatabaseDefaults::default()
        },
        ..DatabaseChoices::default()
    })
}

fn names(rows: &[Row], table: &'static str) -> Result<Vec<String>, DriverError> {
    let field = decode_error(table);
    rows.iter().map(|row| row.try_get(0).map_err(&field)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_encodings_offered_are_the_server_encodings_once_each() {
        let mut sorted = SERVER_ENCODINGS.to_vec();
        sorted.sort_unstable();
        sorted.dedup();

        assert_eq!(sorted.len(), SERVER_ENCODINGS.len());
        assert!(SERVER_ENCODINGS.contains(&"UTF8") && SERVER_ENCODINGS.contains(&"SQL_ASCII"));
        for client_only in ["BIG5", "GB18030", "GBK", "JOHAB", "SJIS", "SHIFT_JIS_2004", "UHC"] {
            assert!(!SERVER_ENCODINGS.contains(&client_only), "{client_only}");
        }
    }
}
