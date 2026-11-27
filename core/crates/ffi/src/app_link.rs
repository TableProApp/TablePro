use tablepro_core::app_link::{self, AppLink};

use crate::error::CoreError;

// A tablepro:// link other than a share link, which share_token_from_link reads.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum AppLinkInfo {
    OpenConnection {
        connection_id: String,
    },
    OpenTable {
        connection_id: String,
        database: Option<String>,
        schema: Option<String>,
        table: String,
    },
    OpenQuery {
        connection_id: String,
        sql: String,
    },
    OpenSettings {
        pane: Option<String>,
    },
    StartMcpServer,
}

#[uniffi::export]
pub fn parse_app_link(link: String) -> Result<AppLinkInfo, CoreError> {
    let parsed = app_link::parse(&link).map_err(|error| CoreError::failed(error.code(), error.to_string()))?;
    let id = |connection: uuid::Uuid| connection.hyphenated().to_string();
    Ok(match parsed {
        AppLink::OpenConnection { connection } => AppLinkInfo::OpenConnection {
            connection_id: id(connection),
        },
        AppLink::OpenTable {
            connection,
            database,
            schema,
            table,
        } => AppLinkInfo::OpenTable {
            connection_id: id(connection),
            database,
            schema,
            table,
        },
        AppLink::OpenQuery { connection, sql } => AppLinkInfo::OpenQuery {
            connection_id: id(connection),
            sql,
        },
        AppLink::OpenSettings { pane } => AppLinkInfo::OpenSettings { pane },
        AppLink::StartMcpServer => AppLinkInfo::StartMcpServer,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_table_link_names_its_connection_in_lower_case() {
        let link = "tablepro://connect/9F1F0C3E-2E3D-4B14-9C3A-1D2F4AD1F6F1/database/app/table/users";

        assert_eq!(
            parse_app_link(link.to_owned()).ok(),
            Some(AppLinkInfo::OpenTable {
                connection_id: "9f1f0c3e-2e3d-4b14-9c3a-1d2f4ad1f6f1".to_owned(),
                database: Some("app".to_owned()),
                schema: None,
                table: "users".to_owned(),
            })
        );
    }

    #[test]
    fn a_start_mcp_link_starts_the_server() {
        assert_eq!(
            parse_app_link("tablepro://integrations/start-mcp".to_owned()).ok(),
            Some(AppLinkInfo::StartMcpServer)
        );
    }

    #[test]
    fn a_link_it_cannot_read_fails_with_the_core_s_code() {
        let failure = parse_app_link("tablepro://connect/nope".to_owned()).err();

        assert_eq!(failure.as_ref().map(CoreError::code), Some("link.invalid_id"));
    }
}
