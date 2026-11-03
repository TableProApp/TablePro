// One matrix, run on the library the app downloads and on the same driver linked in: the ABI must behave the
// same both ways (core/docs/decisions/0004-driver-plugin-abi.md).

use std::sync::Arc;
use std::time::{Duration, Instant};

use arrow_array::{Array, BinaryArray, Float64Array, Int64Array, StringArray};
use arrow_schema::DataType;
use tablepro_driver_abi::ffi::status;
use tablepro_driver_abi::proto::{self, Request, request, response};
use tablepro_driver_host::DriverHandle;

use crate::support::*;

async fn describes_itself(handle: &DriverHandle) {
    let reply = call(handle, request::Kind::Describe(proto::Describe {})).await;

    assert_eq!(reply.status, status::OK);
    let Some(response::Kind::Description(description)) = reply.response.kind else {
        panic!("no description");
    };
    assert_eq!(description.id, "sqlite");
    assert_eq!(description.display_name, "SQLite");
    assert_eq!(description.data_model(), proto::DataModel::Relational);
    assert_eq!(description.category(), proto::Category::Relational);
    let Some(proto::description::Endpoint::File(file)) = description.endpoint else {
        panic!("SQLite opens files");
    };
    assert!(file.suffixes.iter().any(|suffix| suffix == "sqlite"));
}

async fn lists_the_catalog(handle: &DriverHandle, connection: u64) {
    let schemas = call(handle, request::Kind::ListSchemas(proto::ListSchemas { connection })).await;
    let Some(response::Kind::Schemas(schemas)) = schemas.response.kind else {
        panic!("no schemas");
    };
    assert!(
        schemas
            .schemas
            .iter()
            .any(|schema| schema.name == "main" && schema.is_default)
    );

    let objects = call(
        handle,
        request::Kind::ListObjects(proto::ListObjects {
            connection,
            schema: None,
        }),
    )
    .await;
    let Some(response::Kind::Objects(objects)) = objects.response.kind else {
        panic!("no objects");
    };
    let kind_of = |name: &str| {
        objects
            .objects
            .iter()
            .find(|object| object.name == name)
            .map(proto::Object::kind)
    };
    assert_eq!(kind_of("people"), Some(proto::ObjectKind::Table));
    assert_eq!(kind_of("top_people"), Some(proto::ObjectKind::View));
}

async fn reads_rows_as_arrow(handle: &DriverHandle, connection: u64) {
    let reply = call(
        handle,
        read(connection, "SELECT id, name, score, badge FROM people ORDER BY id", 2),
    )
    .await;

    assert_eq!(reply.status, status::OK, "{:?}", reply.response);
    let Some(response::Kind::ReadDone(done)) = reply.response.kind else {
        panic!("no read result");
    };
    assert_eq!((done.rows, done.truncated), (2, true));
    let batch = reply.rows.expect("rows came as Arrow");
    assert_eq!(batch.num_rows(), 2);
    assert_eq!(batch.schema().field(0).data_type(), &DataType::Int64);
    let ids = batch.column(0).as_any().downcast_ref::<Int64Array>().unwrap();
    let names = batch.column(1).as_any().downcast_ref::<StringArray>().unwrap();
    let scores = batch.column(2).as_any().downcast_ref::<Float64Array>().unwrap();
    let badges = batch.column(3).as_any().downcast_ref::<BinaryArray>().unwrap();
    assert_eq!(ids.values(), &[1, 2]);
    assert_eq!((names.value(0), names.value(1)), ("Ada", "Linus"));
    assert_eq!(scores.value(1), 7.25);
    assert_eq!(badges.value(0), [1, 2]);
    assert!(badges.is_null(1));

    let every = call(handle, read(connection, "SELECT name FROM people", 0)).await;
    let Some(response::Kind::ReadDone(done)) = every.response.kind else {
        panic!("no read result");
    };
    assert_eq!((done.rows, done.truncated), (3, false));
}

