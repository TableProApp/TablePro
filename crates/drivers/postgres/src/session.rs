use async_trait::async_trait;
use sqlx::pool::PoolConnection;
use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
use sqlx::{Pool, Postgres};
use tablepro_core::{
    DriverError, MAX_QUERY_CURSOR_PAGE_ROWS, OperationControl, QueryCursorId, QueryCursorPage, QueryResult, Value,
    check_pre_dispatch,
};

use crate::{CONTROL_SETUP_TIMEOUT, controlled_execute, controlled_query, map_sqlx_error};

struct ActiveCursor {
    id: QueryCursorId,
    columns: Vec<tablepro_core::ColumnInfo>,
    failed: bool,
}

pub(crate) struct PgSession {
    connection: Option<PoolConnection<Postgres>>,
    pool: Pool<Postgres>,
    active_cursor: Option<ActiveCursor>,
}

pub(crate) async fn open(options: &PgConnectOptions) -> Result<Box<dyn tablepro_core::Session>, DriverError> {
    let pool = PgPoolOptions::new()
        .max_connections(1)
        .acquire_timeout(CONTROL_SETUP_TIMEOUT)
        .connect_lazy_with(options.clone());
    let mut connection = tokio::time::timeout(CONTROL_SETUP_TIMEOUT, pool.acquire())
        .await
        .map_err(|_| DriverError::TimedOut)?
        .map_err(map_sqlx_error)?;
    connection.close_on_drop();
    Ok(Box::new(PgSession {
        connection: Some(connection),
        pool,
        active_cursor: None,
    }))
}

#[async_trait]
impl tablepro_core::Session for PgSession {
    async fn query_params_controlled(
        &mut self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        if self.active_cursor.as_ref().is_some_and(|cursor| cursor.failed) {
            self.active_cursor = None;
        }
        if self.active_cursor.is_some() {
            return Err(DriverError::Unsupported(
                "query while a forward-only cursor is active".into(),
            ));
        }
        self.run_query_controlled(sql, params, control).await
    }

    async fn lexical_settings_controlled(
        &mut self,
        _control: &OperationControl,
    ) -> Result<Option<tablepro_core::sql_syntax::script::LexicalSettings>, DriverError> {
        let connection = self
            .connection
            .as_ref()
            .ok_or_else(|| DriverError::Internal("the session's connection was lost".into()))?;
        crate::reported_lexical_settings(connection).map(Some)
    }

