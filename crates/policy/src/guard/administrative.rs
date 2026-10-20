use std::future::Future;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use super::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AdministrativeOperation {
    Backup,
    Restore,
}

impl AdministrativeOperation {
    fn label(self) -> &'static str {
        match self {
            Self::Backup => "BACKUP DATABASE",
            Self::Restore => "RESTORE DATABASE",
        }
    }

    fn rule(self) -> &'static str {
        match self {
            Self::Backup => "administrative_backup",
            Self::Restore => "administrative_restore",
        }
    }

    fn replaces_data(self) -> bool {
        matches!(self, Self::Restore)
    }
}

impl PolicyGuard {
    pub async fn run_administrative<T, F>(
        &self,
        operation: AdministrativeOperation,
        control: &OperationControl,
        work: F,
    ) -> Result<T, DriverError>
    where
        F: Future<Output = Result<T, DriverError>>,
    {
        self.run_administrative_inner(operation, control, None, work).await
    }

    pub async fn run_administrative_with_dispatch<T, F>(
        &self,
        operation: AdministrativeOperation,
        control: &OperationControl,
        dispatched: Arc<AtomicBool>,
        work: F,
    ) -> Result<T, DriverError>
    where
        F: Future<Output = Result<T, DriverError>>,
    {
        self.run_administrative_inner(operation, control, Some(dispatched), work)
            .await
    }

    async fn run_administrative_inner<T, F>(
        &self,
        operation: AdministrativeOperation,
        control: &OperationControl,
        dispatched: Option<Arc<AtomicBool>>,
        work: F,
    ) -> Result<T, DriverError>
    where
        F: Future<Output = Result<T, DriverError>>,
    {
        check_pre_dispatch(control)?;
        let decision = self.administrative_decision(operation);
        let authorization = self
            .resolve_authorization(
                operation.label(),
                administrative_analysis(operation),
                decision,
                None,
                Some(control),
            )
            .await?;
        self.run_authorized_administrative(operation, control, dispatched, authorization, work)
            .await
    }

    async fn run_authorized_administrative<T, F>(
        &self,
        operation: AdministrativeOperation,
        control: &OperationControl,
        dispatched: Option<Arc<AtomicBool>>,
        authorization: Authorization,
        work: F,
    ) -> Result<T, DriverError>
    where
        F: Future<Output = Result<T, DriverError>>,
    {
        let mut pending_restore = match (operation.replaces_data(), dispatched.clone()) {
            (true, Some(dispatched)) => Some(self.ctx.audit_state.pending_write_after_dispatch(dispatched)),
            _ => None,
        };
        let audit = AuditOperation {
            operation_id: Uuid::new_v4(),
            batch_id: None,
            sql: operation.label(),
            class: AuditOperationClass::Administrative,
            targets: Vec::new(),
            decision_rule: authorization.decision.rule_name().to_string(),
            approval_outcome: authorization.approval_outcome,
            preview_state: authorization.preview_state,
        };
        self.record_intent(&audit).await.map_err(|error| {
            DriverError::PolicyDenied(format!(
                "operation denied because audit intent could not be persisted: {error}"
            ))
        })?;
        let started = Instant::now();
        let result = tokio::select! {
            biased;
            _ = control.cancellation_token().cancelled() => Err(DriverError::Cancelled),
            _ = wait_for_control_deadline(control) => {
                control.cancellation_token().cancel();
                Err(DriverError::TimedOut)
            },
            result = work => result,
        };
        let result = self.resolve_restore_outcome(operation, dispatched.as_ref(), result);
        let outcome = AuditOutcome {
            terminal_status: result
                .as_ref()
                .map_or_else(controlled_error_terminal_status, |_| AuditTerminalStatus::Succeeded),
            transaction_outcome: AuditTransactionOutcome::NotApplicable,
            rows_affected: None,
            error_category: result.as_ref().err().map(error_category),
            duration_ms: u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
        };
        let recorded = self.record_outcome(&audit, outcome).await;
        self.handle_write_outcome_failure(recorded)?;
        if let Some(pending) = &mut pending_restore {
            pending.disarm();
        }
        result
    }

    fn resolve_restore_outcome<T>(
        &self,
        operation: AdministrativeOperation,
        dispatched: Option<&Arc<AtomicBool>>,
        result: Result<T, DriverError>,
    ) -> Result<T, DriverError> {
        match result {
            Err(error)
                if operation.replaces_data()
                    && dispatched.as_ref().is_some_and(|state| state.load(Ordering::Acquire)) =>
            {
                self.ctx.audit_state.disable_governed_writes();
                Err(match error {
                    DriverError::OperationOutcomeUnknown { .. } => error,
                    error => DriverError::OperationOutcomeUnknown {
                        source: Box::new(error),
                    },
                })
            }
            result => result,
        }
    }

    fn administrative_decision(&self, operation: AdministrativeOperation) -> Decision {
        if self.ctx.principal.is_agent() {
            return Decision::Deny {
                rule: "agent_administrative_operation".into(),
                message: "agents cannot run backups or restores".into(),
            };
        }
        if !operation.replaces_data() {
            return Decision::Allow {
                rule: operation.rule().into(),
            };
        }
        if self.ctx.read_only {
            return Decision::Deny {
                rule: "connection_read_only".into(),
                message: "connection is marked read-only; a restore would replace its data".into(),
            };
        }
        if let Some(refusal) = self.governed_write_refusal() {
            return refusal;
        }
        Decision::RequireApproval {
            rule: operation.rule().into(),
            reason: "restoring replaces the data in this database".into(),
            preview: None,
        }
    }
}

fn administrative_analysis(operation: AdministrativeOperation) -> StatementAnalysis {
    let effects = if operation.replaces_data() {
        Effects::WRITES_ROWS.union(Effects::WRITES_SCHEMA).union(Effects::ADMIN)
    } else {
        Effects::READS.union(Effects::ADMIN)
    };
    StatementAnalysis {
        facts: StatementFacts {
            class: StatementClass::Administrative,
            effects,
            tables: Vec::new(),
            has_where: true,
            contains_unscoped_dml: false,
            is_multi_statement: false,
            parse_error: None,
        },
        blast_radius: None,
        rolls_back_to_savepoint: false,
        sensitive_positions: None,
        known_statement_rows: Vec::new(),
    }
}
