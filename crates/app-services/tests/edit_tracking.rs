#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::cell::RefCell;
use std::rc::Rc;
use tablepro_app_services::change_tracker::{RowKey, TabChangeTracker, TrackerEvent, TrackerEventSink};
use tablepro_core::Value;

#[derive(Debug, Clone)]
struct Events(Rc<RefCell<Vec<TrackerEvent>>>);

impl TrackerEventSink for Events {
    fn emit(&self, event: TrackerEvent) {
        self.0.borrow_mut().push(event);
    }
}

#[test]
fn edits_and_clear_notify_every_subscriber_without_gui_channels() {
    let first = Events(Rc::default());
    let second = Events(Rc::default());
    let mut tracker = TabChangeTracker::default();
    tracker.subscribe(first.clone());
    tracker.subscribe(second.clone());
    let key = RowKey::from_pk_values(&[Value::Int(7)]).unwrap();
    tracker.track_cell_edit(
        key.clone(),
        1,
        Value::Text("before".into()),
        Value::Text("after".into()),
    );
    for events in [&first, &second] {
        let events = events.0.borrow();
        assert!(matches!(&events[0], TrackerEvent::ChangedRows(keys) if keys == std::slice::from_ref(&key)));
        assert!(matches!(&events[1], TrackerEvent::PendingCountChanged(1)));
    }
    tracker.clear();
    assert!(!tracker.has_pending());
    for events in [&first, &second] {
        assert!(
            events
                .0
                .borrow()
                .iter()
                .any(|event| matches!(event, TrackerEvent::Cleared))
        );
    }
}