    async fn open_query_cursor_controlled(
        &mut self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryCursorId, DriverError> {
        if self.active_cursor.is_some() {
            return Err(DriverError::Unsupported(
                "only one forward-only cursor is supported per session".into(),
            ));
        }
        check_pre_dispatch(control)?;
        let statement = format!("{CURSOR_PREFIX}{sql}");
        let connection = self
            .connection
            .take()
            .ok_or_else(|| DriverError::Internal("the session's connection was lost".into()))?;
        let (connection, result) = controlled_execute(connection, &statement, params, false, control).await;
        self.connection = connection;
        if let Err(error) = result {
            if !matches!(error, DriverError::Query { .. }) {
                self.retire_cursor_session();
            }
            return Err(position_in_cursor_query(error));
        }
        let id = QueryCursorId::new();
        self.active_cursor = Some(ActiveCursor {
            id,
            columns: Vec::new(),
            failed: false,
        });
        Ok(id)
    }

    async fn fetch_query_cursor_page_controlled(
        &mut self,
        cursor_id: QueryCursorId,
        control: &OperationControl,
    ) -> Result<QueryCursorPage, DriverError> {
        self.active_cursor
            .as_ref()
            .filter(|cursor| cursor.id == cursor_id)
            .ok_or_else(|| DriverError::Unsupported("forward-only cursor is not active in this session".into()))?;
        check_pre_dispatch(control)?;
        let statement = format!("FETCH FORWARD {MAX_QUERY_CURSOR_PAGE_ROWS} FROM bookie_cursor");
        let result = self.run_cursor_query_controlled(&statement, control).await;
        let mut page = match result {
            Ok(page) => page,
            Err(error @ DriverError::Query { .. }) if self.connection.is_some() => {
                if let Some(cursor) = self.active_cursor.as_mut() {
                    cursor.failed = true;
                }
                return Err(error);
            }
            Err(error) => {
                self.retire_cursor_session();
                return Err(error);
            }
        };
        if page.truncated {
            self.retire_cursor_session();
            return Ok(QueryCursorPage {
                result: page,
                has_next_page: false,
            });
        }
        let cursor = self
            .active_cursor
            .as_mut()
            .ok_or_else(|| DriverError::Internal("the active PostgreSQL cursor disappeared during fetch".into()))?;
        if !page.columns.is_empty() {
            cursor.columns.clone_from(&page.columns);
        } else if !cursor.columns.is_empty() {
            page.columns.clone_from(&cursor.columns);
        }
        let has_next_page = page.rows.len() == MAX_QUERY_CURSOR_PAGE_ROWS;
        Ok(QueryCursorPage {
            result: QueryResult {
                columns: page.columns,
                rows: page.rows,
                truncated: false,
            },
            has_next_page,
        })
    }

    async fn close_query_cursor_controlled(
        &mut self,
        cursor_id: QueryCursorId,
        control: &OperationControl,
    ) -> Result<(), DriverError> {
        let Some(cursor) = self.active_cursor.as_ref().filter(|cursor| cursor.id == cursor_id) else {
            return Err(DriverError::Unsupported(
                "forward-only cursor is not active in this session".into(),
            ));
        };
        if cursor.failed {
            self.active_cursor = None;
            return Ok(());
        }
        check_pre_dispatch(control)?;
        let connection = self
            .connection
            .take()
            .ok_or_else(|| DriverError::Internal("the session's connection was lost".into()))?;
        let (connection, result) = controlled_execute(connection, "CLOSE bookie_cursor", &[], false, control).await;
        self.connection = connection;
        if result.is_err() {
            self.retire_cursor_session();
        } else {
            self.active_cursor = None;
        }
        result.map(|_| ())
    }

    fn is_usable(&self) -> bool {
        self.connection.is_some()
    }

    async fn close(mut self: Box<Self>) -> Result<(), DriverError> {
        if let Some(connection) = self.connection.take() {
            let _ = connection.close().await;
        }
        self.pool.close().await;
        Ok(())
    }
}

impl PgSession {
    async fn run_query_controlled(
        &mut self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        check_pre_dispatch(control)?;
        let connection = self
            .connection
            .take()
            .ok_or_else(|| DriverError::Internal("the session's connection was lost".into()))?;
        let (connection, result) = controlled_query(connection, sql, params, true, control).await;
        self.connection = connection;
        if matches!(result, Err(DriverError::Disconnected)) {
            // A lost backend also loses session-local state. Do not let the
            // single-slot pool silently replace it and masquerade as the same
            // session on the next statement.
            self.connection = None;
        }
        result
    }

    async fn run_cursor_query_controlled(
        &mut self,
        sql: &str,
        control: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        let connection = self
            .connection
            .take()
            .ok_or_else(|| DriverError::Internal("the session's connection was lost".into()))?;
        let (connection, result) = controlled_query(connection, sql, &[], false, control).await;
        self.connection = connection;
        result
    }

    fn retire_cursor_session(&mut self) {
        self.connection = None;
        self.active_cursor = None;
    }
}

const CURSOR_PREFIX: &str = "DECLARE bookie_cursor NO SCROLL CURSOR FOR ";

fn position_in_cursor_query(error: DriverError) -> DriverError {
    let DriverError::Query {
        message,
        sqlstate,
        position,
    } = error
    else {
        return error;
    };
    let prefix = CURSOR_PREFIX.chars().count();
    DriverError::Query {
        message,
        sqlstate,
        position: position
            .and_then(|position| position.checked_sub(prefix))
            .filter(|position| *position > 0),
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::DriverError;

    use super::{CURSOR_PREFIX, position_in_cursor_query};

    fn query_error(position: Option<usize>) -> DriverError {
        DriverError::Query {
            message: "column \"nope\" does not exist".into(),
            sqlstate: Some("42703".into()),
            position,
        }
    }

    #[test]
    fn an_error_position_points_into_the_users_statement() {
        let prefix = CURSOR_PREFIX.chars().count();
        let shifted = position_in_cursor_query(query_error(Some(prefix + 8)));
        assert!(
            matches!(shifted, DriverError::Query { position: Some(8), .. }),
            "{shifted:?}"
        );
    }

    #[test]
    fn a_position_inside_the_cursor_prefix_is_dropped() {
        let dropped = position_in_cursor_query(query_error(Some(3)));
        assert!(
            matches!(dropped, DriverError::Query { position: None, .. }),
            "{dropped:?}"
        );
        let other = position_in_cursor_query(DriverError::Disconnected);
        assert!(matches!(other, DriverError::Disconnected));
    }
}
