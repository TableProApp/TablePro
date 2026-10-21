#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use crate::start_pg;
use secrecy::ExposeSecret;
use sqlx::Row;
use sqlx::postgres::PgConnectOptions;

#[path = "../../src/pool.rs"]
mod pool;

#[tokio::test]
#[ignore = "requires docker"]
async fn settings_and_temp_tables_do_not_survive_on_a_pooled_connection() {
    let (_container, opts) = start_pg().await;
    let options = PgConnectOptions::new()
        .host(&opts.host)
        .port(opts.port)
        .username(&opts.username)
        .password(opts.password.expose_secret())
        .database(&opts.database)
        .statement_cache_capacity(0);
    let pool = pool::options().max_connections(1).connect_with(options).await.unwrap();
    let mut connection = pool.acquire().await.unwrap();
    let backend: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
        .fetch_one(&mut *connection)
        .await
        .unwrap();
    let default_path: String = sqlx::query_scalar("SHOW search_path")
        .fetch_one(&mut *connection)
        .await
        .unwrap();
    for _ in 0..8 {
        sqlx::raw_sql("SET search_path TO pg_catalog; CREATE TEMP TABLE leaked (id int)")
            .execute(&mut *connection)
            .await
            .unwrap();
        let dirty = sqlx::query("SELECT current_setting('search_path'), to_regclass('pg_temp.leaked')::text")
            .fetch_one(&mut *connection)
            .await
            .unwrap();
        assert_eq!(dirty.get::<String, _>(0), "pg_catalog");
        assert!(dirty.get::<Option<String>, _>(1).is_some());
        drop(connection);
        connection = pool.acquire().await.unwrap();
        let clean =
            sqlx::query("SELECT pg_backend_pid(), current_setting('search_path'), to_regclass('pg_temp.leaked')::text")
                .fetch_one(&mut *connection)
                .await
                .unwrap();
        assert_eq!(clean.get::<i32, _>(0), backend);
        assert_eq!(clean.get::<String, _>(1), default_path);
        assert_eq!(clean.get::<Option<String>, _>(2), None);
    }
    connection.close().await.unwrap();
    pool.close().await;
}
