use crate::bson::{doc, Document};
use futures::{future::BoxFuture, FutureExt};

use crate::{
    coll::options::CollectionOptions,
    error::Result,
    event::command::CommandEvent,
    options::ReadConcern,
    test::{log_uncaptured, topology_is_standalone},
    Client,
    ClientSession,
    Collection,
};

/// Strunct encapsulating an operation that takes a session in, as well as some associated
/// information.
struct Operation {
    name: &'static str,
    f: OperationFn,
    is_read: bool,
}

/// A Closure that executes an operation and returns the resultant future.
type OperationFn =
    Box<dyn FnOnce(Collection<Document>, &mut ClientSession) -> BoxFuture<Result<()>>>;

impl Operation {
    /// Execute the operation using the provided collection and session.
    async fn execute(self, coll: Collection<Document>, session: &mut ClientSession) -> Result<()> {
        (self.f)(coll, session).await
    }
}

/// Shorthand macro for defining an Operation.
macro_rules! op {
    ($name:expr, $is_read: expr, |$coll:ident, $s:ident| $body:expr) => {
        Operation {
            f: Box::new({ move |$coll, $s| async move { $body.await.map(|_| ()) }.boxed() }),
            name: $name,
            is_read: $is_read,
        }
    };
}

fn all_session_ops() -> impl Iterator<Item = Operation> {
    let mut ops = vec![];

    ops.push(op!("insert", false, |coll, session| {
        coll.insert_one(doc! { "x": 1 }).session(session)
    }));

    ops.push(op!("insert", false, |coll, session| {
        coll.insert_many(vec![doc! { "x": 1 }]).session(session)
    }));

    ops.push(op!("find", true, |coll, session| coll
        .find_one(doc! { "x": 1 })
        .session(session)));

    ops.push(op!("find", true, |coll, session| coll
        .find(doc! { "x": 1 })
        .session(session)));

    ops.push(op!("update", false, |coll, s| coll
        .update_one(doc! { "x": 1 }, doc! { "$inc": { "x": 1 } },)
        .session(s)));

    ops.push(op!("update", false, |coll, s| coll
        .update_many(doc! { "x": 1 }, doc! { "$inc": { "x": 1 } },)
        .session(s)));

    ops.push(op!("update", false, |coll, s| coll
        .replace_one(doc! { "x": 1 }, doc! { "x": 2 },)
        .session(s)));

    ops.push(op!("delete", false, |coll, s| coll
        .delete_one(doc! { "x": 1 })
        .session(s)));

    ops.push(op!("delete", false, |coll, s| coll
        .delete_many(doc! { "x": 1 })
        .session(s)));

    ops.push(op!("findAndModify", false, |coll, s| coll
        .find_one_and_update(doc! { "x": 1 }, doc! { "$inc": { "x": 1 } },)
        .session(s)));

    ops.push(op!("findAndModify", false, |coll, s| coll
        .find_one_and_replace(doc! { "x": 1 }, doc! { "x": 1  },)
        .session(s)));

    ops.push(op!("findAndModify", false, |coll, s| coll
        .find_one_and_delete(doc! { "x": 1 })
        .session(s)));

    ops.push(op!("aggregate", true, |coll, s| coll
        .count_documents(doc! { "x": 1 })
        .session(s)));

    ops.push(op!("aggregate", true, |coll, s| coll
        .aggregate(vec![doc! { "$match": { "x": 1 } }])
        .session(s)));

    ops.push(op!("aggregate", false, |coll, s| coll
        .aggregate(vec![
            doc! { "$match": { "x": 1 } },
            doc! { "$out": "some_other_coll" },
        ])
        .session(s)));

    ops.push(op!("distinct", true, |coll, s| coll
        .distinct("x", doc! {},)
        .session(s)));

    ops.into_iter()
}

/// Test 1 from the causal consistency specification.
#[tokio::test]
async fn new_session_operation_time_null() {
    if topology_is_standalone().await {
        log_uncaptured(
            "skipping new_session_operation_time_null due to unsupported topology: standalone",
        );
        return;
    }

    let client = Client::for_test().monitor_events().await;
    let session = client.start_session().await.unwrap();
    assert!(session.operation_time().is_none());
}

/// Test 2 from the causal consistency specification.
#[tokio::test]
async fn first_read_no_after_cluster_time() {
    if topology_is_standalone().await {
        log_uncaptured(
            "skipping first_read_no_after_cluser_time due to unsupported topology: standalone",
        );
        return;
    }

    let client = Client::for_test().monitor_events().await;
    for op in all_session_ops().filter(|o| o.is_read) {
        client.events.clone().clear_cached_events();

        let mut session = client
            .start_session()
            .causal_consistency(true)
            .await
            .unwrap();
        assert!(session.operation_time().is_none());
        let name = op.name;
        op.execute(
            client
                .create_fresh_collection("causal_consistency_2", "causal_consistency_2", None)
                .await,
            &mut session,
        )
        .await
        .unwrap_or_else(|e| panic!("{name} failed: {e}"));

        let (started, _) = client.events.get_successful_command_execution(name);

        // assert that no read concern was set.
        started.command.get_document("readConcern").unwrap_err();
    }
}

