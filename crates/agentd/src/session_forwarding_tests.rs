use super::*;

struct Marker {
    cancels: bool,
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
        _: Option<&str>,
        _: &str,
        _: &[String],
    ) -> Result<(), DriverError> {
        Ok(())
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
        inner: Arc::new(Marker { cancels: true }),
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
        inner: Arc::new(Marker { cancels: false }),
        _tunnel: None,
    };
    assert!(!quiet.supports_server_cancellation());
    assert!(matches!(session.ping().await, Err(DriverError::Disconnected)));
}
