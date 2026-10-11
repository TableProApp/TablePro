use std::time::Duration;

use drivers_mongodb::MongodbDriver;
use mongodb::bson::doc;
use tablepro_core::{ConnectOptions, Connection, DatabaseDriver, DriverError, OperationControl};
use testcontainers::ImageExt;
use testcontainers_modules::mongo::Mongo;
use testcontainers_modules::testcontainers::runners::AsyncRunner;
use tokio_util::sync::CancellationToken;

#[tokio::test]
#[ignore = "requires docker"]
async fn cancelling_a_blocked_mongodb_metadata_census_leaves_the_client_usable() {
    let container = Mongo::default()
        .with_tag(super::MONGO_TAG)
        .with_cmd(["mongod", "--setParameter", "enableTestCommands=1", "--bind_ip_all"])
        .start()
        .await
        .expect("start MongoDB with test failpoints enabled");
    let host = container.get_host().await.expect("host").to_string();
    let port = container.get_host_port_ipv4(27017).await.expect("port");
    let connection: std::sync::Arc<dyn Connection> = MongodbDriver
        .connect(ConnectOptions {
            host: host.clone(),
            port,
            database: "appdb".into(),
            ..Default::default()
        })
        .await
        .expect("connect driver")
        .into();
    let native = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect native oracle");
    let table = "census_cancel";
    native
        .database("appdb")
        .collection::<mongodb::bson::Document>(table)
        .insert_many([
            doc! { "_id": 1, "payload": "first" },
            doc! { "_id": 2, "payload": "second" },
        ])
        .await
        .expect("seed census collection");
    native
        .database("admin")
        .run_command(doc! {
            "configureFailPoint": "failCommand",
            "mode": { "times": 1 },
            "data": {
                "failCommands": ["find"],
                "blockConnection": true,
                "blockTimeMS": 15_000
            }
        })
        .await
        .expect("block the metadata census find");

    let token = CancellationToken::new();
    let control = OperationControl::new(token.clone(), None);
    let running = connection.clone();
    let task = tokio::spawn(async move { running.fetch_columns_controlled(None, table, &control).await });
    let mut census_is_blocked = false;
    for _ in 0..100 {
        let current = native
            .database("admin")
            .run_command(doc! { "currentOp": 1, "$all": true })
            .await
            .expect("inspect active census");
        census_is_blocked = current
            .get_array("inprog")
            .expect("currentOp returns active operations")
            .iter()
            .filter_map(|operation| operation.as_document())
            .filter_map(|operation| operation.get_document("command").ok())
            .any(|command| command.get_str("find").ok() == Some(table));
        if census_is_blocked {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(
        census_is_blocked,
        "MongoDB must be blocked inside the census find before cancellation"
    );
    token.cancel();

    let error = tokio::time::timeout(Duration::from_secs(2), task)
        .await
        .expect("cancelled metadata census must return promptly")
        .expect("census task")
        .expect_err("cancelled census must not return columns");
    assert!(
        matches!(error, DriverError::OperationOutcomeUnknown { ref source } if matches!(**source, DriverError::Cancelled)),
        "a cancelled in-flight census has an unknown outcome, got {error:?}"
    );

    let columns = tokio::time::timeout(Duration::from_secs(10), connection.fetch_columns(None, table))
        .await
        .expect("a later census must not hang")
        .expect("same client remains usable after census cancellation");
    assert!(columns.iter().any(|column| column.name == "payload"));
    let count = native
        .database("appdb")
        .collection::<mongodb::bson::Document>(table)
        .count_documents(doc! {})
        .await
        .expect("native rows remain present");
    assert_eq!(count, 2);
}
