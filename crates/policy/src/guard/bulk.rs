use super::*;
use crate::classify::StatementClass;
use crate::classify::classify;

/// Rows one approved import may write. A budget larger than this is
/// refused before the user is asked, so no single approval can cover an
/// unbounded amount of work.
pub const MAX_BULK_ROW_BUDGET: u64 = 1_000_000;

/// What the user is asked to approve: one INSERT shape, one table, one
/// connection and a fixed number of rows.
#[derive(Debug, Clone)]
pub struct BulkInsertRequest {
    pub schema: Option<String>,
    pub table: String,
    pub statement: String,
    pub row_budget: u64,
}

/// One bounded batch offered against an open scope. Every field is
/// checked against what the scope was granted for; a mismatch is denied.
#[derive(Debug, Clone, Copy)]
pub struct BulkBatch<'a> {
    pub schema: Option<&'a str>,
    pub table: &'a str,
    pub statement: &'a str,
    pub rows: &'a [Vec<Value>],
}

/// How an import stopped. Every import ends through exactly one of these.
#[derive(Debug, Clone, Copy)]
pub enum BulkInsertEnd<'a> {
    Completed,
    Cancelled,
    Failed(&'a DriverError),
}

/// One approval, granted once and spendable only on the connection,
/// table, statement and row count it names.
///
/// The scope is not a flag that turns policy off. It carries the identity
/// of what was approved, and every batch is checked against it. It cannot
/// be cloned or copied, it is ended by
/// [`PolicyGuard::finish_bulk_insert`], and dropping it without finishing
/// disables governed writes the same way a write whose outcome was never
/// recorded does.
pub struct BulkInsertScope {
    connection_id: Uuid,
    operation_id: Uuid,
    batch_id: Uuid,
    schema: Option<String>,
    table: String,
    statement: String,
    target: String,
    class: AuditOperationClass,
    decision_rule: String,
    approval_outcome: AuditApprovalOutcome,
    preview_state: AuditPreviewState,
    row_budget: u64,
    committed: u64,
    open: bool,
    started: Instant,
    audit_state: Arc<AuditState>,
}

struct GrantedBulkDecision {
    decision_rule: String,
    approval_outcome: AuditApprovalOutcome,
    preview_state: AuditPreviewState,
}

impl BulkInsertScope {
    pub fn committed_rows(&self) -> u64 {
        self.committed
    }

    pub fn row_budget(&self) -> u64 {
        self.row_budget
    }

    pub fn remaining_rows(&self) -> u64 {
        self.row_budget.saturating_sub(self.committed)
    }

    pub fn is_open(&self) -> bool {
        self.open
    }

    fn operation(&self) -> AuditOperation<'_> {
        AuditOperation {
            operation_id: self.operation_id,
            batch_id: Some(self.batch_id),
            sql: &self.statement,
            class: self.class,
            targets: vec![self.target.clone()],
            decision_rule: self.decision_rule.clone(),
            approval_outcome: self.approval_outcome,
            preview_state: self.preview_state.clone(),
        }
    }

    fn admit(&mut self, connection_id: Uuid, batch: &BulkBatch<'_>) -> Result<(), DriverError> {
        let verdict = self.verdict(connection_id, batch);
        if let Err(error) = verdict {
            self.open = false;
            return Err(error);
        }
        Ok(())
    }

    fn verdict(&self, connection_id: Uuid, batch: &BulkBatch<'_>) -> Result<(), DriverError> {
        if !self.open {
            return Err(denied("the import approval has already been spent or ended"));
        }
        if connection_id != self.connection_id {
            return Err(denied("the import approval was granted for another connection"));
        }
        if batch.table != self.table || batch.schema != self.schema.as_deref() {
            return Err(denied("the import approval was granted for another table"));
        }
        if batch.statement != self.statement {
            return Err(denied("the import approval was granted for another statement"));
        }
        let rows = batch.rows.len() as u64;
        if rows > self.remaining_rows() {
            return Err(denied("the import would write more rows than were approved"));
        }
        Ok(())
    }
}

/// A scope that reaches its drop still open means an import stopped
/// without a terminal audit record. That is the same hole an abandoned
/// write leaves, and it closes the same way.
impl Drop for BulkInsertScope {
    fn drop(&mut self) {
        if !self.open {
            return;
        }
        tracing::error!("an import ended without a terminal audit record; governed writes are disabled");
        self.audit_state.disable_governed_writes();
    }
}

fn denied(message: &str) -> DriverError {
    DriverError::PolicyDenied(message.to_owned())
}

