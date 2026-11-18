// tablepro:// links that open something in the app, read as macOS reads them; share links are tablepro-account's.

use thiserror::Error;
use url::Url;
use uuid::Uuid;

pub const SCHEME: &str = "tablepro";

// In UTF-16 units, as macOS counts it.
pub const SQL_LIMIT: usize = 51_200;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AppLink {
    OpenConnection {
        connection: Uuid,
    },
    // No database means the connection's own, no schema its current one.
    OpenTable {
        connection: Uuid,
        database: Option<String>,
        schema: Option<String>,
        table: String,
    },
    // The SQL goes into a new query tab and never runs from the link.
    OpenQuery {
        connection: Uuid,
        sql: String,
    },
    // A pane the app does not know still opens Settings.
    OpenSettings {
        pane: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum AppLinkError {
    #[error("this is not a tablepro:// link")]
    NotALink,

    #[error("no link opens {host}")]
    UnknownHost { host: String },

    #[error("the link's path is not one the app reads")]
    MalformedPath,

    #[error("{text} is not a connection id")]
    InvalidId { text: String },

    #[error("the link carries no SQL")]
    MissingSql,

    #[error("the SQL is {length} characters, past the {SQL_LIMIT} a link carries")]
    SqlTooLong { length: usize },
}

impl AppLinkError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::NotALink => "link.invalid",
            Self::UnknownHost { .. } => "link.unknown_host",
            Self::MalformedPath => "link.malformed_path",
            Self::InvalidId { .. } => "link.invalid_id",
            Self::MissingSql => "link.missing_sql",
            Self::SqlTooLong { .. } => "link.sql_too_long",
        }
    }
}

pub fn parse(link: &str) -> Result<AppLink, AppLinkError> {
    let url = Url::parse(link.trim()).map_err(|_| AppLinkError::NotALink)?;
    if url.scheme() != SCHEME {
        return Err(AppLinkError::NotALink);
    }
    let host = url.host_str().unwrap_or_default();
    let segments = segments(&url)?;
    match host {
        "connect" => connect(&url, &segments),
        "settings" => Ok(AppLink::OpenSettings {
            pane: segments.into_iter().next(),
        }),
        _ => Err(AppLinkError::UnknownHost { host: host.to_owned() }),
    }
}

// Each segment decoded, so a table named `daily events` arrives as written.
fn segments(url: &Url) -> Result<Vec<String>, AppLinkError> {
    let Some(raw) = url.path_segments() else {
        return Ok(Vec::new());
    };
    raw.filter(|segment| !segment.is_empty())
        .map(|segment| {
            percent_encoding::percent_decode_str(segment)
                .decode_utf8()
                .map(|text| text.into_owned())
                .map_err(|_| AppLinkError::MalformedPath)
        })
        .collect()
}

fn connect(url: &Url, segments: &[String]) -> Result<AppLink, AppLinkError> {
    let (first, rest) = segments.split_first().ok_or(AppLinkError::MalformedPath)?;
    let connection = connection_id(first)?;
    let named = |text: &String| (!text.is_empty()).then(|| text.clone());
    match rest {
        [] => Ok(AppLink::OpenConnection { connection }),
        [table_word, table] if table_word == "table" => Ok(AppLink::OpenTable {
            connection,
            database: None,
            schema: None,
            table: named(table).ok_or(AppLinkError::MalformedPath)?,
        }),
        [database_word, database, table_word, table] if database_word == "database" && table_word == "table" => {
            Ok(AppLink::OpenTable {
                connection,
                database: Some(named(database).ok_or(AppLinkError::MalformedPath)?),
                schema: None,
                table: named(table).ok_or(AppLinkError::MalformedPath)?,
            })
        }
        [database_word, database, schema_word, schema, table_word, table]
            if database_word == "database" && schema_word == "schema" && table_word == "table" =>
        {
            Ok(AppLink::OpenTable {
                connection,
                database: Some(named(database).ok_or(AppLinkError::MalformedPath)?),
                schema: Some(named(schema).ok_or(AppLinkError::MalformedPath)?),
                table: named(table).ok_or(AppLinkError::MalformedPath)?,
            })
        }
        [query_word] if query_word == "query" => query(url, connection),
        _ => Err(AppLinkError::MalformedPath),
    }
}

fn decoded(text: &str) -> Option<String> {
    percent_encoding::percent_decode_str(text)
        .decode_utf8()
        .ok()
        .map(|text| text.into_owned())
}

// Hyphenated, in either case, as Swift's `UUID(uuidString:)` reads one.
fn connection_id(text: &str) -> Result<Uuid, AppLinkError> {
    (text.len() == 36)
        .then(|| Uuid::try_parse(text).ok())
        .flatten()
        .ok_or_else(|| AppLinkError::InvalidId { text: text.to_owned() })
}

