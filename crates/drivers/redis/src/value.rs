use super::*;
use redis::AsyncCommands;

pub(super) struct RedisValueQuery {
    database: u8,
    key: Vec<u8>,
}

pub(super) async fn browse_connection(
    connection: &RedisConnection,
    database: u8,
) -> Result<redis::aio::MultiplexedConnection, DriverError> {
    let mut conn = tokio::time::timeout(
        CONNECT_TIMEOUT,
        connection.browse_client.get_multiplexed_async_connection(),
    )
    .await
    .map_err(|_| DriverError::TimedOut)?
    .map_err(map_redis_error)?;
    redis::cmd("SELECT")
        .arg(database)
        .query_async::<()>(&mut conn)
        .await
        .map_err(map_redis_error)?;
    Ok(conn)
}

pub(super) fn parse_value_query(sql: &str, params: &[Value]) -> Option<RedisValueQuery> {
    let rest = sql.trim().strip_prefix("SELECT \"Value\" FROM \"db")?;
    let (database, suffix) = rest.split_once("\" WHERE \"Key\" = ?")?;
    if !suffix.is_empty()
        || params.len() != 1
        || database.is_empty()
        || !database.bytes().all(|byte| byte.is_ascii_digit())
    {
        return None;
    }
    let database = database.parse().ok()?;
    let key = match &params[0] {
        Value::Text(text) => text.as_bytes().to_vec(),
        Value::Bytes(bytes) => bytes.clone(),
        _ => return None,
    };
    Some(RedisValueQuery { database, key })
}

pub(super) async fn fetch_string_value(
    connection: &RedisConnection,
    query: RedisValueQuery,
) -> Result<QueryResult, DriverError> {
    let mut conn = browse_connection(connection, query.database).await?;
    let key_type: String = conn.key_type(&query.key).await.map_err(map_redis_error)?;
    if key_type == "none" {
        return Ok(QueryResult {
            columns: vec![text_col("Value")],
            rows: Vec::new(),
            truncated: false,
        });
    }
    if key_type != "string" {
        return Err(DriverError::Unsupported(
            "Redis full-value refetch only supports string keys".into(),
        ));
    }
    let Some(bytes) = conn
        .get::<_, Option<Vec<u8>>>(&query.key)
        .await
        .map_err(map_redis_error)?
    else {
        return Ok(QueryResult {
            columns: vec![text_col("Value")],
            rows: Vec::new(),
            truncated: false,
        });
    };
    if bytes.len() > MAX_QUERY_RESULT_BYTES {
        return Err(DriverError::Unsupported(
            "Redis value exceeds the 64 MiB query limit".into(),
        ));
    }
    Ok(QueryResult {
        columns: vec![text_col("Value")],
        rows: vec![vec![bytes_to_value(bytes)]],
        truncated: false,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn value_queries_accept_only_bound_text_or_binary_keys_for_known_databases() {
        let key = Value::Bytes(vec![0xff, b'?', b'\n']);
        let parsed = parse_value_query(
            "SELECT \"Value\" FROM \"db12\" WHERE \"Key\" = ?",
            std::slice::from_ref(&key),
        )
        .expect("valid value query");
        assert_eq!(parsed.database, 12);
        assert_eq!(parsed.key, vec![0xff, b'?', b'\n']);

        for (sql, params) in [
            (
                "SELECT \"Value\" FROM \"db12\" WHERE \"Key\" = ? OR 1=1",
                vec![Value::Text("x".into())],
            ),
            (
                "SELECT \"Type\" FROM \"db12\" WHERE \"Key\" = ?",
                vec![Value::Text("x".into())],
            ),
            (
                "SELECT \"Value\" FROM \"db256\" WHERE \"Key\" = ?",
                vec![Value::Text("x".into())],
            ),
            ("SELECT \"Value\" FROM \"db12\" WHERE \"Key\" = ?", vec![Value::Int(1)]),
        ] {
            assert!(parse_value_query(sql, &params).is_none(), "accepted {sql}");
        }
    }
}