fn qualified_target(schema: Option<&str>, table: &str) -> String {
    schema.map_or_else(|| table.to_owned(), |schema| format!("{schema}.{table}"))
}

fn approval_preview(target: &str, rows: u64, statement: &str) -> String {
    format!("Import {rows} rows into {target}\n\nEvery row runs this statement with its own bound values:\n{statement}")
}

impl PolicyGuard {
    /// Classify one INSERT shape, decide it once, ask for one approval when
    /// the policy requires it, and record one intent. The returned scope is
    /// the only thing that lets [`PolicyGuard::execute_bulk_batch`] run.
    pub async fn begin_bulk_insert(&self, request: BulkInsertRequest) -> Result<BulkInsertScope, DriverError> {
        self.require_governed_write_available()?;
        let facts = bulk_facts(&request, &self.ctx.driver_id)?;
        let env_policy = self
            .ctx
            .policy
            .for_connection(&self.ctx.connection_id.to_string(), self.ctx.environment);
        let decision = evaluate_with_effects(
            &self.ctx.principal,
            self.ctx.environment,
            &facts,
            self.ctx.read_only,
            &env_policy,
            Some(request.row_budget),
        );
        let granted = self.settle_bulk_decision(&request, &facts, decision).await?;
        let scope = self.new_scope(request, &facts, granted);
        self.handle_intent_failure(self.record_intent(&scope.operation()).await)?;
        Ok(scope)
    }

    /// Run one bounded batch under an open scope. The batch must name the
    /// connection, table and statement the scope was granted for, and must
    /// fit in what is left of its row budget.
    pub async fn execute_bulk_batch(
        &self,
        scope: &mut BulkInsertScope,
        batch: BulkBatch<'_>,
        control: &OperationControl,
    ) -> Result<u64, DriverError> {
        scope.admit(self.ctx.connection_id, &batch)?;
        if let Err(error) = self.require_governed_write_available().and(check_pre_dispatch(control)) {
            scope.open = false;
            return Err(error);
        }
        if batch.rows.is_empty() {
            return Ok(0);
        }
        let statements: Vec<(String, Vec<Value>)> = batch
            .rows
            .iter()
            .map(|row| (scope.statement.clone(), row.clone()))
            .collect();
        let result = self
            .caught_write(
                "BULK INSERT BATCH",
                self.inner.execute_in_transaction_controlled(&statements, control),
            )
            .await;
        if let Err(error) = result {
            scope.open = false;
            return Err(error);
        }
        let rows = statements.len() as u64;
        scope.committed += rows;
        Ok(rows)
    }

    /// End the import and write its single terminal audit record, carrying
    /// the rows that actually committed.
    pub async fn finish_bulk_insert(
        &self,
        scope: &mut BulkInsertScope,
        end: BulkInsertEnd<'_>,
    ) -> Result<u64, DriverError> {
        scope.open = false;
        let committed = scope.committed;
        let (terminal_status, transaction_outcome, error_category) = bulk_terminal(end, committed);
        let audit_result = self
            .record_outcome(
                &scope.operation(),
                AuditOutcome {
                    terminal_status,
                    transaction_outcome,
                    rows_affected: Some(committed),
                    error_category,
                    duration_ms: scope.started.elapsed().as_millis() as u64,
                },
            )
            .await;
        self.handle_write_outcome_failure(audit_result)?;
        Ok(committed)
    }

    async fn settle_bulk_decision(
        &self,
        request: &BulkInsertRequest,
        facts: &StatementFacts,
        decision: Decision,
    ) -> Result<GrantedBulkDecision, DriverError> {
        let target = qualified_target(request.schema.as_deref(), &request.table);
        match decision {
            Decision::Allow { rule } => Ok(GrantedBulkDecision {
                decision_rule: rule,
                approval_outcome: AuditApprovalOutcome::NotRequired,
                preview_state: AuditPreviewState::NotRequested,
            }),
            Decision::Deny { ref rule, ref message } => {
                self.record_bulk_refusal(request, facts, rule, AuditApprovalOutcome::NotRequired, None)
                    .await?;
                Err(denied(message))
            }
            Decision::RequireApproval { ref rule, .. } => {
                let preview = approval_preview(&target, request.row_budget, &request.statement);
                let outcome = self
                    .ctx
                    .approval
                    .request(ApprovalRequest {
                        principal: self.ctx.principal.clone(),
                        environment: self.ctx.environment,
                        connection_id: self.ctx.connection_id,
                        connection_name: self.ctx.connection_name.clone(),
                        sql: request.statement.clone(),
                        facts: facts.clone(),
                        rule: rule.clone(),
                        reason: format!("import {} rows into {target}", request.row_budget),
                        preview: Some(preview.clone()),
                        estimated_rows: Some(request.row_budget),
                        cancellation: None,
                    })
                    .await;
                if outcome == ApprovalOutcome::Deny {
                    self.record_bulk_refusal(request, facts, rule, AuditApprovalOutcome::Denied, Some(preview))
                        .await?;
                    return Err(denied("the import was not approved"));
                }
                Ok(GrantedBulkDecision {
                    decision_rule: format!("{rule}:approved"),
                    approval_outcome: AuditApprovalOutcome::Approved,
                    preview_state: AuditPreviewState::Available(preview),
                })
            }
        }
    }

