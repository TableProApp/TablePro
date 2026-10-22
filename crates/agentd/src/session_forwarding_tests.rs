use super::*;

struct SequenceCall {
    schema: Option<String>,
    table: String,
    columns: Vec<String>,
    control: Option<OperationControl>,
}

#[derive(Default)]
struct Marker {
    cancels: bool,
    sequence_calls: Mutex<Vec<SequenceCall>>,
    sequence_failure: bool,
}

impl Marker {
    fn sequence_call(
        &self,
        schema: Option<&str>,
        table: &str,
        columns: &[String],
        control: Option<OperationControl>,
    ) -> Result<(), DriverError> {
        self.sequence_calls.lock().unwrap().push(SequenceCall {
            schema: schema.map(str::to_owned),
            table: table.to_owned(),
            columns: columns.to_vec(),
            control,
        });
        if self.sequence_failure {
            return Err(DriverError::ReadOnly);
        }
        Ok(())
    }
}

fn tables() -> Vec<TableInfo> {
    vec![TableInfo {
        schema: Some("s".into()),
        name: "marker".into(),
    }]
}

fn columns() -> Vec<ColumnInfo> {
    vec![ColumnInfo {
        name: "marker".into(),
        data_type: "text".into(),
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: None,
        domain_type: None,
    }]
}

fn indexes() -> Vec<IndexInfo> {
    vec![IndexInfo {
        name: "marker".into(),
        columns: vec!["a".into()],
        unique: true,
        primary: false,
        predicate: None,
        constraint: None,
        has_expression_key: false,
    }]
}

fn foreign_keys() -> Vec<ForeignKeyInfo> {
    vec![ForeignKeyInfo {
        name: "marker".into(),
        columns: vec!["a".into()],
        ref_schema: None,
        ref_table: "t".into(),
        ref_columns: vec!["b".into()],
        on_delete: None,
        on_update: None,
    }]
}

