// The tools refuse a field they do not know, so an option the user left out is left out here too.

use serde::Serialize;

use crate::output::ExportFormat;

#[derive(Serialize)]
pub(crate) struct NoArguments {}

#[derive(Serialize)]
pub(crate) struct ConnectionArguments<'a> {
    pub(crate) connection_id: &'a str,
}

#[derive(Serialize)]
pub(crate) struct ScopeArguments<'a> {
    pub(crate) connection_id: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) database: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) schema: Option<&'a str>,
}

#[derive(Serialize)]
pub(crate) struct TableArguments<'a> {
    pub(crate) connection_id: &'a str,
    pub(crate) table: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) database: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) schema: Option<&'a str>,
}

#[derive(Serialize)]
pub(crate) struct QueryArguments<'a> {
    pub(crate) connection_id: &'a str,
    pub(crate) query: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) database: Option<&'a str>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub(crate) read_only: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) max_rows: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) timeout_seconds: Option<u32>,
}

#[derive(Serialize)]
pub(crate) struct ExportArguments<'a> {
    pub(crate) connection_id: &'a str,
    pub(crate) format: ExportFormat,
    pub(crate) tables: &'a [String],
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) database: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) schema: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) max_rows: Option<u32>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_option_left_out_is_not_sent() {
        let bare = QueryArguments {
            connection_id: "c",
            query: "SELECT 1",
            database: None,
            read_only: false,
            max_rows: None,
            timeout_seconds: None,
        };
        let full = QueryArguments {
            database: Some("sales"),
            read_only: true,
            max_rows: Some(5),
            timeout_seconds: Some(9),
            ..bare
        };

        assert_eq!(
            serde_json::to_string(&bare).expect("JSON"),
            r#"{"connection_id":"c","query":"SELECT 1"}"#
        );
        assert_eq!(
            serde_json::to_string(&full).expect("JSON"),
            r#"{"connection_id":"c","query":"SELECT 1","database":"sales","read_only":true,"max_rows":5,"timeout_seconds":9}"#
        );
    }

    #[test]
    fn an_export_names_its_format_as_the_tool_does() {
        let tables = vec!["orders".to_owned()];
        let arguments = ExportArguments {
            connection_id: "c",
            format: ExportFormat::Sql,
            tables: &tables,
            database: None,
            schema: Some("public"),
            max_rows: None,
        };

        assert_eq!(
            serde_json::to_string(&arguments).expect("JSON"),
            r#"{"connection_id":"c","format":"sql","tables":["orders"],"schema":"public"}"#
        );
    }
}