    async fn record_bulk_refusal(
        &self,
        request: &BulkInsertRequest,
        facts: &StatementFacts,
        rule: &str,
        approval_outcome: AuditApprovalOutcome,
        preview: Option<String>,
    ) -> Result<(), DriverError> {
        let operation = AuditOperation {
            operation_id: Uuid::new_v4(),
            batch_id: None,
            sql: &request.statement,
            class: AuditOperationClass::from_statement(facts.class, facts.writes()),
            targets: vec![qualified_target(request.schema.as_deref(), &request.table)],
            decision_rule: rule.to_owned(),
            approval_outcome,
            preview_state: preview.map_or(AuditPreviewState::NotRequested, AuditPreviewState::Available),
        };
        let audit_result = self
            .record_outcome(
                &operation,
                AuditOutcome {
                    terminal_status: AuditTerminalStatus::Denied,
                    transaction_outcome: AuditTransactionOutcome::NotApplicable,
                    rows_affected: None,
                    error_category: Some(AuditErrorCategory::Policy),
                    duration_ms: 0,
                },
            )
            .await;
        self.handle_non_execution_audit_failure(audit_result)
    }

    fn new_scope(
        &self,
        request: BulkInsertRequest,
        facts: &StatementFacts,
        granted: GrantedBulkDecision,
    ) -> BulkInsertScope {
        BulkInsertScope {
            connection_id: self.ctx.connection_id,
            operation_id: Uuid::new_v4(),
            batch_id: Uuid::new_v4(),
            target: qualified_target(request.schema.as_deref(), &request.table),
            schema: request.schema,
            table: request.table,
            statement: request.statement,
            class: AuditOperationClass::from_statement(facts.class, facts.writes()),
            decision_rule: granted.decision_rule,
            approval_outcome: granted.approval_outcome,
            preview_state: granted.preview_state,
            row_budget: request.row_budget,
            committed: 0,
            open: true,
            started: Instant::now(),
            audit_state: self.ctx.audit_state.clone(),
        }
    }
}

fn bulk_terminal(
    end: BulkInsertEnd<'_>,
    committed: u64,
) -> (AuditTerminalStatus, AuditTransactionOutcome, Option<AuditErrorCategory>) {
    match end {
        BulkInsertEnd::Completed => (AuditTerminalStatus::Succeeded, AuditTransactionOutcome::Committed, None),
        BulkInsertEnd::Cancelled => (
            AuditTerminalStatus::Cancelled,
            partial_transaction_outcome(committed),
            Some(AuditErrorCategory::Cancelled),
        ),
        BulkInsertEnd::Failed(error) => (
            controlled_error_terminal_status(error),
            partial_transaction_outcome(committed),
            Some(error_category(error)),
        ),
    }
}

/// An import commits batch by batch, so a stopped import leaves the
/// batches that already committed in place. Reporting the whole import as
/// rolled back would hide them.
fn partial_transaction_outcome(committed: u64) -> AuditTransactionOutcome {
    if committed == 0 {
        return AuditTransactionOutcome::RolledBack;
    }
    AuditTransactionOutcome::Committed
}

fn bulk_facts(request: &BulkInsertRequest, driver_id: &str) -> Result<StatementFacts, DriverError> {
    if request.table.trim().is_empty() {
        return Err(denied("an import needs a target table"));
    }
    if request.row_budget == 0 || request.row_budget > MAX_BULK_ROW_BUDGET {
        return Err(denied("an import must name between one row and the import row limit"));
    }
    let facts = classify(&request.statement, driver_id);
    if facts.is_multi_statement || facts.class != StatementClass::Insert || !facts.writes() {
        return Err(denied(
            "an import approval covers one INSERT statement and nothing else",
        ));
    }
    Ok(facts)
}
