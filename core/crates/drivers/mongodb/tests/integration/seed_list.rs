//! A DNS seed list end to end, through the public records the MongoDB
//! specification keeps for drivers' tests, against the set they name.

use tablepro_core::meta::{ObjectScope, TableRef};
use tablepro_core::{NetworkOptions, NetworkTarget, RunEnd, TlsConfig, Value};
use tablepro_test_fixtures::MongoFixture;
use tablepro_test_support::conformance::test_liveness;

use crate::support::{CALL, connect_to, direct, editor, first_page, password, run, save_field, unique, within};

/// SRV `localhost.test.build.10gen.cc:27017`, TXT `replicaSet=repl0&authSource=thisDB`.
const SEED_LIST: &str = "test5.test.build.10gen.cc";

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker, public DNS and host port 27017"]
async fn a_seed_list_logs_in_where_its_txt_record_says_then_pages_and_saves() {
    let fixture = MongoFixture::start_on_test_records()
        .await
        .expect("the set the records name");
    let liveness = test_liveness();
    // No database and no Authentication Database: only the TXT record names thisDB, the user's one database.
    let target = NetworkTarget {
        transport: direct(SEED_LIST, MongoFixture::PORT, &liveness),
        credentials: password(&fixture.this_db_credentials().expect("a user defined in thisDB")),
        database: None,
        tls: TlsConfig::disabled(),
        options: NetworkOptions {
            dns_seed_list: true,
            ..NetworkOptions::default()
        },
    };

    let connection = connect_to(target, liveness).await;

    let session = editor(connection.as_ref()).await;
    let collection = unique("listed");
    let (filled, _) = run(
        session.as_ref(),
        &format!(
            "db.getSiblingDB('{}').getCollection('{collection}').insertMany([{{_id: 1, label: 'a'}}, \
             {{_id: 2, label: 'b'}}, {{_id: 3, label: 'c'}}])",
            MongoFixture::THIS_DB
        ),
    )
    .await;
    assert_eq!(filled.end, RunEnd::Completed);
    let objects = connection
        .list_objects(&ObjectScope::Schema(MongoFixture::THIS_DB.to_owned()), within(CALL))
        .await
        .expect("the database's collections");
    assert!(objects.iter().any(|object| object.name == collection), "{objects:?}");
    let table = TableRef::new(Some(MongoFixture::THIS_DB.to_owned()), collection.clone());
    let read = first_page(connection.as_ref(), &table).await;
    let ids: Vec<&Value> = read.result.rows.iter().filter_map(|row| row.first()).collect();
    assert_eq!(ids, [&Value::Int(1), &Value::Int(2), &Value::Int(3)]);

    let report = save_field(
        connection.as_ref(),
        &table,
        Value::Int(2),
        "label",
        Value::Text("renamed".to_owned()),
    )
    .await;

    assert_eq!(report.rows_affected, [Some(1)]);
    let read = first_page(connection.as_ref(), &table).await;
    let edited = read.result.rows.iter().find(|row| row.first() == Some(&Value::Int(2)));
    assert_eq!(
        edited.and_then(|row| row.get(1)),
        Some(&Value::Text("renamed".to_owned()))
    );
    session.close().await;
    connection.close().await.expect("a clean close");
}
