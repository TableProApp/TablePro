//! Local smoke against an already-running Postgres (no Docker required).
//!
//! Ignored by default so a plain `cargo test` stays green without a database.
//! Run it through `scripts/smoke-postgres.sh`, or directly:
//!
//! ```text
//! cargo test -p tablepro-driver-postgres --test smoke_local -- --include-ignored
//! ```
//!
//! Env: SMOKE_PG_HOST, SMOKE_PG_PORT, SMOKE_PG_USER, SMOKE_PG_PASS, SMOKE_PG_DB.
//! Defaults match `scripts/smoke-postgres.sh`. `docs/testing.md` has the
//! container one-liner that serves those defaults.
//!
//! The test creates, truncates and drops its own table, so point it at a
//! scratch database.

use drivers_postgres::PgDriver;
use tablepro_core::{ConnectOptions, DatabaseDriver, Value};

const TABLE: &str = "tablepro_smoke_items";
const DEFAULT_PORT: u16 = 54329;

fn opts_from_env() -> ConnectOptions {
    ConnectOptions {
        host: std::env::var("SMOKE_PG_HOST").unwrap_or_else(|_| "127.0.0.1".into()),
        port: port_from_env(),
        database: std::env::var("SMOKE_PG_DB").unwrap_or_else(|_| "tablepro".into()),
        username: std::env::var("SMOKE_PG_USER").unwrap_or_else(|_| "tablepro".into()),
        password: secrecy::SecretString::new(
            std::env::var("SMOKE_PG_PASS")
                .unwrap_or_else(|_| "tablepro".into())
                .into(),
        ),
        use_tls: false,
        ..Default::default()
    }
}

fn port_from_env() -> u16 {
    let Ok(raw) = std::env::var("SMOKE_PG_PORT") else {
        return DEFAULT_PORT;
    };
    raw.parse()
        .unwrap_or_else(|e| panic!("SMOKE_PG_PORT={raw} is not a port number: {e}"))
}

#[tokio::test]
#[ignore = "requires a local postgres; run via scripts/smoke-postgres.sh"]
async fn connect_browse_and_edit_cell() {
    let opts = opts_from_env();
    let conn = PgDriver.connect(opts).await.expect("connect to smoke postgres");

    conn.execute(&format!(
        "CREATE TABLE IF NOT EXISTS {TABLE} (
            id SERIAL PRIMARY KEY,
            name TEXT NOT NULL,
            qty INT DEFAULT 0
        )"
    ))
    .await
    .expect("create table");

    conn.execute(&format!("DELETE FROM {TABLE}")).await.expect("clear");
    conn.execute(&format!(
        "INSERT INTO {TABLE} (name, qty) VALUES ('alpha', 1), ('beta', 2)"
    ))
    .await
    .expect("seed");

    let tables = conn.list_tables().await.expect("list_tables");
    assert!(
        tables.iter().any(|t| t.name == TABLE),
        "{TABLE} missing from {:?}",
        tables.iter().map(|t| &t.name).collect::<Vec<_>>()
    );

    let cols = conn.fetch_columns(Some("public"), TABLE).await.expect("fetch_columns");
    assert!(cols.iter().any(|c| c.name == "id" && c.primary_key));

    let before = conn
        .fetch_rows(Some("public"), TABLE, 0, 100)
        .await
        .expect("fetch_rows");
    assert_eq!(before.rows.len(), 2);

    let updated = conn
        .execute_params(
            &format!("UPDATE {TABLE} SET qty = $1 WHERE name = $2"),
            &[Value::Int(99), Value::Text("alpha".into())],
        )
        .await
        .expect("edit cell");
    assert_eq!(updated.rows_affected, 1);

    let after = conn
        .query(&format!("SELECT qty FROM {TABLE} WHERE name = 'alpha'"))
        .await
        .expect("verify");
    assert_eq!(after.rows.len(), 1);
    assert_eq!(after.rows[0][0], Value::Int(99));

    conn.execute(&format!("DROP TABLE {TABLE}")).await.expect("drop table");

    conn.close().await.expect("close");
}
