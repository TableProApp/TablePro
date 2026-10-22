use std::collections::HashMap;

use tablepro_policy::{
    AuditApprovalOutcome, AuditEvent, AuditOperationClass, AuditRecordPhase, AuditTerminalStatus, Principal,
};
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq)]
pub struct OperationRow {
    pub operation_id: Uuid,
    pub started: String,
    pub connection: String,
    pub principal: String,
    pub class: String,
    pub status: AuditTerminalStatus,
    pub approval: AuditApprovalOutcome,
    pub rule: String,
    pub sql: String,
    pub error: Option<String>,
    pub rows: Option<u64>,
    pub duration_ms: Option<u64>,
}

pub fn operations(events: Vec<AuditEvent>) -> Vec<OperationRow> {
    let mut rows: Vec<(OperationRow, usize)> = Vec::new();
    let mut by_operation: HashMap<Uuid, usize> = HashMap::new();
    for (position, event) in events.into_iter().enumerate() {
        let index = *by_operation.entry(event.operation_id).or_insert_with(|| {
            rows.push((row_from(&event), position));
            rows.len() - 1
        });
        rows[index].1 = position;
        if event.phase == AuditRecordPhase::Outcome {
            let row = &mut rows[index].0;
            row.status = event.terminal_status;
            row.approval = event.approval_outcome;
            row.error = event.error;
            row.rows = event.rows_affected;
            row.duration_ms = event.duration_ms;
        }
    }
    rows.sort_by_key(|(_, last_event)| std::cmp::Reverse(*last_event));
    rows.into_iter().map(|(row, _)| row).collect()
}

fn row_from(event: &AuditEvent) -> OperationRow {
    OperationRow {
        operation_id: event.operation_id,
        started: event
            .timestamp
            .with_timezone(&chrono::Local)
            .format("%Y-%m-%d %H:%M:%S")
            .to_string(),
        connection: event.connection_name.clone(),
        principal: principal_text(&event.principal),
        class: class_label(event.operation_class),
        status: event.terminal_status,
        approval: event.approval_outcome,
        rule: event.decision_rule.clone(),
        sql: event.redacted_sql.clone(),
        error: event.error.clone(),
        rows: event.rows_affected,
        duration_ms: event.duration_ms,
    }
}

fn principal_text(principal: &Principal) -> String {
    match principal {
        Principal::Agent {
            token,
            client: Some(client),
            ..
        } => format!("agent:{client}:{token}"),
        Principal::Agent { token, .. } => format!("agent:{token}"),
        human => human.label(),
    }
}

fn class_label(class: AuditOperationClass) -> String {
    match class {
        AuditOperationClass::Read => crate::tr!("Read"),
        AuditOperationClass::Mutation => crate::tr!("Data change"),
        AuditOperationClass::Ddl => crate::tr!("Schema change"),
        AuditOperationClass::Administrative => crate::tr!("Administrative"),
        AuditOperationClass::TransactionCommit => crate::tr!("Commit"),
        AuditOperationClass::TransactionRollback => crate::tr!("Rollback"),
        AuditOperationClass::UnknownWrite => crate::tr!("Unclassified write"),
    }
}

pub fn approval_label(approval: AuditApprovalOutcome) -> String {
    match approval {
        AuditApprovalOutcome::NotRequired => crate::tr!("no approval needed"),
        AuditApprovalOutcome::Approved => crate::tr!("approved"),
        AuditApprovalOutcome::Denied => crate::tr!("denied"),
        AuditApprovalOutcome::Cancelled => crate::tr!("approval cancelled"),
        AuditApprovalOutcome::TimedOut => crate::tr!("approval timed out"),
    }
}

pub fn needs_attention(status: AuditTerminalStatus) -> bool {
    !matches!(status, AuditTerminalStatus::Succeeded | AuditTerminalStatus::Pending)
}

pub fn status_label(status: AuditTerminalStatus) -> String {
    match status {
        AuditTerminalStatus::Pending => crate::tr!("No outcome recorded"),
        AuditTerminalStatus::Succeeded => crate::tr!("Succeeded"),
        AuditTerminalStatus::Failed => crate::tr!("Failed"),
        AuditTerminalStatus::Denied => crate::tr!("Denied"),
        AuditTerminalStatus::Cancelled => crate::tr!("Cancelled"),
        AuditTerminalStatus::TimedOut => crate::tr!("Timed out"),
        AuditTerminalStatus::Unknown => crate::tr!("Unknown outcome"),
    }
}

