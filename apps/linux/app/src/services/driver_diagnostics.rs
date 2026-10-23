use tablepro_core::DriverError;

pub(crate) fn warn_driver_cleanup(error: &DriverError, operation: &'static str) {
    tracing::warn!(
        error_code = driver_code(error),
        operation,
        "database operation cleanup failed"
    );
}

pub(crate) fn warn_export_cleanup(error: &tablepro_core::export::ExportError, operation: &'static str) {
    use tablepro_core::export::ExportError;

    let error_code = match error {
        ExportError::Write(_) => "write",
        ExportError::Cancelled => "cancelled",
        ExportError::SqlLiteralsUnsupported { .. } => "sql_literals_unsupported",
        ExportError::MissingSqlTarget => "missing_sql_target",
        ExportError::Statement(_) => "statement",
        ExportError::WorkbookTooLarge { .. } => "workbook_row_limit",
        ExportError::WorkbookColumnLimit { .. } => "workbook_column_limit",
        ExportError::WorkbookEmptyText { .. } => "workbook_empty_text",
        ExportError::XmlCharacter { .. } => "xml_character",
        ExportError::HtmlCharacter { .. } => "html_character",
        ExportError::NullMarkerCollision { .. } => "null_marker_collision",
        ExportError::Source(_) => "source",
        ExportError::Workbook(_) => "workbook",
    };
    tracing::warn!(error_code, operation, "export source cleanup failed");
}

fn driver_code(error: &DriverError) -> &'static str {
    match error {
        DriverError::ConnectionRefused => "connection_refused",
        DriverError::AuthFailed => "authentication_failed",
        DriverError::Tls(_) => "tls",
        DriverError::Query { .. } => "query",
        DriverError::Disconnected => "disconnected",
        DriverError::ReadOnly => "read_only",
        DriverError::PolicyDenied(_) => "policy_denied",
        DriverError::Unsupported(_) => "unsupported",
        DriverError::Internal(_) => "internal",
        DriverError::Cancelled => "cancelled",
        DriverError::TimedOut => "timed_out",
        DriverError::ConcurrentModification => "concurrent_modification",
        DriverError::OperationOutcomeUnknown { .. } => "outcome_unknown",
        DriverError::IntegratedAuth(_) => "integrated_authentication_failed",
        DriverError::Transaction { .. } => "transaction_failed",
        DriverError::PartiallyApplied { .. } => "partially_applied",
        DriverError::TransactionRollbackFailed { .. } => "rollback_failed",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::sync::{Arc, Mutex};

    #[derive(Clone, Default)]
    struct Capture(Arc<Mutex<Vec<u8>>>);

    impl Write for Capture {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(bytes);
            Ok(bytes.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn cursor_cleanup_logs_codes_without_driver_payloads() {
        let capture = Capture::default();
        let writer = capture.clone();
        let subscriber = tracing_subscriber::fmt()
            .without_time()
            .with_ansi(false)
            .with_writer(move || writer.clone())
            .finish();
        let _guard = tracing::subscriber::set_default(subscriber);
        for operation in ["finish", "setup_rollback", "setup_close"] {
            for error in [
                DriverError::query("private-query-marker"),
                DriverError::Internal("private-query-marker".into()),
                DriverError::OperationOutcomeUnknown {
                    source: Box::new(DriverError::query("private-query-marker")),
                },
                DriverError::TransactionRollbackFailed {
                    statement_index: 0,
                    source: Box::new(DriverError::query("private-query-marker")),
                    rollback_error: Box::new(DriverError::query("private-query-marker")),
                },
            ] {
                warn_driver_cleanup(&error, operation);
            }
        }
        let output = String::from_utf8(capture.0.lock().unwrap().clone()).unwrap();
        assert!(!output.contains("private-query-marker"));
        for operation in ["finish", "setup_rollback", "setup_close"] {
            assert!(output.contains(operation));
        }
        for code in ["query", "internal", "outcome_unknown", "rollback_failed"] {
            assert!(output.contains(code));
        }
    }
}