/// Test 3 from the causal consistency specification.
#[tokio::test]
async fn first_op_update_op_time() {
    if topology_is_standalone().await {
        log_uncaptured("skipping first_op_update_op_time due to unsupported topology: standalone");
        return;
    }

    let client = Client::for_test().monitor_events().await;
    for op in all_session_ops() {
        client.events.clone().clear_cached_events();

        let mut session = client
            .start_session()
            .causal_consistency(true)
            .await
            .unwrap();
        assert!(session.operation_time().is_none());
        let name = op.name;
        op.execute(
            client
                .create_fresh_collection("causal_consistency_3", "causal_consistency_3", None)
                .await,
            &mut session,
        )
        .await
        .unwrap();

        let event = client
            .events
            .get_command_events(&[name])
            .into_iter()
            .find(|e| matches!(e, CommandEvent::Succeeded(_) | CommandEvent::Failed(_)))
            .unwrap_or_else(|| panic!("no event found for {name}"));

        match event {
            CommandEvent::Succeeded(s) => {
                let op_time = s.reply.get_timestamp("operationTime").unwrap();
                assert_eq!(session.operation_time().unwrap(), op_time);
            }
            CommandEvent::Failed(_f) => {
                assert!(session.operation_time().is_some());
            }
            _ => panic!("should have been succeeded or failed"),
        }
    }
}

/// Test 4 from the causal consistency specification.
#[tokio::test]
async fn read_includes_after_cluster_time() {
    if topology_is_standalone().await {
        log_uncaptured(
            "skipping read_includes_after_cluster_time due to unsupported topology: standalone",
        );
        return;
    }

    let client = Client::for_test().monitor_events().await;

    let coll = client
        .create_fresh_collection("causal_consistency_4", "causal_consistency_4", None)
        .await;

    for op in all_session_ops().filter(|o| o.is_read) {
        let command_name = op.name;
        let mut session = client.start_session().await.unwrap();
        coll.find_one(doc! {}).session(&mut session).await.unwrap();
        let op_time = session.operation_time().unwrap();
        op.execute(coll.clone(), &mut session).await.unwrap();

        let command_started = client
            .events
            .get_command_started_events(&[command_name])
            .pop()
            .unwrap();

        assert_eq!(
            command_started
                .command
                .get_document("readConcern")
                .expect("no readConcern field found in command")
                .get_timestamp("afterClusterTime")
                .expect("no readConcern.afterClusterTime field found in command"),
            op_time,
        );
    }
}

/// Test 5 from the causal consistency specification.
#[tokio::test]
async fn find_after_write_includes_after_cluster_time() {
    if topology_is_standalone().await {
        log_uncaptured(
            "skipping find_after_write_includes_after_cluster_time due to unsupported topology: \
             standalone",
        );
        return;
    }

    let client = Client::for_test().monitor_events().await;
    let coll = client
        .create_fresh_collection("causal_consistency_5", "causal_consistency_5", None)
        .await;

    for op in all_session_ops().filter(|o| !o.is_read) {
        let mut session = client
            .start_session()
            .causal_consistency(true)
            .await
            .unwrap();
        op.execute(coll.clone(), &mut session).await.unwrap();
        let op_time = session.operation_time().unwrap();
        coll.find_one(doc! {}).session(&mut session).await.unwrap();

        let command_started = client
            .events
            .get_command_started_events(&["find"])
            .pop()
            .unwrap();
        assert_eq!(
            command_started
                .command
                .get_document("readConcern")
                .expect("no readConcern field found in command")
                .get_timestamp("afterClusterTime")
                .expect("no readConcern.afterClusterTime field found in command"),
            op_time,
        );
    }
}

/// Test 6 from the causal consistency specification.
#[tokio::test]
async fn not_causally_consistent_omits_after_cluster_time() {
    if topology_is_standalone().await {
        log_uncaptured(
            "skipping not_causally_consistent_omits_after_cluster_time due to unsupported \
             topology: standalone",
        );
        return;
    }

    let client = Client::for_test().monitor_events().await;
    let coll = client
        .create_fresh_collection("causal_consistency_6", "causal_consistency_6", None)
        .await;

    for op in all_session_ops().filter(|o| o.is_read) {
        let command_name = op.name;

        let mut session = client
            .start_session()
            .causal_consistency(false)
            .await
            .unwrap();
        op.execute(coll.clone(), &mut session).await.unwrap();

        let command_started = client
            .events
            .get_command_started_events(&[command_name])
            .pop()
            .unwrap();
        command_started
            .command
            .get_document("readConcern")
            .unwrap_err();
    }
}

