use super::*;
use std::sync::atomic::{AtomicBool, Ordering};

struct ViewConnection {
    fail: bool,
    controlled: Arc<AtomicBool>,
}
#[async_trait]
impl Connection for ViewConnection {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        Err(DriverError::Unsupported("unused test operation".into()))
    }

    async fn list_views(&self) -> Result<Vec<TableInfo>, DriverError> {
        if self.fail {
            return Err(DriverError::Disconnected);
        }
        Ok(vec![TableInfo {
            schema: Some("public".into()),
            name: "recent_orders".into(),
        }])
    }
    async fn list_views_controlled(&self, control: &OperationControl) -> Result<Vec<TableInfo>, DriverError> {
        tablepro_core::check_pre_dispatch(control)?;
        self.controlled.store(true, std::sync::atomic::Ordering::SeqCst);
        self.list_views().await
    }

    async fn list_objects(
        &self,
        kind: tablepro_core::CatalogObjectKind,
        schema: Option<&str>,
    ) -> Result<Vec<tablepro_core::CatalogObject>, DriverError> {
        if self.fail {
            return Err(DriverError::Disconnected);
        }
        Ok(vec![tablepro_core::CatalogObject {
            kind,
            schema: schema.map(str::to_string),
            name: "audit_row".into(),
            detail: None,
        }])
    }

    async fn list_objects_controlled(
        &self,
        kind: tablepro_core::CatalogObjectKind,
        schema: Option<&str>,
        control: &OperationControl,
    ) -> Result<Vec<tablepro_core::CatalogObject>, DriverError> {
        tablepro_core::check_pre_dispatch(control)?;
        self.controlled.store(true, std::sync::atomic::Ordering::SeqCst);
        self.list_objects(kind, schema).await
    }

    async fn fetch_columns(&self, _schema: Option<&str>, _table: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        Err(DriverError::Unsupported("unused test operation".into()))
    }

    async fn fetch_indexes(&self, _schema: Option<&str>, _table: &str) -> Result<Vec<IndexInfo>, DriverError> {
        Err(DriverError::Unsupported("unused test operation".into()))
    }

    async fn fetch_indexes_controlled(
        &self,
        schema: Option<&str>,
        table: &str,
        control: &OperationControl,
    ) -> Result<Vec<IndexInfo>, DriverError> {
        tablepro_core::check_pre_dispatch(control)?;
        assert_eq!((schema, table), (Some("public"), "orders"));
        self.controlled.store(true, Ordering::SeqCst);
        if self.fail {
            Err(DriverError::Disconnected)
        } else {
            Ok(Vec::new())
        }
    }

    async fn fetch_foreign_keys(
        &self,
        _schema: Option<&str>,
        _table: &str,
    ) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        Err(DriverError::Unsupported("unused test operation".into()))
    }

    async fn fetch_foreign_keys_controlled(
        &self,
        schema: Option<&str>,
        table: &str,
        control: &OperationControl,
    ) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        tablepro_core::check_pre_dispatch(control)?;
        assert_eq!((schema, table), (Some("public"), "orders"));
        self.controlled.store(true, Ordering::SeqCst);
        if self.fail {
            Err(DriverError::Disconnected)
        } else {
            Ok(Vec::new())
        }
    }

    async fn fetch_rows(
        &self,
        _schema: Option<&str>,
        _table: &str,
        _offset: u64,
        _limit: u64,
    ) -> Result<QueryResult, DriverError> {
        Err(DriverError::Unsupported("unused test operation".into()))
    }

    async fn query(&self, _sql: &str) -> Result<QueryResult, DriverError> {
        Err(DriverError::Unsupported("unused test operation".into()))
    }

    async fn execute(&self, _sql: &str) -> Result<ExecResult, DriverError> {
        Err(DriverError::Unsupported("unused test operation".into()))
    }

    async fn execute_params(&self, _sql: &str, _params: &[Value]) -> Result<ExecResult, DriverError> {
        Err(DriverError::Unsupported("unused test operation".into()))
    }

    async fn execute_in_transaction(&self, _statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        Err(DriverError::Unsupported("unused test operation".into()))
    }

    async fn ping(&self) -> Result<(), DriverError> {
        Ok(())
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

#[tokio::test]
async fn session_preserves_views_errors_and_controlled_dispatch() {
    for fail in [false, true] {
        let controlled = Arc::new(AtomicBool::new(false));
        let session = SessionConnection {
            inner: Arc::new(ViewConnection {
                fail,
                controlled: controlled.clone(),
            }),
            _tunnel: None,
        };
        let control = OperationControl::with_timeout(Duration::from_secs(1));
        let ordinary = session.list_views().await;
        let bounded = session.list_views_controlled(&control).await;
        assert!(controlled.load(Ordering::SeqCst));
        if fail {
            assert!(matches!(ordinary, Err(DriverError::Disconnected)));
            assert!(matches!(bounded, Err(DriverError::Disconnected)));
        } else {
            let expected = vec![TableInfo {
                schema: Some("public".into()),
                name: "recent_orders".into(),
            }];
            assert_eq!(ordinary.unwrap(), expected);
            assert_eq!(bounded.unwrap(), expected);
        }
        controlled.store(false, Ordering::SeqCst);
        control.cancellation_token().cancel();
        assert!(matches!(
            session.list_views_controlled(&control).await,
            Err(DriverError::Cancelled)
        ));
        assert!(!controlled.load(Ordering::SeqCst));
    }
}

#[tokio::test]
async fn session_forwards_catalog_listing_errors_and_controlled_dispatch() {
    for fail in [false, true] {
        let controlled = Arc::new(AtomicBool::new(false));
        let session = SessionConnection {
            inner: Arc::new(ViewConnection {
                fail,
                controlled: controlled.clone(),
            }),
            _tunnel: None,
        };
        let kind = tablepro_core::CatalogObjectKind::Trigger;
        let control = OperationControl::with_timeout(Duration::from_secs(1));
        let ordinary = session.list_objects(kind, Some("public")).await;
        let bounded = session.list_objects_controlled(kind, Some("public"), &control).await;
        assert!(controlled.load(Ordering::SeqCst));
        if fail {
            assert!(matches!(ordinary, Err(DriverError::Disconnected)));
            assert!(matches!(bounded, Err(DriverError::Disconnected)));
        } else {
            let names: Vec<String> = bounded.unwrap().into_iter().map(|object| object.name).collect();
            assert_eq!(names, vec!["audit_row".to_string()]);
            assert_eq!(ordinary.unwrap()[0].schema.as_deref(), Some("public"));
        }
    }
}

#[tokio::test]
async fn session_preserves_controlled_constraint_metadata() {
    for fail in [false, true] {
        let controlled = Arc::new(AtomicBool::new(false));
        let session = SessionConnection {
            inner: Arc::new(ViewConnection {
                fail,
                controlled: controlled.clone(),
            }),
            _tunnel: None,
        };
        let control = OperationControl::with_timeout(Duration::from_secs(1));
        let indexes = session
            .fetch_indexes_controlled(Some("public"), "orders", &control)
            .await;
        assert!(
            controlled.swap(false, Ordering::SeqCst),
            "index control was not forwarded"
        );
        let keys = session
            .fetch_foreign_keys_controlled(Some("public"), "orders", &control)
            .await;
        assert!(
            controlled.swap(false, Ordering::SeqCst),
            "foreign-key control was not forwarded"
        );
        if fail {
            assert!(matches!(indexes, Err(DriverError::Disconnected)));
            assert!(matches!(keys, Err(DriverError::Disconnected)));
        } else {
            assert!(indexes.unwrap().is_empty());
            assert!(keys.unwrap().is_empty());
        }
        control.cancellation_token().cancel();
        assert!(matches!(
            session
                .fetch_indexes_controlled(Some("public"), "orders", &control)
                .await,
            Err(DriverError::Cancelled)
        ));
        assert!(matches!(
            session
                .fetch_foreign_keys_controlled(Some("public"), "orders", &control)
                .await,
            Err(DriverError::Cancelled)
        ));
        assert!(!controlled.load(Ordering::SeqCst));
    }
}
