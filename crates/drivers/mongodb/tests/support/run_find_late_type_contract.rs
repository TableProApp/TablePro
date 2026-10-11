use drivers_mongodb::MongodbDriver;
use mongodb::bson::{Decimal128, Document, doc};
use tablepro_core::{DatabaseDriver, Value};
use testcontainers::ImageExt;
use testcontainers_modules::testcontainers::runners::AsyncRunner;

#[tokio::test]
#[ignore = "requires docker"]
async fn run_find_marks_a_page_mixed_when_a_bson_type_changes_after_census() {
    let container = super::Mongo::default()
        .with_tag(super::MONGO_TAG)
        .with_cmd(["mongod", "--setParameter", "enableTestCommands=1", "--bind_ip_all"])
        .start()
        .await
        .expect("start MongoDB with test failpoints enabled");
    let host = container.get_host().await.expect("host").to_string();
    let port = container.get_host_port_ipv4(27017).await.expect("port");
    let connection = MongodbDriver
        .connect(super::opts(&host, port, "appdb"))
        .await
        .expect("connect driver");
    let native = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("native MongoDB client");
    let collection = native
        .database("appdb")
        .collection::<Document>("late_type_after_census");
    collection
        .insert_one(doc! { "_id": 1, "value": "12345678901234567890.1234567890123" })
        .await
        .expect("seed the type census");

    native
        .database("admin")
        .run_command(doc! {
            "configureFailPoint": "failCommand",
            "mode": { "skip": 1 },
            "data": {
                "failCommands": ["find"],
                "blockConnection": true,
                "blockTimeMS": 3_000
            }
        })
        .await
        .expect("skip census find and block the following page find");

    let running = tokio::spawn(async move { connection.query("db.late_type_after_census.find({})").await });
    let mut blocked_page_find = false;
    for _ in 0..100 {
        let current = native
            .database("admin")
            .run_command(doc! { "currentOp": 1, "$all": true })
            .await
            .expect("inspect the in-flight page query");
        blocked_page_find = current
            .get_array("inprog")
            .expect("currentOp returns active operations")
            .iter()
            .filter_map(|operation| operation.as_document())
            .filter_map(|operation| operation.get_document("command").ok())
            .any(|command| command.get_str("find").ok() == Some("late_type_after_census"));
        if blocked_page_find {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    assert!(
        blocked_page_find,
        "run_find must reach the blocked page find after its census"
    );

    let decimal_text = "12345678901234567890.1234567890123";
    let decimal = decimal_text.parse::<Decimal128>().unwrap();
    collection
        .update_one(doc! { "_id": 1 }, doc! { "$set": { "value": decimal } })
        .await
        .expect("change the BSON type after metadata census");

    let page = tokio::time::timeout(std::time::Duration::from_secs(10), running)
        .await
        .expect("the page query returns after the failpoint")
        .expect("query task")
        .expect("run_find succeeds");
    native
        .database("admin")
        .run_command(doc! { "configureFailPoint": "failCommand", "mode": "off" })
        .await
        .expect("disable the test failpoint");

    let value_index = page.columns.iter().position(|column| column.name == "value").unwrap();
    assert_eq!(page.columns[value_index].data_type, "mixed");
    assert_eq!(
        page.rows,
        vec![vec![
            Value::Int(1),
            Value::Json(serde_json::json!({"$numberDecimal": decimal_text})),
        ]]
    );
    assert_eq!(
        collection
            .find_one(doc! { "_id": 1 })
            .await
            .unwrap()
            .unwrap()
            .get("value"),
        Some(&mongodb::bson::Bson::Decimal128(decimal))
    );
}
