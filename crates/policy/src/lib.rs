//! Statement classification, policy decisions, and the connection guard
//! that every consumer (GUI, MCP, agentd) must pass through.

mod admin_functions;
mod approval;
mod audit;
mod blast_radius;
mod catalog_effect;
mod classify;
pub use catalog_effect::{CatalogEffect, catalog_effect};
mod config;
mod effects;
mod effects_classification;
mod guard;
mod mask;
mod principal;
mod rules;
mod select_writes;
mod sensitive_projection;
mod transaction_control;
mod verdict;

pub use approval::{ApprovalOutcome, ApprovalRequest, ApprovalSink, AutoApproveSink, DenyApprovalSink};
pub use audit::{
    AuditAdministrativeAction, AuditAdministrativeMetadata, AuditApprovalOutcome, AuditError, AuditErrorCategory,
    AuditEvent, AuditOperationClass, AuditPreviewState, AuditRecordPhase, AuditSink, AuditState, AuditTerminalStatus,
    AuditTransactionOutcome, AuditTransportClient, AuditTransportMetadata, AuditTransportOutcome, NullAuditSink,
};
pub use blast_radius::{BlastRadiusResult, BlastRadiusRewrite, count_sql_for_mutation};
pub use classify::{StatementClass, StatementFacts, classify, statement_requires_write_capability};
pub use config::{EnvPolicy, MaskRule, PolicyConfig, WritePolicy, load_from_path};
pub use guard::{
    BulkBatch, BulkInsertEnd, BulkInsertRequest, BulkInsertScope, ConnectionFaultSink, GuardContext,
    MAX_BULK_ROW_BUDGET, PolicyGuard,
};
pub use mask::{DEFAULT_SENSITIVE_PATTERNS, apply_masking, column_is_sensitive};
pub use principal::Principal;
pub use rules::{Decision, evaluate};
pub use transaction_control::{TransactionControl, transaction_control};

pub fn panic_description(location: Option<(&str, u32)>) -> String {
    match location {
        Some((file, line)) => format!("a panic occurred at {file}:{line}; its message is withheld"),
        None => "a panic occurred; its message is withheld".to_string(),
    }
}

pub fn withhold_panic_messages() {
    if std::env::var_os("TABLEPRO_DEBUG_PANICS").is_some() {
        return;
    }
    std::panic::set_hook(Box::new(|info| {
        let location = info.location().map(|location| (location.file(), location.line()));
        tracing::error!("{}", panic_description(location));
    }));
}

#[cfg(test)]
mod panic_description_tests {
    use super::panic_description;

    #[test]
    fn the_description_names_where_but_never_what() {
        assert_eq!(
            panic_description(Some(("src/lib.rs", 42))),
            "a panic occurred at src/lib.rs:42; its message is withheld"
        );
        assert_eq!(panic_description(None), "a panic occurred; its message is withheld");
    }
}
