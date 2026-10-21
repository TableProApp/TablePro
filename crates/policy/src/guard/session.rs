use std::cell::Cell;

use tablepro_core::{QueryCursorId, QueryCursorPage, QueryResultBatch, Session, SessionCommitOutcome};

use super::*;
use crate::transaction_control::{TransactionControl, hides_transaction_control, transaction_control};

const CLOSE_ROLLBACK_TIMEOUT: Duration = Duration::from_secs(10);
const CLOSE_CURSOR_TIMEOUT: Duration = Duration::from_secs(5);

mod refusal;

pub(crate) struct PolicySession {
    guard: PolicyGuard,
    inner: Box<dyn Session>,
    batch: Option<OpenBatch>,
    cursor: Option<ActiveCursor>,
    retired: Cell<bool>,
    extra: ExtraSets,
}

struct ActiveCursor {
    id: QueryCursorId,
    audit: CursorAudit,
    complete: bool,
}

struct CursorAudit {
    operation_id: Uuid,
    batch_id: Uuid,
    sql: String,
    targets: Vec<String>,
    decision_rule: String,
    approval_outcome: AuditApprovalOutcome,
    preview_state: AuditPreviewState,
    analysis: crate::classify::StatementAnalysis,
}

impl CursorAudit {
    fn operation(&self) -> AuditOperation<'_> {
        AuditOperation {
            operation_id: self.operation_id,
            batch_id: Some(self.batch_id),
            sql: &self.sql,
            class: AuditOperationClass::Read,
            targets: self.targets.clone(),
            decision_rule: self.decision_rule.clone(),
            approval_outcome: self.approval_outcome,
            preview_state: self.preview_state.clone(),
        }
    }
}

#[derive(Default)]
struct ExtraSets {
    collect: bool,
    sets: Vec<QueryResult>,
}

async fn inner_statement(
    inner: &mut Box<dyn Session>,
    extra: &mut ExtraSets,
    guard: &PolicyGuard,
    analysis: &crate::classify::StatementAnalysis,
    sql: &str,
    params: &[Value],
    control: &OperationControl,
) -> Result<QueryResult, DriverError> {
    if !extra.collect {
        return inner.query_params_controlled(sql, params, control).await;
    }
    let batch = inner.query_result_sets_params_controlled(sql, params, control).await?;
    let truncated = batch.truncated;
    let mut sets = batch.result_sets.into_iter();
    let mut first = sets.next().unwrap_or(QueryResult {
        columns: Vec::new(),
        rows: Vec::new(),
        truncated,
    });
    first.truncated |= truncated;
    extra
        .sets
        .extend(sets.map(|set| guard.mask_result_for_analysis(Some(analysis), set)));
    Ok(first)
}

fn rows_in(first: &QueryResult, extra_sets: &[QueryResult]) -> u64 {
    first.rows.len() as u64 + extra_sets.iter().map(|set| set.rows.len() as u64).sum::<u64>()
}

#[derive(Clone, Copy)]
struct OpenBatch {
    id: Uuid,
    read_only: bool,
    wrote: bool,
    uncertain: bool,
    aborted: bool,
}