async fn reads_only_the_first_statement(handle: &DriverHandle, connection: u64) {
    let reply = call(
        handle,
        read(
            connection,
            "SELECT name FROM people WHERE id = 1; SELECT name FROM people",
            0,
        ),
    )
    .await;

    assert_eq!(reply.status, status::OK, "{:?}", reply.response);
    let Some(response::Kind::ReadDone(done)) = reply.response.kind else {
        panic!("no read result");
    };
    assert_eq!((done.rows, done.truncated), (1, false));
}

async fn reports_the_engines_error(handle: &DriverHandle, connection: u64) {
    let reply = call(handle, read(connection, "SELECT nope FROM nowhere", 0)).await;

    assert_eq!(reply.status, status::DRIVER);
    assert_eq!(error_code(&reply.response), "driver.server");
}

async fn answers_an_unknown_kind_unsupported(handle: &DriverHandle) {
    // Field 99, length-delimited and empty: a kind a later host might send.
    let pending = handle.start_bytes(&[0x9A, 0x06, 0x00]).unwrap();
    let reply = tokio::time::timeout(WAIT, pending.reply()).await.unwrap();

    assert_eq!(reply.status, status::UNSUPPORTED);
    assert_eq!(error_code(&reply.response), "abi.unsupported");
    assert_eq!(handle.start_bytes(&[0xFF]).err(), Some(status::BAD_REQUEST));
}

async fn cancels_a_running_read(handle: &DriverHandle, connection: u64) {
    let pending = handle.start(&Request::of(read(connection, ENDLESS, 0))).unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;
    let cancelled_at = Instant::now();

    assert_eq!(handle.cancel(pending.call_id), status::OK);
    let reply = tokio::time::timeout(WAIT, pending.reply()).await.unwrap();

    assert_eq!(reply.status, status::CANCELLED, "{:?}", reply.response);
    assert!(cancelled_at.elapsed() < Duration::from_secs(10));
    assert_eq!(handle.cancel(u64::MAX), status::UNKNOWN_CALL);
}

async fn closes_a_connection(handle: &DriverHandle, connection: u64) {
    let closed = call(handle, request::Kind::Close(proto::Close { connection })).await;
    assert_eq!(closed.status, status::OK);

    let after = call(handle, read(connection, "SELECT 1", 0)).await;
    assert_eq!(after.status, status::BAD_REQUEST);
    assert_eq!(error_code(&after.response), "abi.unknown_connection");
}

async fn shuts_down_with_a_call_in_flight(handle: DriverHandle, connection: u64) {
    let handle = Arc::new(handle);
    let pending = handle.start(&Request::of(read(connection, ENDLESS, 0))).unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;

    assert!(
        shut_down(Arc::clone(&handle)).await,
        "a driver thread outlived shutdown"
    );
    let reply = tokio::time::timeout(WAIT, pending.reply()).await.unwrap();

    assert_ne!(reply.status, status::OK);
    assert_eq!(
        handle
            .start(&Request::of(request::Kind::Describe(proto::Describe {})))
            .err(),
        Some(status::SHUT_DOWN)
    );
}

async fn matrix(handle: DriverHandle) {
    let folder = tempfile::tempdir().unwrap();
    let path = people_database(folder.path()).await;

    describes_itself(&handle).await;
    let connection = open(&handle, &path).await;
    lists_the_catalog(&handle, connection).await;
    reads_rows_as_arrow(&handle, connection).await;
    reads_only_the_first_statement(&handle, connection).await;
    reports_the_engines_error(&handle, connection).await;
    answers_an_unknown_kind_unsupported(&handle).await;
    cancels_a_running_read(&handle, connection).await;
    let probed = call(&handle, request::Kind::Probe(proto::Probe { connection })).await;
    assert_eq!(probed.status, status::OK);
    closes_a_connection(&handle, connection).await;
    let second = open(&handle, &path).await;
    shuts_down_with_a_call_in_flight(handle, second).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_downloadable_library_passes_the_matrix() {
    matrix(load_dynamic()).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_driver_linked_in_passes_the_same_matrix() {
    matrix(load_static()).await;
}
