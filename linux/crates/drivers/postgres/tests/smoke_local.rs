//! Local smoke against an already-running Postgres (no Docker required).
//!
//! Env: SMOKE_PG_HOST, SMOKE_PG_PORT, SMOKE_PG_USER, SMOKE_PG_PASS, SMOKE_PG_DB
//! Defaults match `scripts/smoke-postgres.sh` / the plan's podman one-liner.

use drivers_postgres::PgDriver;
use tablepro_core::{ConnectOptions, Connection as _, DatabaseDriver, Value};

fn opts_from_env() -> ConnectOptions {
    ConnectOptions {
        host: std::env::var("SMOKE_PG_HOST").unwrap_or_else(|_| "127.0.0.1".into()),
        port: std::env::var("SMOKE_PG_PORT")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(54329),
        database: std::env::var("SMOKE_PG_DB").unwrap_or_else(|_| "tablepro".into()),
        username: std::env::var("SMOKE_PG_USER").unwrap_or_else(|_| "tablepro".into()),
        password: secrecy::SecretString::new(
            std::env::var("SMOKE_PG_PASS")
                .unwrap_or_else(|_| "tablepro".into())
                .into(),
        ),
        use_tls: false,
    }
}

#[tokio::test]
async fn connect_browse_and_edit_cell() {
    let opts = opts_from_env();
    let conn = PgDriver
        .connect(opts)
        .await
        .expect("connect to smoke postgres");

    conn.execute(
        "CREATE TABLE IF NOT EXISTS smoke_items (
            id SERIAL PRIMARY KEY,
            name TEXT NOT NULL,
            qty INT DEFAULT 0
        )",
    )
    .await
    .expect("create table");

    conn.execute("DELETE FROM smoke_items").await.expect("clear");
    conn.execute("INSERT INTO smoke_items (name, qty) VALUES ('alpha', 1), ('beta', 2)")
        .await
        .expect("seed");

    let tables = conn.list_tables().await.expect("list_tables");
    assert!(
        tables.iter().any(|t| t.name == "smoke_items"),
        "smoke_items missing from {:?}",
        tables.iter().map(|t| &t.name).collect::<Vec<_>>()
    );

    let cols = conn
        .fetch_columns(Some("public"), "smoke_items")
        .await
        .expect("fetch_columns");
    assert!(cols.iter().any(|c| c.name == "id" && c.primary_key));

    let before = conn
        .fetch_rows(Some("public"), "smoke_items", 0, 100)
        .await
        .expect("fetch_rows");
    assert_eq!(before.rows.len(), 2);

    let updated = conn
        .execute_params(
            "UPDATE smoke_items SET qty = $1 WHERE name = $2",
            &[Value::Int(99), Value::Text("alpha".into())],
        )
        .await
        .expect("edit cell");
    assert_eq!(updated.rows_affected, 1);

    let after = conn
        .query("SELECT qty FROM smoke_items WHERE name = 'alpha'")
        .await
        .expect("verify");
    assert_eq!(after.rows.len(), 1);
    assert_eq!(after.rows[0][0], Value::Int(99));

    conn.close().await.expect("close");
}
