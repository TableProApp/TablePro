use super::super::session_mode::StatementTarget;
use super::{ScriptRunResult, StatementOutcomeKind, StatementRun, run_statements_with_stream};
use tablepro_core::sql_syntax::script::LexicalSettings;

struct SqlModeSession {
    executed: std::sync::Arc<std::sync::Mutex<Vec<String>>>,
    settings: LexicalSettings,
}

#[async_trait::async_trait]
impl tablepro_core::Session for SqlModeSession {
    async fn query_params_controlled(
        &mut self,
        sql: &str,
        _params: &[tablepro_core::Value],
        _control: &tablepro_core::OperationControl,
    ) -> Result<tablepro_core::QueryResult, tablepro_core::DriverError> {
        self.executed.lock().unwrap().push(sql.to_owned());
        if let Some(mode) = sql.strip_prefix("SET SESSION sql_mode = ") {
            self.settings = LexicalSettings::from_mysql_sql_mode(mode.trim_matches('\''));
        }
        Ok(tablepro_core::QueryResult {
            columns: Vec::new(),
            rows: Vec::new(),
            truncated: false,
        })
    }

    async fn lexical_settings_controlled(
        &mut self,
        _control: &tablepro_core::OperationControl,
    ) -> Result<Option<LexicalSettings>, tablepro_core::DriverError> {
        Ok(Some(self.settings))
    }

    fn is_usable(&self) -> bool {
        true
    }

    async fn close(self: Box<Self>) -> Result<(), tablepro_core::DriverError> {
        Ok(())
    }
}

async fn run_in_sql_mode(sql_mode: &str, script: &str) -> (Vec<String>, Vec<StatementOutcomeKind>) {
    let settings = LexicalSettings::from_mysql_sql_mode(sql_mode);
    let planned = super::super::statement_cursor::script_statements(
        script,
        super::super::statement_cursor::Lexing {
            driver: "mysql",
            settings: Some(settings),
        },
    )
    .expect("the script plans under the session's settings");
    let executed = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let session: Box<dyn tablepro_core::Session> = Box::new(SqlModeSession {
        executed: executed.clone(),
        settings,
    });
    let target = StatementTarget::Session {
        id: uuid::Uuid::new_v4(),
        shared: std::sync::Arc::new(tokio::sync::Mutex::new(Some(session))),
    };
    let result = run_statements_with_stream(
        StatementRun {
            target,
            statements: planned.statements,
            driver_id: "mysql",
            parameter_values: &Default::default(),
            control: &crate::services::operation_control::bounded(30),
            error_policy: planned.error_policy,
            settings_check: planned.settings_check,
            succeeded: |_: &str| {},
        },
        |_| async { false },
    )
    .await;
    let ScriptRunResult::Completed(outcomes) = result else {
        panic!("the script completes");
    };
    let executed = executed.lock().unwrap().clone();
    (executed, outcomes.into_iter().map(|outcome| outcome.kind).collect())
}

#[tokio::test]
async fn a_script_split_under_no_backslash_escapes_runs_each_statement_once() {
    let (executed, outcomes) = run_in_sql_mode("NO_BACKSLASH_ESCAPES", r"SELECT 'path\'; SELECT 2;").await;
    assert_eq!(executed, [r"SELECT 'path\'", "SELECT 2"]);
    assert!(
        outcomes
            .iter()
            .all(|kind| matches!(kind, StatementOutcomeKind::Rows(_)))
    );
}

#[tokio::test]
async fn a_statement_that_changes_how_strings_split_stops_the_rest_of_the_script() {
    let script = "SET SESSION sql_mode = 'NO_BACKSLASH_ESCAPES';\nSELECT 'x\\'; SELECT 2; -- '";
    let (executed, outcomes) = run_in_sql_mode("", script).await;
    assert_eq!(executed, ["SET SESSION sql_mode = 'NO_BACKSLASH_ESCAPES'"]);
    let [StatementOutcomeKind::Rows(_), StatementOutcomeKind::Error(reason)] = outcomes.as_slice() else {
        panic!("unexpected outcomes {outcomes:?}");
    };
    assert!(reason.starts_with("Not run:"), "{reason}");
}

#[tokio::test]
async fn a_script_that_splits_the_same_under_every_setting_is_not_checked_between_statements() {
    let script = "SET SESSION sql_mode = 'ANSI_QUOTES';\nSELECT 'plain'; SELECT 2";
    let (executed, outcomes) = run_in_sql_mode("", script).await;
    assert_eq!(executed.len(), 3);
    assert!(
        outcomes
            .iter()
            .all(|kind| matches!(kind, StatementOutcomeKind::Rows(_)))
    );
}
