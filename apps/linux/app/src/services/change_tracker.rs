pub use tablepro_app_services::change_tracker::*;

#[derive(Debug)]
struct RelmTrackerEvents(relm4::Sender<TrackerEvent>);

impl TrackerEventSink for RelmTrackerEvents {
    fn emit(&self, event: TrackerEvent) {
        let _ = self.0.send(event);
    }
}

pub fn subscribe(tab_id: uuid::Uuid, sender: relm4::Sender<TrackerEvent>) {
    with_tab(tab_id, |tracker| tracker.subscribe(RelmTrackerEvents(sender)));
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_core::Value;

    #[tokio::test]
    async fn the_app_bridge_delivers_row_and_pending_count_events_to_relm() {
        let id = uuid::Uuid::new_v4();
        let (sender, receiver) = relm4::channel();
        open_tab(id);
        subscribe(id, sender);
        let key = RowKey::from_pk_values(&[Value::Int(7)]).unwrap();
        with_tab(id, |tracker| {
            tracker.track_cell_edit(key.clone(), 1, Value::Int(1), Value::Int(2))
        });
        let event = tokio::time::timeout(std::time::Duration::from_secs(5), receiver.recv())
            .await
            .unwrap();
        assert!(matches!(event, Some(TrackerEvent::ChangedRows(keys)) if keys == vec![key]));
        let event = tokio::time::timeout(std::time::Duration::from_secs(5), receiver.recv())
            .await
            .unwrap();
        assert!(matches!(event, Some(TrackerEvent::PendingCountChanged(1))));
        close_tab(id);
        assert!(with_tab_ref(id, |_| ()).is_none());
    }
}