// Percent-decoded only: a form's + for a space would turn `1+2` into `1 2`, which macOS's query items never do.
fn query(url: &Url, connection: Uuid) -> Result<AppLink, AppLinkError> {
    let sql = url
        .query()
        .unwrap_or_default()
        .split('&')
        .map(|pair| pair.split_once('=').unwrap_or((pair, "")))
        .find(|(name, _)| decoded(name).as_deref() == Some("sql"))
        .and_then(|(_, value)| decoded(value))
        .filter(|sql| !sql.is_empty())
        .ok_or(AppLinkError::MissingSql)?;
    let length = sql.encode_utf16().count();
    if length > SQL_LIMIT {
        return Err(AppLinkError::SqlTooLong { length });
    }
    Ok(AppLink::OpenQuery { connection, sql })
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "9f1f0c3e-2e3d-4b14-9c3a-1d2f4ad1f6f1";

    fn id() -> Uuid {
        Uuid::try_parse(ID).unwrap_or_default()
    }

    fn table(database: Option<&str>, schema: Option<&str>, table: &str) -> AppLink {
        AppLink::OpenTable {
            connection: id(),
            database: database.map(str::to_owned),
            schema: schema.map(str::to_owned),
            table: table.to_owned(),
        }
    }

    #[test]
    fn a_connect_link_opens_the_connection_its_table_or_a_query() {
        let cases = [
            (
                format!("tablepro://connect/{ID}"),
                AppLink::OpenConnection { connection: id() },
            ),
            (
                format!("tablepro://connect/{}/", ID.to_uppercase()),
                AppLink::OpenConnection { connection: id() },
            ),
            (
                format!("tablepro://connect/{ID}/table/users"),
                table(None, None, "users"),
            ),
            (
                format!("tablepro://connect/{ID}/database/analytics/table/events"),
                table(Some("analytics"), None, "events"),
            ),
            (
                format!("tablepro://connect/{ID}/database/app/schema/reporting/table/daily%20events"),
                table(Some("app"), Some("reporting"), "daily events"),
            ),
            (
                format!("tablepro://connect/{ID}/query?sql=SELECT%20*%20FROM%20users%20LIMIT%2010"),
                AppLink::OpenQuery {
                    connection: id(),
                    sql: "SELECT * FROM users LIMIT 10".to_owned(),
                },
            ),
        ];

        for (link, expected) in cases {
            assert_eq!(parse(&link), Ok(expected), "{link}");
        }
    }

    #[test]
    fn a_settings_link_names_its_pane_or_none() {
        assert_eq!(parse("tablepro://settings"), Ok(AppLink::OpenSettings { pane: None }));
        assert_eq!(
            parse("tablepro://settings/notifications/extra?x=1"),
            Ok(AppLink::OpenSettings {
                pane: Some("notifications".to_owned())
            })
        );
    }

    #[test]
    fn a_link_the_app_cannot_read_says_why() {
        let long = "x".repeat(SQL_LIMIT + 1);
        let cases = [
            ("https://connect/x".to_owned(), "link.invalid"),
            ("not a link".to_owned(), "link.invalid"),
            ("tablepro://share?token=abc".to_owned(), "link.unknown_host"),
            ("tablepro://import?name=x".to_owned(), "link.unknown_host"),
            ("tablepro://connect".to_owned(), "link.malformed_path"),
            (format!("tablepro://connect/{ID}/table"), "link.malformed_path"),
            (format!("tablepro://connect/{ID}/table/a/b"), "link.malformed_path"),
            (
                format!("tablepro://connect/{ID}/database/app/users"),
                "link.malformed_path",
            ),
            (
                format!("tablepro://connect/{ID}/schema/app/table/users"),
                "link.malformed_path",
            ),
            (format!("tablepro://connect/{ID}/table/%FF"), "link.malformed_path"),
            (
                "tablepro://connect/production/table/users".to_owned(),
                "link.invalid_id",
            ),
            (format!("tablepro://connect/{}", ID.replace('-', "")), "link.invalid_id"),
            (format!("tablepro://connect/{ID}/query"), "link.missing_sql"),
            (format!("tablepro://connect/{ID}/query?sql="), "link.missing_sql"),
            (format!("tablepro://connect/{ID}/query?sql={long}"), "link.sql_too_long"),
        ];

        for (link, code) in cases {
            assert_eq!(parse(&link).map_err(|error| error.code()), Err(code), "{link}");
        }
    }

    #[test]
    fn a_plus_in_the_sql_stays_a_plus() {
        assert_eq!(
            parse(&format!("tablepro://connect/{ID}/query?x=1&sql=SELECT%201+2%2B3&sql=ignored")),
            Ok(AppLink::OpenQuery {
                connection: id(),
                sql: "SELECT 1+2+3".to_owned(),
            })
        );
    }

    #[test]
    fn the_sql_limit_counts_utf16_units() {
        let at_limit = "é".repeat(SQL_LIMIT);
        let past = format!("{at_limit}a");

        assert!(parse(&format!("tablepro://connect/{ID}/query?sql={at_limit}")).is_ok());
        assert_eq!(
            parse(&format!("tablepro://connect/{ID}/query?sql={past}")),
            Err(AppLinkError::SqlTooLong { length: SQL_LIMIT + 1 })
        );
    }
}