#[async_trait]
impl Connection for Marker {
    async fn list_databases(&self) -> Result<Vec<String>, DriverError> {
        Ok(vec!["marker_db".into()])
    }

    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        Ok(tables())
    }

    async fn fetch_columns(&self, _: Option<&str>, _: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        Ok(columns())
    }

    async fn fetch_indexes(&self, _: Option<&str>, _: &str) -> Result<Vec<IndexInfo>, DriverError> {
        Ok(indexes())
    }

    async fn fetch_foreign_keys(&self, _: Option<&str>, _: &str) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        Ok(foreign_keys())
    }

    async fn fetch_enum_labels(&self, _: &str, _: &str) -> Result<Vec<String>, DriverError> {
        Ok(vec!["marker_label".into()])
    }

    async fn fetch_rows(&self, _: Option<&str>, _: &str, _: u64, _: u64) -> Result<QueryResult, DriverError> {
        Err(DriverError::Unsupported("unused".into()))
    }

    async fn query(&self, _: &str) -> Result<QueryResult, DriverError> {
        Err(DriverError::Unsupported("unused".into()))
    }

    async fn execute(&self, _: &str) -> Result<ExecResult, DriverError> {
        Err(DriverError::Unsupported("unused".into()))
    }

    async fn execute_params(&self, _: &str, _: &[Value]) -> Result<ExecResult, DriverError> {
        Err(DriverError::Unsupported("unused".into()))
    }

    async fn execute_in_transaction(&self, _: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        Ok(vec![7, 9])
    }

    async fn synchronize_auto_increment_sequences(
        &self,
        schema: Option<&str>,
        table: &str,
        columns: &[String],
    ) -> Result<(), DriverError> {
        self.sequence_call(schema, table, columns, None)
    }

    async fn synchronize_auto_increment_sequences_controlled(
        &self,
        schema: Option<&str>,
        table: &str,
        columns: &[String],
        control: &OperationControl,
    ) -> Result<(), DriverError> {
        self.sequence_call(schema, table, columns, Some(control.clone()))
    }

    async fn server_version(&self) -> Result<Option<String>, DriverError> {
        Ok(Some("marker 1.0".into()))
    }

    fn supports_server_cancellation(&self) -> bool {
        self.cancels
    }

    async fn ping(&self) -> Result<(), DriverError> {
        Err(DriverError::Disconnected)
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

#[tokio::test]
async fn the_session_returns_what_the_driver_returned_for_every_catalog_and_transaction_call() {
    let session = SessionConnection {
        inner: Arc::new(Marker {
            cancels: true,
            ..Default::default()
        }),
        _tunnel: None,
    };
    let control = OperationControl::with_timeout(Duration::from_secs(1));
    let statements = vec![("UPDATE t SET a = 1".to_string(), Vec::new())];

    assert_eq!(session.list_databases().await.unwrap(), vec!["marker_db"]);
    assert_eq!(session.list_tables().await.unwrap(), tables());
    assert_eq!(session.list_tables_controlled(&control).await.unwrap(), tables());
    assert_eq!(session.fetch_columns(None, "t").await.unwrap(), columns());
    assert_eq!(
        session.fetch_columns_controlled(None, "t", &control).await.unwrap(),
        columns()
    );
    assert_eq!(session.fetch_indexes(None, "t").await.unwrap(), indexes());
    assert_eq!(session.fetch_foreign_keys(None, "t").await.unwrap(), foreign_keys());
    assert_eq!(session.fetch_enum_labels("s", "e").await.unwrap(), vec!["marker_label"]);
    assert_eq!(
        session.fetch_enum_labels_controlled("s", "e", &control).await.unwrap(),
        vec!["marker_label"]
    );
    assert_eq!(session.execute_in_transaction(&statements).await.unwrap(), vec![7, 9]);
    assert_eq!(
        session
            .execute_in_transaction_controlled(&statements, &control)
            .await
            .unwrap(),
        vec![7, 9]
    );
    session
        .synchronize_auto_increment_sequences(None, "marker", &["id".into()])
        .await
        .unwrap();
    session
        .synchronize_auto_increment_sequences_controlled(None, "marker", &["id".into()], &control)
        .await
        .unwrap();
    assert_eq!(session.server_version().await.unwrap().as_deref(), Some("marker 1.0"));
    assert!(session.supports_server_cancellation());
    let quiet = SessionConnection {
        inner: Arc::new(Marker::default()),
        _tunnel: None,
    };
    assert!(!quiet.supports_server_cancellation());
    assert!(matches!(session.ping().await, Err(DriverError::Disconnected)));
}

#[tokio::test]
async fn sequence_synchronization_preserves_arguments_deadline_and_cancellation() {
    let marker = Arc::new(Marker::default());
    let session = SessionConnection {
        inner: marker.clone(),
        _tunnel: None,
    };
    let columns = vec!["id".to_owned(), "other_id".to_owned()];
    let control = OperationControl::with_timeout(Duration::from_secs(5));

    session
        .synchronize_auto_increment_sequences(Some("tenant"), "items", &columns)
        .await
        .unwrap();
    session
        .synchronize_auto_increment_sequences_controlled(Some("tenant"), "items", &columns, &control)
        .await
        .unwrap();

    let calls = marker.sequence_calls.lock().unwrap();
    assert_eq!(calls.len(), 2);
    for call in calls.iter() {
        assert_eq!(call.schema.as_deref(), Some("tenant"));
        assert_eq!(call.table, "items");
        assert_eq!(call.columns, columns);
    }
    assert!(calls[0].control.is_none());
    let forwarded = calls[1].control.as_ref().unwrap();
    assert_eq!(forwarded.deadline(), control.deadline());
    assert!(!forwarded.cancellation_token().is_cancelled());
    control.cancellation_token().cancel();
    assert!(forwarded.cancellation_token().is_cancelled());
}

#[tokio::test]
async fn sequence_synchronization_preserves_driver_failures() {
    let marker = Arc::new(Marker {
        sequence_failure: true,
        ..Default::default()
    });
    let session = SessionConnection {
        inner: marker.clone(),
        _tunnel: None,
    };
    let columns = vec!["id".to_owned()];
    let control = OperationControl::with_timeout(Duration::from_secs(5));

    assert!(matches!(
        session
            .synchronize_auto_increment_sequences(None, "items", &columns)
            .await,
        Err(DriverError::ReadOnly)
    ));
    assert!(matches!(
        session
            .synchronize_auto_increment_sequences_controlled(None, "items", &columns, &control)
            .await,
        Err(DriverError::ReadOnly)
    ));
    assert_eq!(marker.sequence_calls.lock().unwrap().len(), 2);
}