pub fn matches(row: &OperationRow, query: &str) -> bool {
    let query = query.trim().to_lowercase();
    if query.is_empty() {
        return true;
    }
    [
        row.operation_id.to_string(),
        row.connection.clone(),
        row.principal.clone(),
        row.class.clone(),
        row.sql.clone(),
        status_label(row.status),
    ]
    .iter()
    .any(|field| field.to_lowercase().contains(&query))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_policy::{AuditOperationClass, AuditPreviewState, AuditTransactionOutcome, Principal};

    fn event(operation_id: Uuid, phase: AuditRecordPhase, status: AuditTerminalStatus) -> AuditEvent {
        AuditEvent {
            timestamp: chrono::Utc::now(),
            operation_id,
            batch_id: None,
            phase,
            principal: Principal::human_gui(),
            connection_id: Uuid::nil(),
            connection_name: "shop".into(),
            environment: tablepro_core::Environment::Prod,
            driver_id: "postgres".into(),
            operation_class: AuditOperationClass::Mutation,
            redacted_sql: "UPDATE orders SET note = ?".into(),
            sql_hash: String::new(),
            targets: Vec::new(),
            decision_rule: "human_write_approve".into(),
            approval_outcome: AuditApprovalOutcome::Approved,
            preview_state: AuditPreviewState::NotRequested,
            terminal_status: status,
            transaction_outcome: AuditTransactionOutcome::NotApplicable,
            error_category: None,
            error: None,
            rows_affected: (phase == AuditRecordPhase::Outcome).then_some(3),
            duration_ms: (phase == AuditRecordPhase::Outcome).then_some(12),
            transport_attempt: None,
            administrative_action: None,
        }
    }

    #[test]
    fn intent_and_outcome_of_one_operation_become_one_row_ordered_by_latest_record() {
        let (first, second) = (Uuid::new_v4(), Uuid::new_v4());
        let rows = operations(vec![
            event(first, AuditRecordPhase::Intent, AuditTerminalStatus::Pending),
            event(second, AuditRecordPhase::Intent, AuditTerminalStatus::Pending),
            event(first, AuditRecordPhase::Outcome, AuditTerminalStatus::Succeeded),
        ]);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].operation_id, first, "its outcome is the newest record");
        assert_eq!(rows[0].status, AuditTerminalStatus::Succeeded);
        assert_eq!((rows[0].rows, rows[0].duration_ms), (Some(3), Some(12)));
        assert_eq!(rows[1].operation_id, second);
        assert_eq!(
            rows[1].status,
            AuditTerminalStatus::Pending,
            "no outcome yet stays visible"
        );
    }

    #[test]
    fn the_operation_that_finished_last_comes_first_and_agents_keep_their_token() {
        let (long, short) = (Uuid::new_v4(), Uuid::new_v4());
        let mut agent = event(short, AuditRecordPhase::Outcome, AuditTerminalStatus::Succeeded);
        agent.principal = Principal::Agent {
            token: "sha256:0123456789abcdef".into(),
            client: Some("claude".into()),
            model: None,
        };
        let rows = operations(vec![
            event(long, AuditRecordPhase::Intent, AuditTerminalStatus::Pending),
            agent,
            event(long, AuditRecordPhase::Outcome, AuditTerminalStatus::Failed),
        ]);
        assert_eq!(rows[0].operation_id, long, "the failure that ended last is first");
        assert_eq!(rows[1].principal, "agent:claude:sha256:0123456789abcdef");
        assert!(needs_attention(AuditTerminalStatus::Failed) && !needs_attention(AuditTerminalStatus::Pending));
    }

    #[test]
    fn an_outcome_whose_intent_is_older_than_the_window_still_shows() {
        let id = Uuid::new_v4();
        let rows = operations(vec![event(id, AuditRecordPhase::Outcome, AuditTerminalStatus::Denied)]);
        assert_eq!(rows[0].status, AuditTerminalStatus::Denied);
    }

    #[test]
    fn the_filter_matches_operation_id_connection_sql_and_outcome() {
        let id = Uuid::new_v4();
        let row = &operations(vec![event(id, AuditRecordPhase::Outcome, AuditTerminalStatus::Failed)])[0];
        for query in ["", &id.to_string()[..8], "SHOP", "orders", "failed"] {
            assert!(matches(row, query), "{query}");
        }
        assert!(!matches(row, "billing"));
    }
}
