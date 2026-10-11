use super::*;

impl PolicySession {
    pub(super) async fn require_writable(&mut self, sql: &str) -> Result<(), DriverError> {
        match self.guard.require_governed_write_available() {
            Ok(()) => Ok(()),
            Err(error) => self.refuse(sql, "governed_write_lockdown", error).await.map(|_| ()),
        }
    }

    pub(super) async fn refuse_policy(
        &mut self,
        sql: &str,
        rule: &str,
        message: &str,
    ) -> Result<QueryResult, DriverError> {
        self.refuse(sql, rule, DriverError::PolicyDenied(message.into())).await
    }

    pub(super) async fn refuse(
        &mut self,
        sql: &str,
        rule: &str,
        error: DriverError,
    ) -> Result<QueryResult, DriverError> {
        let analysis = self.guard.analyze_statement(sql);
        let decision = Decision::Deny {
            rule: rule.into(),
            message: error.to_string(),
        };
        let operation = self.guard.operation(
            sql,
            self.batch.map(|batch| batch.id),
            &analysis.facts,
            &decision,
            AuditApprovalOutcome::NotRequired,
            AuditPreviewState::NotRequested,
        );
        let recorded = self
            .guard
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
        self.guard.handle_non_execution_audit_failure(recorded)?;
        Err(error)
    }
}
