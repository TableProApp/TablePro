use std::sync::Arc;

use gtk4::glib;
use tablepro_core::meta::ObjectScope;
use tablepro_session::runtime::WatchForwarder;
use tablepro_session::{ObjectListSnapshot, OperationError, Session};

pub(in crate::ui::workspace) fn spawn_local(future: futures::future::LocalBoxFuture<'static, ()>) {
    glib::spawn_future_local(future);
}

/// Deliver each object list the catalog commits for every schema, and
/// each refresh of it that failed, which keeps the list it had. The list
/// on screen when the watch starts is not delivered again.
pub(in crate::ui::workspace) fn catalog_watch(
    session: &Arc<Session>,
    mut listed: impl FnMut(ObjectListSnapshot) + 'static,
    mut failed: impl FnMut(Arc<OperationError>) + 'static,
) -> WatchForwarder {
    let objects = session.catalog().subscribe(ObjectScope::AllSchemas);
    let (mut shown, mut reported) = {
        let current = objects.borrow();
        (current.generation, current.last_error.clone())
    };
    WatchForwarder::new(
        objects,
        move |snapshot: ObjectListSnapshot| {
            if snapshot.generation != shown {
                shown = snapshot.generation;
                listed(snapshot);
                return;
            }
            let Some(error) = snapshot.last_error else {
                return;
            };
            if !reported.as_ref().is_some_and(|seen| Arc::ptr_eq(seen, &error)) {
                reported = Some(error.clone());
                failed(error);
            }
        },
        spawn_local,
    )
}

/// Deliver each list a reconnect commits for the default schema. The
/// reconnect marks every other list stale without reading it, so this is
/// when the sidebar's list is read again.
pub(in crate::ui::workspace) fn reconnect_watch(
    session: &Arc<Session>,
    mut committed: impl FnMut(ObjectListSnapshot) + 'static,
) -> WatchForwarder {
    let objects = session.catalog().subscribe(ObjectScope::DefaultSchema);
    let mut seen = objects.borrow().generation;
    WatchForwarder::new(
        objects,
        move |snapshot: ObjectListSnapshot| {
            if snapshot.generation != seen {
                seen = snapshot.generation;
                committed(snapshot);
            }
        },
        spawn_local,
    )
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::collections::VecDeque;
    use std::rc::Rc;
    use std::time::Duration;

    use tablepro_core::DriverError;
    use tablepro_core::meta::{ObjectInfo, ObjectKind};
    use tablepro_test_support::{CallCounters, ConnectionScript, FakeReply};

    use super::*;
    use crate::test_support::FakeSession;

    fn names(snapshot: &ObjectListSnapshot) -> Vec<String> {
        snapshot.objects.iter().map(|object| object.name.clone()).collect()
    }

    /// The workspace's input queue, holding what the catalog watch
    /// posted until the workspace handles it.
    type Queue<T> = Rc<RefCell<VecDeque<T>>>;

    fn post_to<T: 'static>(queue: &Queue<T>) -> impl FnMut(T) + 'static {
        let queue = queue.clone();
        move |update| queue.borrow_mut().push_back(update)
    }

    fn refresh_objects(
        session: &Arc<Session>,
        runtime: &crate::runtime::AppRuntime,
    ) -> impl Future<Output = ()> + use<> {
        let session = session.clone();
        let refreshing = runtime
            .tasks()
            .spawn_task(async move { session.refresh_objects(ObjectScope::AllSchemas).await });
        async move {
            let _ = refreshing.await;
        }
    }

    fn object(name: &str, kind: ObjectKind) -> ObjectInfo {
        ObjectInfo {
            schema: Some("public".to_owned()),
            name: name.to_owned(),
            kind,
        }
    }

    /// A workspace drops its catalog watch with itself, so a list read
    /// for its session after that reaches nothing.
    #[gtk4::test]
    fn f002_a_late_catalog_commit_after_the_watch_drops_is_not_delivered() {
        let runtime = crate::test_support::test_runtime();
        let mut script = ConnectionScript::default();
        script.list_objects.always(FakeReply::Late {
            after: Duration::from_millis(300),
            outcome: Ok(vec![object("late", ObjectKind::Table)]),
        });
        let fake = FakeSession::start(script, [], runtime.tasks());
        let queue = Queue::default();
        let failures = Queue::default();
        let watching = catalog_watch(&fake.session, post_to(&queue), post_to(&failures));
        let late = refresh_objects(&fake.session, &runtime);
        let counters = fake.connection.counters();
        crate::test_support::wait_until(Duration::from_secs(5), || {
            CallCounters::get(&counters.list_objects) == 1
        })
        .expect("the list was asked for");

        drop(watching);
        crate::test_support::finish_on_main(Duration::from_secs(5), late).expect("the list to land");
        crate::test_support::drain_main_context();

        assert_eq!(
            names(&fake.session.subscribe_objects(ObjectScope::AllSchemas).borrow()),
            ["late"],
            "the late list never landed, so the test proved nothing"
        );
        assert!(queue.borrow().is_empty(), "a dropped watch still delivered");
    }

    #[gtk4::test]
    fn a_new_list_is_delivered_once() {
        let runtime = crate::test_support::test_runtime();
        let mut script = ConnectionScript::default();
        script
            .list_objects
            .always(FakeReply::ok(vec![object("users", ObjectKind::Table)]));
        let fake = FakeSession::start(script, [], runtime.tasks());
        let queue = Queue::default();
        let failures = Queue::default();
        let _watching = catalog_watch(&fake.session, post_to(&queue), post_to(&failures));

        crate::test_support::finish_on_main(Duration::from_secs(5), refresh_objects(&fake.session, &runtime))
            .expect("the list to land");
        crate::test_support::wait_until(Duration::from_secs(5), || queue.borrow().len() == 1)
            .expect("the list was delivered");
        crate::test_support::drain_main_context();

        assert_eq!(queue.borrow().len(), 1);
        assert_eq!(names(&queue.borrow()[0]), ["users"]);
        assert!(failures.borrow().is_empty());
    }

    #[gtk4::test]
    fn a_failed_refresh_is_delivered_without_a_list() {
        let runtime = crate::test_support::test_runtime();
        let mut script = ConnectionScript::default();
        script
            .list_objects
            .once(FakeReply::ok(vec![object("users", ObjectKind::Table)]))
            .always(FakeReply::err(DriverError::Protocol("catalog gone".to_owned())));
        let fake = FakeSession::start(script, [], runtime.tasks());
        let queue = Queue::default();
        let failures = Queue::default();
        let _watching = catalog_watch(&fake.session, post_to(&queue), post_to(&failures));

        crate::test_support::finish_on_main(Duration::from_secs(5), refresh_objects(&fake.session, &runtime))
            .expect("the list to land");
        crate::test_support::finish_on_main(Duration::from_secs(5), refresh_objects(&fake.session, &runtime))
            .expect("the refresh to fail");
        crate::test_support::wait_until(Duration::from_secs(5), || failures.borrow().len() == 1)
            .expect("the failure was delivered");

        assert_eq!(queue.borrow().len(), 1, "a failed refresh delivered a list");
        assert_eq!(
            names(&fake.session.subscribe_objects(ObjectScope::AllSchemas).borrow()),
            ["users"],
            "the failure emptied the list"
        );
    }
}
