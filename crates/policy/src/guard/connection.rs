use super::*;

#[async_trait]
impl Connection for PolicyGuard {
    /// The guard adds policy, not a driver. Whether an interrupted
    /// operation can be stopped on the server is a property of the
    /// connection underneath, and the interface only ever holds guarded
    /// connections, so failing to forward this would report every engine
    /// as unable to cancel.
    fn supports_server_cancellation(&self) -> bool {
        self.inner.supports_server_cancellation()
    }

    async fn list_databases(&self) -> Result<Vec<String>, DriverError> {
        let operation = self.metadata_operation("LIST DATABASES", Vec::new());
        self.prepare_governed_read(&operation).await?;
        let start = Instant::now();
        let result = self.caught_read("LIST DATABASES", self.inner.list_databases()).await;
        let rows = result.as_ref().ok().map(|databases| databases.len() as u64);
        self.audit_read_result(&operation, start, &result, rows).await?;
        result
    }

    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        let operation = self.metadata_operation("LIST TABLES", Vec::new());
        self.prepare_governed_read(&operation).await?;
        let start = Instant::now();
        let result = self.caught_read("LIST TABLES", self.inner.list_tables()).await;
        let rows = result.as_ref().ok().map(|tables| tables.len() as u64);
        self.audit_read_result(&operation, start, &result, rows).await?;
        result
    }

    async fn list_tables_controlled(&self, control: &OperationControl) -> Result<Vec<TableInfo>, DriverError> {
        check_pre_dispatch(control)?;
        let operation = self.metadata_operation("LIST TABLES", Vec::new());
        self.prepare_governed_read(&operation).await?;
        let start = Instant::now();
        let result = self
            .caught_read("LIST TABLES", self.inner.list_tables_controlled(control))
            .await;
        let rows = result.as_ref().ok().map(|tables| tables.len() as u64);
        self.audit_controlled_read_result(&operation, start, &result, rows)
            .await?;
        result
    }

    async fn list_views(&self) -> Result<Vec<TableInfo>, DriverError> {
        let operation = self.metadata_operation("LIST VIEWS", Vec::new());
        self.prepare_governed_read(&operation).await?;
        let start = Instant::now();
        let result = self.caught_read("LIST VIEWS", self.inner.list_views()).await;
        let rows = result.as_ref().ok().map(|views| views.len() as u64);
        self.audit_read_result(&operation, start, &result, rows).await?;
        result
    }

    async fn list_views_controlled(&self, control: &OperationControl) -> Result<Vec<TableInfo>, DriverError> {
        check_pre_dispatch(control)?;
        let operation = self.metadata_operation("LIST VIEWS", Vec::new());
        self.prepare_governed_read(&operation).await?;
        let start = Instant::now();
        let result = self
            .caught_read("LIST VIEWS", self.inner.list_views_controlled(control))
            .await;
        let rows = result.as_ref().ok().map(|views| views.len() as u64);
        self.audit_controlled_read_result(&operation, start, &result, rows)
            .await?;
        result
    }

    async fn list_objects(
        &self,
        kind: tablepro_core::CatalogObjectKind,
        schema: Option<&str>,
    ) -> Result<Vec<tablepro_core::CatalogObject>, DriverError> {
        let operation = self.metadata_operation("LIST OBJECTS", catalog_target(kind, schema));
        self.prepare_governed_read(&operation).await?;
        let start = Instant::now();
        let result = self
            .caught_read("LIST OBJECTS", self.inner.list_objects(kind, schema))
            .await;
        let rows = result.as_ref().ok().map(|objects| objects.len() as u64);
        self.audit_read_result(&operation, start, &result, rows).await?;
        result
    }

    async fn list_objects_controlled(
        &self,
        kind: tablepro_core::CatalogObjectKind,
        schema: Option<&str>,
        control: &OperationControl,
    ) -> Result<Vec<tablepro_core::CatalogObject>, DriverError> {
        check_pre_dispatch(control)?;
        let operation = self.metadata_operation("LIST OBJECTS", catalog_target(kind, schema));
        self.prepare_governed_read(&operation).await?;
        let start = Instant::now();
        let result = self
            .caught_read(
                "LIST OBJECTS",
                self.inner.list_objects_controlled(kind, schema, control),
            )
            .await;
        let rows = result.as_ref().ok().map(|objects| objects.len() as u64);
        self.audit_controlled_read_result(&operation, start, &result, rows)
            .await?;
        result
    }

    async fn fetch_columns(&self, schema: Option<&str>, table: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        let target = schema.map_or_else(|| table.to_string(), |schema| format!("{schema}.{table}"));
        let operation = self.metadata_operation("FETCH COLUMNS", vec![target]);
        self.prepare_governed_read(&operation).await?;
        let start = Instant::now();
        let result = self
            .caught_read("FETCH COLUMNS", self.inner.fetch_columns(schema, table))
            .await;
        let rows = result.as_ref().ok().map(|columns| columns.len() as u64);
        self.audit_read_result(&operation, start, &result, rows).await?;
        result
    }

    async fn fetch_columns_controlled(
        &self,
        schema: Option<&str>,
        table: &str,
        control: &OperationControl,
    ) -> Result<Vec<ColumnInfo>, DriverError> {
        check_pre_dispatch(control)?;
        let target = schema.map_or_else(|| table.to_string(), |schema| format!("{schema}.{table}"));
        let operation = self.metadata_operation("FETCH COLUMNS", vec![target]);
        self.prepare_governed_read(&operation).await?;
        let start = Instant::now();
        let result = self
            .caught_read(
                "FETCH COLUMNS",
                self.inner.fetch_columns_controlled(schema, table, control),
            )
            .await;
        let rows = result.as_ref().ok().map(|columns| columns.len() as u64);
        self.audit_controlled_read_result(&operation, start, &result, rows)
            .await?;
        result
    }

    async fn fetch_rows(
        &self,
        schema: Option<&str>,
        table: &str,
        offset: u64,
        limit: u64,
    ) -> Result<QueryResult, DriverError> {
        let target = schema.map_or_else(|| table.to_string(), |schema| format!("{schema}.{table}"));
        let operation = self.metadata_operation("FETCH ROWS", vec![target]);
        self.prepare_governed_read(&operation).await?;
        let start = Instant::now();
        let result = self
            .caught_read("FETCH ROWS", self.inner.fetch_rows(schema, table, offset, limit))
            .await
            .map(|rows| self.mask_result(rows));
        let row_count = result.as_ref().ok().map(|rows| rows.rows.len() as u64);
        self.audit_read_result(&operation, start, &result, row_count).await?;
        result
    }

    async fn fetch_rows_controlled(
        &self,
        schema: Option<&str>,
        table: &str,
        offset: u64,
        limit: u64,
        control: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        check_pre_dispatch(control)?;
        let target = schema.map_or_else(|| table.to_string(), |schema| format!("{schema}.{table}"));
        let operation = self.metadata_operation("FETCH ROWS", vec![target]);
        self.prepare_governed_read(&operation).await?;
        let start = Instant::now();
        let result = self
            .caught_read(
                "FETCH ROWS",
                self.inner.fetch_rows_controlled(schema, table, offset, limit, control),
            )
            .await
            .map(|rows| self.mask_result(rows));
        let row_count = result.as_ref().ok().map(|rows| rows.rows.len() as u64);
        self.audit_controlled_read_result(&operation, start, &result, row_count)
            .await?;
        result
    }

    async fn query(&self, sql: &str) -> Result<QueryResult, DriverError> {
        let authorization = self.authorize(sql, false, None).await?;
        if authorization.analysis.facts.writes() {
            return self
                .execute_query_write(sql, None, authorization, |inner| inner.query(sql))
                .await;
        }
        let operation = self.operation(
            sql,
            None,
            &authorization.analysis.facts,
            &authorization.decision,
            authorization.approval_outcome,
            authorization.preview_state,
        );
        self.prepare_governed_read(&operation).await?;
        let start = Instant::now();
        let result = self
            .caught_read("QUERY", self.inner.query(sql))
            .await
            .map(|value| self.mask_result_for_analysis(Some(&authorization.analysis), value));
        let rows = result.as_ref().ok().map(|value| value.rows.len() as u64);
        self.audit_read_result(&operation, start, &result, rows).await?;
        result
    }

    async fn query_controlled(&self, sql: &str, control: &OperationControl) -> Result<QueryResult, DriverError> {
        let authorization = self.authorize(sql, false, Some(control)).await?;
        if authorization.analysis.facts.writes() {
            return self
                .execute_query_write(sql, None, authorization, |inner| inner.query_controlled(sql, control))
                .await;
        }
        let operation = self.operation(
            sql,
            None,
            &authorization.analysis.facts,
            &authorization.decision,
            authorization.approval_outcome,
            authorization.preview_state,
        );
        self.prepare_governed_read(&operation).await?;
        let start = Instant::now();
        let result = self
            .caught_read("QUERY", self.inner.query_controlled(sql, control))
            .await
            .map(|value| self.mask_result_for_analysis(Some(&authorization.analysis), value));
        let rows = result.as_ref().ok().map(|value| value.rows.len() as u64);
        self.audit_controlled_read_result(&operation, start, &result, rows)
            .await?;
        result
    }

    async fn query_params(&self, sql: &str, params: &[Value]) -> Result<QueryResult, DriverError> {
        let authorization = self.authorize(sql, true, None).await?;
        if authorization.analysis.facts.writes() {
            return self
                .execute_query_write(sql, None, authorization, |inner| inner.query_params(sql, params))
                .await;
        }
        let operation = self.operation(
            sql,
            None,
            &authorization.analysis.facts,
            &authorization.decision,
            authorization.approval_outcome,
            authorization.preview_state,
        );
        self.prepare_governed_read(&operation).await?;
        let start = Instant::now();
        let result = self
            .caught_read("QUERY PARAMS", self.inner.query_params(sql, params))
            .await
            .map(|value| self.mask_result_for_analysis(Some(&authorization.analysis), value));
        let rows = result.as_ref().ok().map(|value| value.rows.len() as u64);
        self.audit_read_result(&operation, start, &result, rows).await?;
        result
    }

    async fn query_params_controlled(
        &self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        let authorization = self.authorize(sql, true, Some(control)).await?;
        if authorization.analysis.facts.writes() {
            return self
                .execute_query_write(sql, None, authorization, |inner| {
                    inner.query_params_controlled(sql, params, control)
                })
                .await;
        }
        let operation = self.operation(
            sql,
            None,
            &authorization.analysis.facts,
            &authorization.decision,
            authorization.approval_outcome,
            authorization.preview_state,
        );
        self.prepare_governed_read(&operation).await?;
        let start = Instant::now();
        let result = self
            .caught_read("QUERY PARAMS", self.inner.query_params_controlled(sql, params, control))
            .await
            .map(|value| self.mask_result_for_analysis(Some(&authorization.analysis), value));
        let rows = result.as_ref().ok().map(|value| value.rows.len() as u64);
        self.audit_controlled_read_result(&operation, start, &result, rows)
            .await?;
        result
    }

    async fn query_result_sets_controlled(
        &self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResultBatch, DriverError> {
        let authorization = self.authorize(sql, true, Some(control)).await?;
        let operation = self.operation(
            sql,
            None,
            &authorization.analysis.facts,
            &authorization.decision,
            authorization.approval_outcome,
            authorization.preview_state,
        );
        let start = Instant::now();
        if authorization.analysis.facts.writes() {
            self.require_governed_write_available()?;
            self.handle_intent_failure(self.record_intent(&operation).await)?;
            let mut pending_write = self.ctx.audit_state.pending_write();
            let result = self
                .caught_write(
                    "a write statement",
                    self.inner.query_result_sets_controlled(sql, params, control),
                )
                .await
                .map(|batch| self.mask_result_batch_for_analysis(&authorization.analysis, batch));
            let rows = result.as_ref().ok().map(QueryResultBatch::retained_rows);
            self.audit_write_result(&operation, start, &result, rows).await?;
            pending_write.disarm();
            return result;
        }

        self.prepare_governed_read(&operation).await?;
        let result = self
            .caught_read(
                "QUERY RESULT SETS",
                self.inner.query_result_sets_controlled(sql, params, control),
            )
            .await
            .map(|batch| self.mask_result_batch_for_analysis(&authorization.analysis, batch));
        let rows = result.as_ref().ok().map(QueryResultBatch::retained_rows);
        self.audit_controlled_read_result(&operation, start, &result, rows)
            .await?;
        result
    }

    async fn execute(&self, sql: &str) -> Result<ExecResult, DriverError> {
        let authorization = self.authorize(sql, false, None).await?;
        self.execute_write(sql, None, authorization, |inner| inner.execute(sql))
            .await
    }

    async fn execute_controlled(&self, sql: &str, control: &OperationControl) -> Result<ExecResult, DriverError> {
        let authorization = self.authorize(sql, false, Some(control)).await?;
        self.execute_write(sql, None, authorization, |inner| inner.execute_controlled(sql, control))
            .await
    }

    async fn execute_params(&self, sql: &str, params: &[Value]) -> Result<ExecResult, DriverError> {
        let authorization = self.authorize(sql, true, None).await?;
        self.execute_write(sql, None, authorization, |inner| inner.execute_params(sql, params))
            .await
    }

    async fn execute_params_controlled(
        &self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<ExecResult, DriverError> {
        let authorization = self.authorize(sql, true, Some(control)).await?;
        self.execute_write(sql, None, authorization, |inner| {
            inner.execute_params_controlled(sql, params, control)
        })
        .await
    }

    async fn execute_in_transaction(&self, statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        let combined = statements
            .iter()
            .map(|(sql, _)| sql.trim().trim_end_matches(';'))
            .collect::<Vec<_>>()
            .join(";\n");
        let authorization = self.authorize(&combined, true, None).await?;
        self.require_governed_write_available()?;
        let batch_id = Uuid::new_v4();
        let operation = self.operation(
            &combined,
            Some(batch_id),
            &authorization.analysis.facts,
            &authorization.decision,
            authorization.approval_outcome,
            authorization.preview_state,
        );
        self.handle_intent_failure(self.record_intent(&operation).await)?;
        let mut pending_write = self.ctx.audit_state.pending_write();
        let start = Instant::now();
        let result = self
            .caught_write("EXECUTE IN TRANSACTION", self.inner.execute_in_transaction(statements))
            .await;
        let rows = result.as_ref().ok().map(|values| values.iter().sum());
        self.audit_transaction_result(&operation, start, &result, rows).await?;
        pending_write.disarm();
        result
    }

    async fn execute_in_transaction_checked(
        &self,
        statements: &[(String, Vec<Value>)],
        expect_one: &[usize],
    ) -> Result<Vec<u64>, DriverError> {
        if expect_one.is_empty() {
            return self.execute_in_transaction(statements).await;
        }
        let combined = statements
            .iter()
            .map(|(sql, _)| sql.trim().trim_end_matches(';'))
            .collect::<Vec<_>>()
            .join(";\n");
        let analysis = self.analyze_statement(&combined);
        let enforced_rows = self.enforced_batch_rows(&analysis, expect_one);
        let authorization = self
            .authorize_analysis(&combined, analysis, enforced_rows, None)
            .await?;
        self.require_governed_write_available()?;
        let operation = self.operation(
            &combined,
            Some(Uuid::new_v4()),
            &authorization.analysis.facts,
            &authorization.decision,
            authorization.approval_outcome,
            authorization.preview_state,
        );
        self.handle_intent_failure(self.record_intent(&operation).await)?;
        let mut pending_write = self.ctx.audit_state.pending_write();
        let start = Instant::now();
        let result = self
            .caught_write(
                "EXECUTE CHECKED TRANSACTION",
                self.inner.execute_in_transaction_checked(statements, expect_one),
            )
            .await;
        let rows = result.as_ref().ok().map(|values| values.iter().sum());
        self.audit_transaction_result(&operation, start, &result, rows).await?;
        pending_write.disarm();
        result
    }

    async fn fetch_indexes(&self, schema: Option<&str>, table: &str) -> Result<Vec<IndexInfo>, DriverError> {
        let target = schema.map_or_else(|| table.to_string(), |schema| format!("{schema}.{table}"));
        let operation = self.metadata_operation("FETCH INDEXES", vec![target]);
        self.prepare_governed_read(&operation).await?;
        let start = Instant::now();
        let result = self
            .caught_read("FETCH INDEXES", self.inner.fetch_indexes(schema, table))
            .await;
        let rows = result.as_ref().ok().map(|indexes| indexes.len() as u64);
        self.audit_read_result(&operation, start, &result, rows).await?;
        result
    }

    async fn fetch_indexes_controlled(
        &self,
        schema: Option<&str>,
        table: &str,
        control: &OperationControl,
    ) -> Result<Vec<IndexInfo>, DriverError> {
        check_pre_dispatch(control)?;
        let target = schema.map_or_else(|| table.to_string(), |schema| format!("{schema}.{table}"));
        let operation = self.metadata_operation("FETCH INDEXES", vec![target]);
        self.prepare_governed_read(&operation).await?;
        let start = Instant::now();
        let result = self
            .caught_read(
                "FETCH INDEXES",
                self.inner.fetch_indexes_controlled(schema, table, control),
            )
            .await;
        let rows = result.as_ref().ok().map(|indexes| indexes.len() as u64);
        self.audit_controlled_read_result(&operation, start, &result, rows)
            .await?;
        result
    }

    async fn fetch_foreign_keys(&self, schema: Option<&str>, table: &str) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        let target = schema.map_or_else(|| table.to_string(), |schema| format!("{schema}.{table}"));
        let operation = self.metadata_operation("FETCH FOREIGN KEYS", vec![target]);
        self.prepare_governed_read(&operation).await?;
        let start = Instant::now();
        let result = self
            .caught_read("FETCH FOREIGN KEYS", self.inner.fetch_foreign_keys(schema, table))
            .await;
        let rows = result.as_ref().ok().map(|keys| keys.len() as u64);
        self.audit_read_result(&operation, start, &result, rows).await?;
        result
    }

    async fn fetch_foreign_keys_controlled(
        &self,
        schema: Option<&str>,
        table: &str,
        control: &OperationControl,
    ) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        check_pre_dispatch(control)?;
        let target = schema.map_or_else(|| table.to_string(), |schema| format!("{schema}.{table}"));
        let operation = self.metadata_operation("FETCH FOREIGN KEYS", vec![target]);
        self.prepare_governed_read(&operation).await?;
        let start = Instant::now();
        let result = self
            .caught_read(
                "FETCH FOREIGN KEYS",
                self.inner.fetch_foreign_keys_controlled(schema, table, control),
            )
            .await;
        let rows = result.as_ref().ok().map(|keys| keys.len() as u64);
        self.audit_controlled_read_result(&operation, start, &result, rows)
            .await?;
        result
    }

    async fn open_session(&self) -> Result<Box<dyn tablepro_core::Session>, DriverError> {
        let inner = self.caught_read("OPEN SESSION", self.inner.open_session()).await?;
        Ok(self.wrap_session(inner))
    }

    async fn begin(&self) -> Result<Box<dyn Transaction>, DriverError> {
        let inner = self.caught_write("BEGIN", self.inner.begin()).await?;
        Ok(Box::new(PolicyTransaction {
            guard: self.clone(),
            inner,
            batch_id: Uuid::new_v4(),
        }))
    }

    async fn server_version(&self) -> Result<Option<String>, DriverError> {
        let operation = self.metadata_operation("SERVER VERSION", Vec::new());
        self.prepare_governed_read(&operation).await?;
        let start = Instant::now();
        let result = self.caught_read("SERVER VERSION", self.inner.server_version()).await;
        self.audit_read_result(&operation, start, &result, None).await?;
        result
    }

    async fn ping(&self) -> Result<(), DriverError> {
        self.caught_read("PING", self.inner.ping()).await
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

impl PolicyGuard {
    async fn execute_write<'a, F, Fut>(
        &'a self,
        sql: &'a str,
        batch_id: Option<Uuid>,
        authorization: Authorization,
        execute: F,
    ) -> Result<ExecResult, DriverError>
    where
        F: FnOnce(&'a Arc<dyn Connection>) -> Fut,
        Fut: std::future::Future<Output = Result<ExecResult, DriverError>>,
    {
        self.require_governed_write_available()?;
        let operation = self.operation(
            sql,
            batch_id,
            &authorization.analysis.facts,
            &authorization.decision,
            authorization.approval_outcome,
            authorization.preview_state,
        );
        self.handle_intent_failure(self.record_intent(&operation).await)?;
        let mut pending_write = self.ctx.audit_state.pending_write();
        let start = Instant::now();
        let result = self.caught_write("a write statement", execute(&self.inner)).await;
        let rows = result.as_ref().ok().map(|value| value.rows_affected);
        self.audit_write_result(&operation, start, &result, rows).await?;
        pending_write.disarm();
        result
    }

    async fn execute_query_write<'a, F, Fut>(
        &'a self,
        sql: &'a str,
        batch_id: Option<Uuid>,
        authorization: Authorization,
        execute: F,
    ) -> Result<QueryResult, DriverError>
    where
        F: FnOnce(&'a Arc<dyn Connection>) -> Fut,
        Fut: std::future::Future<Output = Result<QueryResult, DriverError>>,
    {
        self.require_governed_write_available()?;
        let operation = self.operation(
            sql,
            batch_id,
            &authorization.analysis.facts,
            &authorization.decision,
            authorization.approval_outcome,
            authorization.preview_state,
        );
        self.handle_intent_failure(self.record_intent(&operation).await)?;
        let mut pending_write = self.ctx.audit_state.pending_write();
        let start = Instant::now();
        let result = self
            .caught_write("a write statement", execute(&self.inner))
            .await
            .map(|value| self.mask_result_for_analysis(Some(&authorization.analysis), value));
        let rows = result.as_ref().ok().map(|value| value.rows.len() as u64);
        self.audit_write_result(&operation, start, &result, rows).await?;
        pending_write.disarm();
        result
    }
}

async fn run_transaction_query<F>(
    guard: &PolicyGuard,
    batch_id: Uuid,
    sql: &str,
    authorization: Authorization,
    operation_name: &'static str,
    execution: F,
) -> Result<QueryResult, DriverError>
where
    F: std::future::Future<Output = Result<QueryResult, DriverError>> + Send,
{
    let operation = guard.operation(
        sql,
        Some(batch_id),
        &authorization.analysis.facts,
        &authorization.decision,
        authorization.approval_outcome,
        authorization.preview_state,
    );
    if authorization.analysis.facts.writes() {
        guard.require_governed_write_available()?;
        guard.handle_intent_failure(guard.record_intent(&operation).await)?;
        let mut pending_write = guard.ctx.audit_state.pending_write();
        let start = Instant::now();
        let result = guard
            .caught_write(operation_name, execution)
            .await
            .map(|value| guard.mask_result_for_analysis(Some(&authorization.analysis), value));
        let rows = result.as_ref().ok().map(|value| value.rows.len() as u64);
        guard.audit_transaction_result(&operation, start, &result, rows).await?;
        pending_write.disarm();
        return result;
    }
    guard.prepare_governed_read(&operation).await?;
    let start = Instant::now();
    let result = guard
        .caught_read(operation_name, execution)
        .await
        .map(|value| guard.mask_result_for_analysis(Some(&authorization.analysis), value));
    let rows = result.as_ref().ok().map(|value| value.rows.len() as u64);
    guard.audit_transaction_result(&operation, start, &result, rows).await?;
    result
}

#[async_trait]
impl Transaction for PolicyTransaction {
    async fn query(&mut self, sql: &str) -> Result<QueryResult, DriverError> {
        let authorization = self.guard.authorize(sql, false, None).await?;
        run_transaction_query(
            &self.guard,
            self.batch_id,
            sql,
            authorization,
            "QUERY",
            self.inner.query(sql),
        )
        .await
    }

    async fn query_controlled(&mut self, sql: &str, control: &OperationControl) -> Result<QueryResult, DriverError> {
        let authorization = self.guard.authorize(sql, false, Some(control)).await?;
        run_transaction_query(
            &self.guard,
            self.batch_id,
            sql,
            authorization,
            "QUERY",
            self.inner.query_controlled(sql, control),
        )
        .await
    }

    async fn query_params(&mut self, sql: &str, params: &[Value]) -> Result<QueryResult, DriverError> {
        let authorization = self.guard.authorize(sql, true, None).await?;
        run_transaction_query(
            &self.guard,
            self.batch_id,
            sql,
            authorization,
            "QUERY PARAMS",
            self.inner.query_params(sql, params),
        )
        .await
    }

    async fn query_params_controlled(
        &mut self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        let authorization = self.guard.authorize(sql, true, Some(control)).await?;
        run_transaction_query(
            &self.guard,
            self.batch_id,
            sql,
            authorization,
            "QUERY PARAMS",
            self.inner.query_params_controlled(sql, params, control),
        )
        .await
    }

    async fn execute(&mut self, sql: &str) -> Result<ExecResult, DriverError> {
        let authorization = self.guard.authorize(sql, false, None).await?;
        self.guard.require_governed_write_available()?;
        let operation = self.guard.operation(
            sql,
            Some(self.batch_id),
            &authorization.analysis.facts,
            &authorization.decision,
            authorization.approval_outcome,
            authorization.preview_state,
        );
        self.guard
            .handle_intent_failure(self.guard.record_intent(&operation).await)?;
        let mut pending_write = self.guard.ctx.audit_state.pending_write();
        let start = Instant::now();
        let result = self.guard.caught_write("EXECUTE", self.inner.execute(sql)).await;
        let rows = result.as_ref().ok().map(|value| value.rows_affected);
        self.guard
            .audit_transaction_result(&operation, start, &result, rows)
            .await?;
        pending_write.disarm();
        result
    }

    async fn execute_controlled(&mut self, sql: &str, control: &OperationControl) -> Result<ExecResult, DriverError> {
        let authorization = self.guard.authorize(sql, false, Some(control)).await?;
        self.guard.require_governed_write_available()?;
        let operation = self.guard.operation(
            sql,
            Some(self.batch_id),
            &authorization.analysis.facts,
            &authorization.decision,
            authorization.approval_outcome,
            authorization.preview_state,
        );
        self.guard
            .handle_intent_failure(self.guard.record_intent(&operation).await)?;
        let mut pending_write = self.guard.ctx.audit_state.pending_write();
        let start = Instant::now();
        let result = self
            .guard
            .caught_write("EXECUTE", self.inner.execute_controlled(sql, control))
            .await;
        let rows = result.as_ref().ok().map(|value| value.rows_affected);
        self.guard
            .audit_transaction_result(&operation, start, &result, rows)
            .await?;
        pending_write.disarm();
        result
    }

    async fn execute_params(&mut self, sql: &str, params: &[Value]) -> Result<ExecResult, DriverError> {
        let authorization = self.guard.authorize(sql, true, None).await?;
        self.guard.require_governed_write_available()?;
        let operation = self.guard.operation(
            sql,
            Some(self.batch_id),
            &authorization.analysis.facts,
            &authorization.decision,
            authorization.approval_outcome,
            authorization.preview_state,
        );
        self.guard
            .handle_intent_failure(self.guard.record_intent(&operation).await)?;
        let mut pending_write = self.guard.ctx.audit_state.pending_write();
        let start = Instant::now();
        let result = self
            .guard
            .caught_write("EXECUTE PARAMS", self.inner.execute_params(sql, params))
            .await;
        let rows = result.as_ref().ok().map(|value| value.rows_affected);
        self.guard
            .audit_transaction_result(&operation, start, &result, rows)
            .await?;
        pending_write.disarm();
        result
    }

    async fn execute_params_controlled(
        &mut self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<ExecResult, DriverError> {
        let authorization = self.guard.authorize(sql, true, Some(control)).await?;
        self.guard.require_governed_write_available()?;
        let operation = self.guard.operation(
            sql,
            Some(self.batch_id),
            &authorization.analysis.facts,
            &authorization.decision,
            authorization.approval_outcome,
            authorization.preview_state,
        );
        self.guard
            .handle_intent_failure(self.guard.record_intent(&operation).await)?;
        let mut pending_write = self.guard.ctx.audit_state.pending_write();
        let start = Instant::now();
        let result = self
            .guard
            .caught_write(
                "EXECUTE PARAMS",
                self.inner.execute_params_controlled(sql, params, control),
            )
            .await;
        let rows = result.as_ref().ok().map(|value| value.rows_affected);
        self.guard
            .audit_transaction_result(&operation, start, &result, rows)
            .await?;
        pending_write.disarm();
        result
    }

    async fn commit(self: Box<Self>) -> Result<(), DriverError> {
        self.guard.require_governed_write_available()?;
        let operation = PolicyGuard::commit_operation(self.batch_id);
        self.guard.record_intent(&operation).await.map_err(|error| {
            DriverError::PolicyDenied(format!(
                "commit denied because audit intent could not be persisted: {error}"
            ))
        })?;
        let mut pending_write = self.guard.ctx.audit_state.pending_write();
        let start = Instant::now();
        let result = self.guard.caught_write("COMMIT", self.inner.commit()).await;
        let (status, transaction_outcome, category) = match &result {
            Ok(()) => (AuditTerminalStatus::Succeeded, AuditTransactionOutcome::Committed, None),
            Err(error) if is_ambiguous_post_dispatch(error) => {
                self.guard.ctx.audit_state.disable_governed_writes();
                (
                    AuditTerminalStatus::Unknown,
                    AuditTransactionOutcome::Unknown,
                    Some(error_category(error)),
                )
            }
            Err(error) => (
                AuditTerminalStatus::Failed,
                AuditTransactionOutcome::Failed,
                Some(error_category(error)),
            ),
        };
        let audit_result = self
            .guard
            .record_outcome(
                &operation,
                AuditOutcome {
                    terminal_status: status,
                    transaction_outcome,
                    rows_affected: None,
                    error_category: category,
                    duration_ms: start.elapsed().as_millis() as u64,
                },
            )
            .await;
        self.guard.handle_write_outcome_failure(audit_result)?;
        pending_write.disarm();
        result
    }

    async fn rollback(self: Box<Self>) -> Result<(), DriverError> {
        let operation = AuditOperation {
            operation_id: Uuid::new_v4(),
            batch_id: Some(self.batch_id),
            sql: "ROLLBACK",
            class: AuditOperationClass::TransactionRollback,
            targets: Vec::new(),
            decision_rule: "transaction_rollback".into(),
            approval_outcome: AuditApprovalOutcome::NotRequired,
            preview_state: AuditPreviewState::NotRequested,
        };
        self.guard.record_intent(&operation).await.map_err(|error| {
            DriverError::PolicyDenied(format!(
                "rollback denied because audit intent could not be persisted: {error}"
            ))
        })?;
        let mut pending_write = self.guard.ctx.audit_state.pending_write();
        let start = Instant::now();
        let result = self.guard.caught_write("ROLLBACK", self.inner.rollback()).await;
        let (status, transaction_outcome, category) = match &result {
            Ok(()) => (
                AuditTerminalStatus::Succeeded,
                AuditTransactionOutcome::RolledBack,
                None,
            ),
            Err(error) if is_ambiguous_post_dispatch(error) => {
                self.guard.ctx.audit_state.disable_governed_writes();
                (
                    AuditTerminalStatus::Unknown,
                    AuditTransactionOutcome::Unknown,
                    Some(error_category(error)),
                )
            }
            Err(error) => (
                AuditTerminalStatus::Failed,
                AuditTransactionOutcome::Failed,
                Some(error_category(error)),
            ),
        };
        let audit_result = self
            .guard
            .record_outcome(
                &operation,
                AuditOutcome {
                    terminal_status: status,
                    transaction_outcome,
                    rows_affected: None,
                    error_category: category,
                    duration_ms: start.elapsed().as_millis() as u64,
                },
            )
            .await;
        self.guard.handle_write_outcome_failure(audit_result)?;
        pending_write.disarm();
        result
    }

    async fn rollback_controlled(self: Box<Self>, control: &OperationControl) -> Result<(), DriverError> {
        let operation = AuditOperation {
            operation_id: Uuid::new_v4(),
            batch_id: Some(self.batch_id),
            sql: "ROLLBACK",
            class: AuditOperationClass::TransactionRollback,
            targets: Vec::new(),
            decision_rule: "transaction_rollback".into(),
            approval_outcome: AuditApprovalOutcome::NotRequired,
            preview_state: AuditPreviewState::NotRequested,
        };
        self.guard.record_intent(&operation).await.map_err(|error| {
            DriverError::PolicyDenied(format!(
                "rollback denied because audit intent could not be persisted: {error}"
            ))
        })?;
        let mut pending_write = self.guard.ctx.audit_state.pending_write();
        let start = Instant::now();
        let result = self
            .guard
            .caught_write("ROLLBACK", self.inner.rollback_controlled(control))
            .await;
        let (status, transaction_outcome, category) = match &result {
            Ok(()) => (
                AuditTerminalStatus::Succeeded,
                AuditTransactionOutcome::RolledBack,
                None,
            ),
            Err(error) => {
                self.guard.ctx.audit_state.disable_governed_writes();
                (
                    AuditTerminalStatus::Unknown,
                    AuditTransactionOutcome::Unknown,
                    Some(error_category(error)),
                )
            }
        };
        let audit_result = self
            .guard
            .record_outcome(
                &operation,
                AuditOutcome {
                    terminal_status: status,
                    transaction_outcome,
                    rows_affected: None,
                    error_category: category,
                    duration_ms: start.elapsed().as_millis() as u64,
                },
            )
            .await;
        self.guard.handle_write_outcome_failure(audit_result)?;
        pending_write.disarm();
        result
    }
}
