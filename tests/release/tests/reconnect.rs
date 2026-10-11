#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use tablepro_core::{Connection, DatabaseDriver, TlsMode};
use tablepro_release_tests::Fixture;

use drivers_postgres::PgDriver;

async fn query_fails_within(connection: &dyn Connection, attempts: usize) -> bool {
    for _ in 0..attempts {
        if connection.query("SELECT 1").await.is_err() {
            return true;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    false
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn direct_reconnect_restores_a_verified_session() {
    let fixture = Fixture::from_env();
    let toxiproxy = fixture.toxiproxy();
    let connection = fixture.connect_verified().await;
    connection.ping().await.expect("first session is usable");

    toxiproxy.set_enabled("postgres", false).await;
    let broke = query_fails_within(connection.as_ref(), 30).await;
    toxiproxy.set_enabled("postgres", true).await;
    assert!(broke, "cutting the database path must fail queries on the old session");

    let replacement = fixture.connect_verified().await;
    replacement
        .ping()
        .await
        .expect("reconnect must produce a usable session");
    let result = replacement
        .query("SELECT count(*) FROM release_items")
        .await
        .expect("query after reconnect");
    assert_eq!(result.rows.len(), 1);
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn ssh_reconnect_replaces_the_tunnel_and_the_session() {
    let fixture = Fixture::from_env();
    let toxiproxy = fixture.toxiproxy();
    let tunnel = fixture.open_tunnel().await;
    let connection = PgDriver
        .connect(fixture.tunneled_options(&tunnel, TlsMode::Require, None))
        .await
        .expect("first tunneled session");
    connection.ping().await.expect("first tunneled session is usable");

    toxiproxy.set_enabled("bastion", false).await;
    let broke = query_fails_within(connection.as_ref(), 30).await;
    toxiproxy.set_enabled("bastion", true).await;
    assert!(broke, "cutting the bastion path must fail queries on the old session");
    drop(connection);
    drop(tunnel);

    let replacement_tunnel = fixture.open_tunnel().await;
    let replacement = PgDriver
        .connect(fixture.tunneled_options(&replacement_tunnel, TlsMode::Require, None))
        .await
        .expect("reconnect must open a new tunnel and session");
    let result = replacement
        .query("SELECT count(*) FROM release_items")
        .await
        .expect("query after ssh reconnect");
    assert_eq!(result.rows.len(), 1);
}
