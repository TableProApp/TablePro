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
    async fn a_deleted_rows_unique_value_can_be_added_again_in_the_same_save() {
        use tablepro_core::{ConnectOptions, DatabaseDriver, OperationControl};
        let connection = drivers_sqlite::SqliteDriver
            .connect(ConnectOptions {
                database: ":memory:".into(),
                ..Default::default()
            })
            .await
            .unwrap();
        let control = OperationControl::with_timeout(std::time::Duration::from_secs(10));
        for sql in [
            "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE)",
            "INSERT INTO users VALUES (1, 'a@example.com')",
        ] {
            connection.execute_controlled(sql, &control).await.unwrap();
        }
        let columns = connection
            .fetch_columns_controlled(None, "users", &control)
            .await
            .unwrap();
        let mut tracker = TabChangeTracker::new();
        tracker.track_delete(
            RowKey::from_pk_values(&[Value::Int(1)]).unwrap(),
            vec![Value::Int(1), Value::Text("a@example.com".into())],
        );
        tracker.track_insert(vec![Value::Int(2), Value::Text("a@example.com".into())]);
        let (statements, _) = tracker.materialize("sqlite", None, "users", &columns).unwrap();

        connection
            .execute_in_transaction_controlled(&statements, &control)
            .await
            .expect("the delete frees the unique email before the insert takes it");
        let rows = connection
            .query_controlled("SELECT email FROM users", &control)
            .await
            .unwrap()
            .rows;
        assert_eq!(rows, [[Value::Text("a@example.com".into())]]);
    }

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
