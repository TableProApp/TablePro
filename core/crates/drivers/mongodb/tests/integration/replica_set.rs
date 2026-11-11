//! A replica set found from its seeds: the client takes the names the
//! members give themselves and works through the primary, so the member
//! is named by an address the host reaches, and a seed that does not
//! answer is passed over.

use tablepro_core::meta::{ObjectScope, TableRef};
use tablepro_core::{NetworkOptions, NetworkTarget, RunEnd, TlsConfig, Value};
use tablepro_test_fixtures::MongoFixture;
use tablepro_test_support::conformance::test_liveness;

use crate::support::{CALL, DATABASE, connect_to, direct, editor, first_page, password, run, unique, within};

/// The name the set's one member gives itself.
const MEMBER: &str = "localhost.test.build.10gen.cc:27017";

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker, public DNS and host port 27017"]
async fn a_replica_set_is_found_from_its_seeds_and_read_through_its_primary() {
    let fixture = MongoFixture::start_on_test_records()
        .await
        .expect("a set whose member the host reaches by name");
    let liveness = test_liveness();
    // Only the second seed reaches the set, so the set is found from the host list or not at all.
    let target = NetworkTarget {
        transport: direct("127.0.0.1", closed_port(), &liveness),
        credentials: password(&fixture.password_credentials()),
        database: Some(DATABASE.to_owned()),
        tls: TlsConfig::disabled(),
        options: NetworkOptions {
            auth_database: Some("admin".to_owned()),
            replica_set: Some(MongoFixture::TEST_RECORDS_SET.to_owned()),
            more_hosts: vec![MEMBER.to_owned()],
            ..NetworkOptions::default()
        },
    };

    let connection = connect_to(target, liveness).await;

    let session = editor(connection.as_ref()).await;
    let collection = unique("discovered");
    let (filled, _) = run(
        session.as_ref(),
        &format!("db.getCollection('{collection}').insertMany([{{_id: 1, label: 'a'}}, {{_id: 2, label: 'b'}}])"),
    )
    .await;
    assert_eq!(filled.end, RunEnd::Completed, "a write reaches the primary");
    let objects = connection
        .list_objects(&ObjectScope::Schema(DATABASE.to_owned()), within(CALL))
        .await
        .expect("the database's collections");
    assert!(objects.iter().any(|object| object.name == collection), "{objects:?}");
    let read = first_page(
        connection.as_ref(),
        &TableRef::new(Some(DATABASE.to_owned()), collection.clone()),
    )
    .await;
    let ids: Vec<&Value> = read.result.rows.iter().filter_map(|row| row.first()).collect();
    assert_eq!(ids, [&Value::Int(1), &Value::Int(2)]);
    session.close().await;
    connection.close().await.expect("a clean close");
}

/// A port on this host that nothing listens on.
fn closed_port() -> u16 {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("a free port");
    listener.local_addr().expect("the port bound").port()
}