/// Test 7 from the causal consistency specification.
#[tokio::test]
async fn omit_after_cluster_time_standalone() {
    if !topology_is_standalone().await {
        log_uncaptured("skipping omit_after_cluster_time_standalone due to unsupported topology");
        return;
    }

    let client = Client::for_test().monitor_events().await;
    let coll = client
        .create_fresh_collection("causal_consistency_7", "causal_consistency_7", None)
        .await;

    for op in all_session_ops().filter(|o| o.is_read) {
        let command_name = op.name;

        let mut session = client
            .start_session()
            .causal_consistency(true)
            .await
            .unwrap();
        op.execute(coll.clone(), &mut session).await.unwrap();

        let command_started = client
            .events
            .get_command_started_events(&[command_name])
            .pop()
            .unwrap();
        command_started
            .command
            .get_document("readConcern")
            .unwrap_err();
    }
}

/// Test 8 from the causal consistency specification.
#[tokio::test]
async fn omit_default_read_concern_level() {
    if topology_is_standalone().await {
        log_uncaptured(
            "skipping omit_default_read_concern_level due to unsupported topology: standalone",
        );
        return;
    }

    let client = Client::for_test().monitor_events().await;
    let coll = client
        .create_fresh_collection("causal_consistency_8", "causal_consistency_8", None)
        .await;

    for op in all_session_ops().filter(|o| o.is_read) {
        let command_name = op.name;

        let mut session = client
            .start_session()
            .causal_consistency(true)
            .await
            .unwrap();
        coll.find_one(doc! {}).session(&mut session).await.unwrap();
        let op_time = session.operation_time().unwrap();
        op.execute(coll.clone(), &mut session).await.unwrap();

        let command_started = client
            .events
            .get_command_started_events(&[command_name])
            .pop()
            .unwrap();
        let rc_doc = command_started.command.get_document("readConcern").unwrap();

        rc_doc.get_str("level").unwrap_err();
        assert_eq!(rc_doc.get_timestamp("afterClusterTime").unwrap(), op_time);
    }
}

/// Test 9 from the causal consistency specification.
#[tokio::test]
async fn test_causal_consistency_read_concern_merge() {
    if topology_is_standalone().await {
        log_uncaptured(
            "skipping test_causal_consistency_read_concern_merge due to unsupported topology: \
             standalone",
        );
        return;
    }

    let client = Client::for_test().monitor_events().await;
    let mut session = client
        .start_session()
        .causal_consistency(true)
        .await
        .unwrap();

    let coll_options = CollectionOptions::builder()
        .read_concern(ReadConcern::majority())
        .build();
    let _ = client
        .create_fresh_collection("causal_consistency_9", "causal_consistency_9", None)
        .await;
    let coll = client
        .database("causal_consistency_9")
        .collection_with_options("causal_consistency_9", coll_options);

    for op in all_session_ops().filter(|o| o.is_read) {
        let command_name = op.name;
        coll.find_one(doc! {}).session(&mut session).await.unwrap();
        let op_time = session.operation_time().unwrap();
        op.execute(coll.clone(), &mut session).await.unwrap();

        let command_started = client
            .events
            .get_command_started_events(&[command_name])
            .pop()
            .unwrap();
        let rc_doc = command_started
            .command
            .get_document("readConcern")
            .unwrap_or_else(|_| panic!("{command_name} did not include read concern"));

        assert_eq!(rc_doc.get_str("level").unwrap(), "majority");
        assert_eq!(rc_doc.get_timestamp("afterClusterTime").unwrap(), op_time);
    }
}

/// Test 11 from the causal consistency specification.
#[tokio::test]
async fn omit_cluster_time_standalone() {
    if !topology_is_standalone().await {
        log_uncaptured("skipping omit_cluster_time_standalone due to unsupported topology");
        return;
    }

    let client = Client::for_test().monitor_events().await;
    let coll = client
        .database("causal_consistency_11")
        .collection::<Document>("causal_consistency_11");

    coll.find_one(doc! {}).await.unwrap();

    let (started, _) = client.events.get_successful_command_execution("find");
    started.command.get_document("$clusterTime").unwrap_err();
}

/// Test 12 from the causal consistency specification.
#[tokio::test]
async fn cluster_time_sent_in_commands() {
    if topology_is_standalone().await {
        log_uncaptured("skipping cluster_time_sent_in_commands due to unsupported topology");
        return;
    }

    let client = Client::for_test().monitor_events().await;
    let coll = client
        .create_fresh_collection("causal_consistency_12", "causal_consistency_12", None)
        .await;

    coll.find_one(doc! {}).await.unwrap();

    let (started, _) = client.events.get_successful_command_execution("find");
    started.command.get_document("$clusterTime").unwrap();
}