impl OpenBatch {
    fn new(read_only: bool) -> Self {
        Self {
            id: Uuid::new_v4(),
            read_only,
            wrote: false,
            uncertain: false,
            aborted: false,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Finish {
    Commit,
    Rollback,
}

impl PolicyGuard {
    pub(super) fn wrap_session(&self, inner: Box<dyn Session>) -> Box<dyn Session> {
        Box::new(PolicySession {
            guard: self.clone(),
            inner,
            batch: None,
            cursor: None,
            retired: Cell::new(false),
            extra: ExtraSets::default(),
        })
    }
}

#[async_trait]
impl Session for PolicySession {
    async fn query_params_controlled(
        &mut self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        self.require_query_ready(sql).await?;
        match transaction_control(sql, &self.guard.ctx.driver_id) {
            Some(TransactionControl::BeginReadWrite) if self.guard.ctx.read_only => {
                self.refuse_policy(
                    sql,
                    "connection_read_only",
                    "read-write transactions are not allowed on a read-only connection",
                )
                .await
            }
            Some(TransactionControl::Begin | TransactionControl::BeginReadWrite) => self.begin(sql, control).await,
            Some(TransactionControl::BeginReadOnly) => {
                self.refuse_policy(
                    sql,
                    "snapshot_isolation",
                    "read-only sessions require REPEATABLE READ or SERIALIZABLE isolation",
                )
                .await
            }
            Some(TransactionControl::BeginReadOnlySnapshot) => self.begin_read_only(sql, control).await,
            Some(TransactionControl::Commit { chain }) => self
                .finish(sql, control, Finish::Commit, chain)
                .await
                .map(|(result, _)| result),
            Some(TransactionControl::Rollback { chain }) => self
                .finish(sql, control, Finish::Rollback, chain)
                .await
                .map(|(result, _)| result),
            None if hides_transaction_control(sql, &self.guard.ctx.driver_id) => {
                self.refuse_policy(
                    sql,
                    "hidden_transaction_control",
                    "send BEGIN, COMMIT and ROLLBACK as separate statements so the session can track the transaction",
                )
                .await
            }
            None => self.statement(sql, params, control).await,
        }
    }

    async fn commit_controlled(&mut self, control: &OperationControl) -> Result<SessionCommitOutcome, DriverError> {
        self.require_query_ready("COMMIT").await?;
        let (_, outcome) = self.finish("COMMIT", control, Finish::Commit, false).await?;
        match outcome {
            AuditTransactionOutcome::Committed => Ok(SessionCommitOutcome::Committed),
            AuditTransactionOutcome::RolledBack => Ok(SessionCommitOutcome::RolledBack),
            _ => Err(DriverError::OperationOutcomeUnknown {
                source: Box::new(DriverError::Unsupported("unconfirmed session commit outcome".into())),
            }),
        }
    }

    async fn query_result_sets_params_controlled(
        &mut self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResultBatch, DriverError> {
        self.extra.collect = true;
        self.extra.sets.clear();
        let first = self.query_params_controlled(sql, params, control).await;
        self.extra.collect = false;
        let extras = std::mem::take(&mut self.extra.sets);
        let mut result_sets = vec![first?];
        result_sets.extend(extras);
        let truncated = result_sets.iter().any(|set| set.truncated);
        Ok(QueryResultBatch { result_sets, truncated })
    }

    async fn open_query_cursor_controlled(
        &mut self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryCursorId, DriverError> {
        if !self.is_usable() {
            return self
                .refuse_policy(
                    sql,
                    "retired_session",
                    "the session was retired and cannot open a query cursor",
                )
                .await;
        }
        let Some(batch) = self.batch.filter(|batch| batch.read_only) else {
            return self
                .refuse_policy(
                    sql,
                    "query_cursor_requires_read_snapshot",
                    "query cursors require a read-only snapshot",
                )
                .await;
        };
        if self.cursor.is_some() {
            return self
                .refuse_policy(
                    sql,
                    "query_cursor_already_open",
                    "only one query cursor may be open per session",
                )
                .await;
        }
        let analysis = self.guard.analyze_statement(sql);
        if !analysis.facts.is_single_read() {
            return self
                .refuse_policy(
                    sql,
                    "query_cursor_requires_single_read",
                    "query cursors require one read-only statement",
                )
                .await;
        }
        let authorization = self.guard.authorize_classified(sql, analysis, Some(control)).await?;
        let audit = CursorAudit {
            operation_id: Uuid::new_v4(),
            batch_id: batch.id,
            sql: sql.into(),
            targets: authorization.analysis.facts.tables.clone(),
            decision_rule: authorization.decision.rule_name().into(),
            approval_outcome: authorization.approval_outcome,
            preview_state: authorization.preview_state,
            analysis: authorization.analysis,
        };
        self.open_authorized_cursor(sql, params, control, audit).await
    }

    async fn fetch_query_cursor_page_controlled(
        &mut self,
        cursor_id: QueryCursorId,
        control: &OperationControl,
    ) -> Result<QueryCursorPage, DriverError> {
        let Some(cursor) = self.cursor.as_ref().filter(|cursor| cursor.id == cursor_id) else {
            return Err(DriverError::Unsupported(
                "forward-only cursor is not active in this session".into(),
            ));
        };
        let audit = &cursor.audit;
        let start = Instant::now();
        let result = self
            .guard
            .caught_read(
                "SESSION FETCH QUERY CURSOR PAGE",
                self.inner.fetch_query_cursor_page_controlled(cursor_id, control),
            )
            .await
            .map(|mut page| {
                page.result = self.guard.mask_result_for_analysis(Some(&audit.analysis), page.result);
                page
            });
        let rows = result.as_ref().ok().map(|page| page.result.rows.len() as u64);
        let terminal_status = match &result {
            Ok(page) if page.has_next_page => AuditTerminalStatus::Pending,
            Ok(_) => AuditTerminalStatus::Succeeded,
            Err(error) => controlled_error_terminal_status(error),
        };
        let audit_result = audit_cursor_result(&self.guard, audit, start, &result, rows, terminal_status).await;
        match result {
            Err(error) => {
                self.note_cursor_error(&error);
                self.close_cursor_driver(cursor_id).await;
                audit_result?;
                Err(error)
            }
            Ok(page) => {
                if let Err(error) = audit_result {
                    self.close_cursor_driver(cursor_id).await;
                    return Err(error);
                }
                if !page.has_next_page
                    && let Some(cursor) = self.cursor.as_mut()
                {
                    cursor.complete = true;
                }
                Ok(page)
            }
        }
    }

    async fn close_query_cursor_controlled(
        &mut self,
        cursor_id: QueryCursorId,
        _control: &OperationControl,
    ) -> Result<(), DriverError> {
        self.close_active_cursor(cursor_id, Some(AuditTerminalStatus::Cancelled))
            .await
    }

    fn is_usable(&self) -> bool {
        if self.retired.get() {
            return false;
        }
        match self.guard.caught_sync("SESSION STATUS", || self.inner.is_usable()) {
            Some(usable) => usable,
            None => {
                self.retired.set(true);
                false
            }
        }
    }

    fn transaction_open(&self) -> bool {
        self.batch.is_some()
    }

    async fn close(mut self: Box<Self>) -> Result<(), DriverError> {
        let cursor_cleanup = match self.cursor.as_ref() {
            Some(cursor) => {
                self.close_active_cursor(cursor.id, Some(AuditTerminalStatus::Cancelled))
                    .await
            }
            None => Ok(()),
        };
        let cleanup = if let Some(batch) = self.batch {
            if !self.is_usable() && batch.read_only && !batch.wrote {
                record_ended_read_only_batch(&self.guard, batch.id).await;
                Ok(())
            } else if self.is_usable() && !batch.uncertain {
                let control = OperationControl::with_timeout(CLOSE_ROLLBACK_TIMEOUT);
                let rollback = self.finish("ROLLBACK", &control, Finish::Rollback, false).await;
                if rollback.is_err()
                    && let Some(open_batch) = self.batch
                {
                    if open_batch.read_only && !open_batch.wrote {
                        record_ended_read_only_batch(&self.guard, open_batch.id).await;
                    } else {
                        record_abandoned_transaction(&self.guard, open_batch.id).await;
                    }
                }
                rollback.map(|_| ())
            } else {
                record_abandoned_transaction(&self.guard, batch.id).await;
                Err(DriverError::OperationOutcomeUnknown {
                    source: Box::new(DriverError::Disconnected),
                })
            }
        } else {
            Ok(())
        };
        let close = self.guard.caught_read("SESSION CLOSE", self.inner.close()).await;
        cursor_cleanup.and(cleanup).and(close)
    }
}

impl PolicySession {
    async fn open_authorized_cursor(
        &mut self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
        audit: CursorAudit,
    ) -> Result<QueryCursorId, DriverError> {
        let operation = audit.operation();
        self.guard.prepare_governed_read(&operation).await?;
        let start = Instant::now();
        let result = self
            .guard
            .caught_read(
                "SESSION OPEN QUERY CURSOR",
                self.inner.open_query_cursor_controlled(sql, params, control),
            )
            .await;
        let id = match result {
            Ok(id) => id,
            Err(error) => {
                let audit_result = audit_cursor_error(&self.guard, &audit, start, &error).await;
                self.note_cursor_error(&error);
                audit_result?;
                return Err(error);
            }
        };
        self.cursor = Some(ActiveCursor {
            id,
            audit,
            complete: false,
        });
        Ok(id)
    }

    async fn close_active_cursor(
        &mut self,
        cursor_id: QueryCursorId,
        terminal_status: Option<AuditTerminalStatus>,
    ) -> Result<(), DriverError> {
        let Some(cursor) = self.cursor.take() else {
            return Err(DriverError::Unsupported(
                "forward-only cursor is not active in this session".into(),
            ));
        };
        if cursor.id != cursor_id {
            self.cursor = Some(cursor);
            return Err(DriverError::Unsupported(
                "forward-only cursor is not active in this session".into(),
            ));
        }
        let start = Instant::now();
        let control = OperationControl::with_timeout(CLOSE_CURSOR_TIMEOUT);
        let result = self
            .guard
            .caught_read(
                "SESSION CLOSE QUERY CURSOR",
                self.inner.close_query_cursor_controlled(cursor.id, &control),
            )
            .await;
        if !cursor.complete
            && let Some(status) = terminal_status
        {
            let status = result
                .as_ref()
                .map_or_else(controlled_error_terminal_status, |_| status);
            let audit_result = audit_cursor_result(&self.guard, &cursor.audit, start, &result, None, status).await;
            if let Err(error) = audit_result {
                self.retired.set(true);
                return Err(error);
            }
        }
        if result.is_err() {
            self.retired.set(true);
        }
        result
    }

    async fn close_cursor_driver(&mut self, cursor_id: QueryCursorId) {
        let control = OperationControl::with_timeout(CLOSE_CURSOR_TIMEOUT);
        let result = self
            .guard
            .caught_read(
                "SESSION CLOSE QUERY CURSOR",
                self.inner.close_query_cursor_controlled(cursor_id, &control),
            )
            .await;
        self.cursor = None;
        if result.is_err() || !self.is_usable() {
            self.retired.set(true);
        }
    }

    fn note_cursor_error(&mut self, error: &DriverError) {
        if matches!(
            error,
            DriverError::Disconnected | DriverError::OperationOutcomeUnknown { .. }
        ) {
            self.retired.set(true);
        }
        let Some(batch) = self.batch.as_mut() else {
            return;
        };
        if !batch.read_only
            && matches!(
                error,
                DriverError::Cancelled | DriverError::TimedOut | DriverError::OperationOutcomeUnknown { .. }
            )
        {
            batch.uncertain = true;
        }
        if self.guard.ctx.driver_id == "postgres" {
            batch.aborted = true;
        }
    }

    async fn begin(&mut self, sql: &str, control: &OperationControl) -> Result<QueryResult, DriverError> {
        if self.batch.is_some() {
            return self
                .refuse_policy(
                    sql,
                    "nested_transaction",
                    "a transaction is already open on this session; nested BEGIN is refused",
                )
                .await;
        }
        let result = self
            .guard
            .caught_write("BEGIN", self.inner.query_params_controlled(sql, &[], control))
            .await;
        self.note_disconnect(&result);
        if result.is_ok() {
            self.batch = Some(OpenBatch::new(false));
        }
        result
    }

    async fn begin_read_only(&mut self, sql: &str, control: &OperationControl) -> Result<QueryResult, DriverError> {
        if self.guard.ctx.driver_id != "postgres" {
            return self
                .refuse_policy(
                    sql,
                    "snapshot_engine",
                    "read-only session transactions are currently supported only by PostgreSQL",
                )
                .await;
        }
        if self.batch.is_some() {
            return self
                .refuse_policy(
                    sql,
                    "nested_transaction",
                    "a transaction is already open on this session; nested BEGIN is refused",
                )
                .await;
        }
        let analysis = self.guard.analyze_statement(sql);
        let authorization = Authorization {
            decision: Decision::Allow {
                rule: "read_only_snapshot".into(),
            },
            analysis,
            approval_outcome: AuditApprovalOutcome::NotRequired,
            preview_state: AuditPreviewState::NotRequested,
        };
        let operation = self.guard.operation(
            sql,
            None,
            &authorization.analysis.facts,
            &authorization.decision,
            authorization.approval_outcome,
            authorization.preview_state,
        );
        self.guard.prepare_governed_read(&operation).await?;
        let start = Instant::now();
        let result = self
            .guard
            .caught_read("BEGIN READ ONLY", self.inner.query_params_controlled(sql, &[], control))
            .await;
        self.note_disconnect(&result);
        if result.is_ok() {
            self.batch = Some(OpenBatch::new(true));
        }
        let rows = result.as_ref().ok().map(|value| value.rows.len() as u64);
        self.guard
            .audit_controlled_read_result(&operation, start, &result, rows)
            .await?;
        result
    }

    async fn statement(
        &mut self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        let analysis = self.guard.analyze_statement(sql);
        let external_effects = Effects::SESSION_STATE.union(Effects::HOST_OR_FILE_ACCESS);
        if self.batch.is_some_and(|batch| {
            batch.read_only && (analysis.facts.effects.writes() || analysis.facts.effects.contains(external_effects))
        }) {
            return self
                .refuse(sql, "read_only_snapshot_refusal", DriverError::ReadOnly)
                .await;
        }
        let authorization = self.guard.authorize_classified(sql, analysis, Some(control)).await?;
        let writes = authorization.analysis.facts.writes();
        let rolls_back_to_savepoint = authorization.analysis.rolls_back_to_savepoint;
        let result = match self.batch {
            Some(batch) => {
                self.batch_statement(sql, params, control, authorization, batch.id)
                    .await
            }
            None if writes => self.lone_write(sql, params, control, authorization).await,
            None => self.lone_read(sql, params, control, authorization).await,
        };
        self.note_statement(writes, rolls_back_to_savepoint, &result);
        result
    }

    fn note_disconnect(&mut self, result: &Result<QueryResult, DriverError>) {
        if matches!(result, Err(DriverError::Disconnected)) {
            self.retired.set(true);
        }
    }

    fn note_statement(
        &mut self,
        writes: bool,
        rolls_back_to_savepoint: bool,
        result: &Result<QueryResult, DriverError>,
    ) {
        self.note_disconnect(result);
        let Some(batch) = self.batch.as_mut() else {
            return;
        };
        batch.wrote |= writes;
        if matches!(
            result,
            Err(DriverError::Cancelled
                | DriverError::TimedOut
                | DriverError::OperationOutcomeUnknown { .. }
                | DriverError::Disconnected)
        ) {
            batch.uncertain = true;
        }
        if self.guard.ctx.driver_id == "postgres" && (result.is_err() || rolls_back_to_savepoint) {
            batch.aborted = result.is_err();
        }
    }

    async fn batch_statement(
        &mut self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
        authorization: Authorization,
        batch_id: Uuid,
    ) -> Result<QueryResult, DriverError> {
        let writes = authorization.analysis.facts.writes();
        if writes {
            self.require_writable(sql).await?;
        }
        let operation = self.guard.operation(
            sql,
            Some(batch_id),
            &authorization.analysis.facts,
            &authorization.decision,
            authorization.approval_outcome,
            authorization.preview_state,
        );
        let mut pending_write = if writes {
            self.guard
                .handle_intent_failure(self.guard.record_intent(&operation).await)?;
            Some(self.guard.ctx.audit_state.pending_write())
        } else {
            self.guard.prepare_governed_read(&operation).await?;
            None
        };
        let start = Instant::now();
        let execution = inner_statement(
            &mut self.inner,
            &mut self.extra,
            &self.guard,
            &authorization.analysis,
            sql,
            params,
            control,
        );
        let result = match writes {
            true => self.guard.caught_write("SESSION QUERY", execution).await,
            false => self.guard.caught_read("SESSION QUERY", execution).await,
        }
        .map(|value| {
            self.guard
                .mask_result_for_analysis(Some(&authorization.analysis), value)
        });
        let rows = result.as_ref().ok().map(|value| rows_in(value, &self.extra.sets));
        self.guard
            .audit_transaction_result(&operation, start, &result, rows, TransactionAuditMode::Interactive)
            .await?;
        if let Some(pending) = pending_write.as_mut() {
            pending.disarm();
        }
        result
    }

    async fn lone_write(
        &mut self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
        authorization: Authorization,
    ) -> Result<QueryResult, DriverError> {
        self.require_writable(sql).await?;
        let operation = self.guard.operation(
            sql,
            None,
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
                "SESSION QUERY",
                inner_statement(
                    &mut self.inner,
                    &mut self.extra,
                    &self.guard,
                    &authorization.analysis,
                    sql,
                    params,
                    control,
                ),
            )
            .await
            .map(|value| {
                self.guard
                    .mask_result_for_analysis(Some(&authorization.analysis), value)
            });
        let rows = result.as_ref().ok().map(|value| rows_in(value, &self.extra.sets));
        self.guard.audit_write_result(&operation, start, &result, rows).await?;
        pending_write.disarm();
        result
    }

    async fn lone_read(
        &mut self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
        authorization: Authorization,
    ) -> Result<QueryResult, DriverError> {
        let operation = self.guard.operation(
            sql,
            None,
            &authorization.analysis.facts,
            &authorization.decision,
            authorization.approval_outcome,
            authorization.preview_state,
        );
        self.guard.prepare_governed_read(&operation).await?;
        let start = Instant::now();
        let result = self
            .guard
            .caught_read(
                "SESSION QUERY",
                inner_statement(
                    &mut self.inner,
                    &mut self.extra,
                    &self.guard,
                    &authorization.analysis,
                    sql,
                    params,
                    control,
                ),
            )
            .await
            .map(|value| {
                self.guard
                    .mask_result_for_analysis(Some(&authorization.analysis), value)
            });
        let rows = result.as_ref().ok().map(|value| rows_in(value, &self.extra.sets));
        self.guard
            .audit_controlled_read_result(&operation, start, &result, rows)
            .await?;
        result
    }
}

impl PolicySession {
    async fn finish(
        &mut self,
        sql: &str,
        control: &OperationControl,
        kind: Finish,
        chain: bool,
    ) -> Result<(QueryResult, AuditTransactionOutcome), DriverError> {
        let Some(batch) = self.batch else {
            return self
                .refuse_policy(sql, "missing_transaction", "no transaction is open on this session")
                .await;
        };
        if kind == Finish::Commit {
            self.require_writable(sql).await?;
        }
        let operation = finish_operation(kind, batch.id);
        self.guard.record_intent(&operation).await.map_err(|error| {
            DriverError::PolicyDenied(format!(
                "{} denied because audit intent could not be persisted: {error}",
                operation.sql
            ))
        })?;
        let mut pending_write = self.guard.ctx.audit_state.pending_write();
        let start = Instant::now();
        let result = self
            .guard
            .caught_write(operation.sql, self.inner.query_params_controlled(sql, &[], control))
            .await;
        if matches!(result, Err(DriverError::Disconnected)) {
            self.retired.set(true);
        }
        let (mut terminal_status, mut transaction_outcome, error_category, mut ambiguous) =
            finish_outcome(kind, batch.aborted, &result);
        let read_only_ended = ambiguous && batch.read_only && !batch.wrote;
        if read_only_ended {
            (terminal_status, transaction_outcome, ambiguous) =
                (AuditTerminalStatus::Failed, AuditTransactionOutcome::RolledBack, false);
        }
        if ambiguous {
            self.guard.ctx.audit_state.disable_governed_writes();
        }
        let audit_result = self
            .guard
            .record_outcome(
                &operation,
                AuditOutcome {
                    terminal_status,
                    transaction_outcome,
                    rows_affected: None,
                    error_category,
                    duration_ms: start.elapsed().as_millis() as u64,
                },
            )
            .await;
        let is_retryable = matches!(result, Err(DriverError::Cancelled | DriverError::TimedOut));
        self.batch = match (&result, kind) {
            _ if read_only_ended => None,
            (Ok(_), _) => chain.then(|| OpenBatch::new(batch.read_only)),
            (Err(_), Finish::Commit) if !ambiguous && !is_retryable => None,
            _ => Some(OpenBatch {
                uncertain: batch.uncertain || ambiguous,
                ..batch
            }),
        };
        self.guard.handle_write_outcome_failure(audit_result)?;
        pending_write.disarm();
        result.map(|result| (result, transaction_outcome))
    }
}

async fn record_ended_read_only_batch(guard: &PolicyGuard, batch_id: Uuid) {
    let operation = finish_operation(Finish::Rollback, batch_id);
    let _ = guard.record_intent(&operation).await;
    let outcome = AuditOutcome {
        terminal_status: AuditTerminalStatus::Failed,
        transaction_outcome: AuditTransactionOutcome::RolledBack,
        rows_affected: None,
        error_category: Some(error_category(&DriverError::Disconnected)),
        duration_ms: 0,
    };
    let _ = guard.handle_write_outcome_failure(guard.record_outcome(&operation, outcome).await);
}

async fn record_abandoned_transaction(guard: &PolicyGuard, batch_id: Uuid) {
    guard.ctx.audit_state.disable_governed_writes();
    let operation = finish_operation(Finish::Rollback, batch_id);
    let _ = guard.record_intent(&operation).await;
    let outcome = AuditOutcome {
        terminal_status: AuditTerminalStatus::Unknown,
        transaction_outcome: AuditTransactionOutcome::Unknown,
        rows_affected: None,
        error_category: None,
        duration_ms: 0,
    };
    let _ = guard.handle_write_outcome_failure(guard.record_outcome(&operation, outcome).await);
}

async fn audit_cursor_result<T>(
    guard: &PolicyGuard,
    audit: &CursorAudit,
    start: Instant,
    result: &Result<T, DriverError>,
    rows: Option<u64>,
    terminal_status: AuditTerminalStatus,
) -> Result<(), DriverError> {
    let status = result
        .as_ref()
        .map_or_else(controlled_error_terminal_status, |_| terminal_status);
    let audit_result = guard
        .record_outcome(
            &audit.operation(),
            AuditOutcome {
                terminal_status: status,
                transaction_outcome: AuditTransactionOutcome::NotApplicable,
                rows_affected: rows,
                error_category: result.as_ref().err().map(error_category),
                duration_ms: start.elapsed().as_millis() as u64,
            },
        )
        .await;
    guard.handle_read_audit_failure(audit_result)
}

async fn audit_cursor_error(
    guard: &PolicyGuard,
    audit: &CursorAudit,
    start: Instant,
    error: &DriverError,
) -> Result<(), DriverError> {
    let audit_result = guard
        .record_outcome(
            &audit.operation(),
            AuditOutcome {
                terminal_status: controlled_error_terminal_status(error),
                transaction_outcome: AuditTransactionOutcome::NotApplicable,
                rows_affected: None,
                error_category: Some(error_category(error)),
                duration_ms: start.elapsed().as_millis() as u64,
            },
        )
        .await;
    guard.handle_read_audit_failure(audit_result)
}

fn finish_operation(kind: Finish, batch_id: Uuid) -> AuditOperation<'static> {
    match kind {
        Finish::Commit => PolicyGuard::commit_operation(batch_id),
        Finish::Rollback => AuditOperation {
            operation_id: Uuid::new_v4(),
            batch_id: Some(batch_id),
            sql: "ROLLBACK",
            class: AuditOperationClass::TransactionRollback,
            targets: Vec::new(),
            decision_rule: "transaction_rollback".into(),
            approval_outcome: AuditApprovalOutcome::NotRequired,
            preview_state: AuditPreviewState::NotRequested,
        },
    }
}

fn finish_outcome(
    kind: Finish,
    aborted: bool,
    result: &Result<QueryResult, DriverError>,
) -> (
    AuditTerminalStatus,
    AuditTransactionOutcome,
    Option<AuditErrorCategory>,
    bool,
) {
    match result {
        Ok(_) => {
            let outcome = match kind {
                Finish::Commit if aborted => AuditTransactionOutcome::RolledBack,
                Finish::Commit => AuditTransactionOutcome::Committed,
                Finish::Rollback => AuditTransactionOutcome::RolledBack,
            };
            (AuditTerminalStatus::Succeeded, outcome, None, false)
        }
        Err(DriverError::Cancelled) => (
            AuditTerminalStatus::Cancelled,
            AuditTransactionOutcome::Pending,
            Some(AuditErrorCategory::Cancelled),
            false,
        ),
        Err(DriverError::TimedOut) => (
            AuditTerminalStatus::TimedOut,
            AuditTransactionOutcome::Pending,
            Some(AuditErrorCategory::Timeout),
            false,
        ),
        Err(error) if is_ambiguous_post_dispatch(error) => (
            AuditTerminalStatus::Unknown,
            AuditTransactionOutcome::Unknown,
            Some(error_category(error)),
            true,
        ),
        Err(error) => (
            AuditTerminalStatus::Failed,
            AuditTransactionOutcome::Failed,
            Some(error_category(error)),
            false,
        ),
    }
}
