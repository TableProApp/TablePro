use super::*;
use relm4::ComponentSender;

impl SqlEditor {
    pub(super) fn export_name(&self) -> String {
        let buffer = self.source_view.buffer();
        let (start, end) = buffer.bounds();
        export_name_for_query(&buffer.text(&start, &end, true))
    }

    pub(super) fn metadata(&self) -> Option<ConnectionMetadata> {
        self.database.metadata(self.connection_id?)
    }

    pub(super) fn begin_run(&mut self, sql: String, single_statement: bool, sender: ComponentSender<Self>) {
        if self.session_teardown_active {
            return;
        }
        let driver_id = self.metadata().map(|metadata| metadata.driver_id).unwrap_or_default();
        let (statements, error_policy) = if single_statement {
            (
                vec![sql.clone()],
                tablepro_core::sql_syntax::script::BatchErrorPolicy::StopScript,
            )
        } else {
            match script_statements(&sql, &driver_id) {
                Ok(planned) => (planned.statements, planned.error_policy),
                Err(message) => {
                    self.status.set_label(&message);
                    return;
                }
            }
        };
        let names = crate::services::query_parameters::statement_names(&sql, &driver_id);
        if names.is_empty() {
            self.execute_sql(sql, statements, error_policy, std::collections::HashMap::new(), sender);
            return;
        }
        let Some(window) = self
            .source_view
            .root()
            .and_then(|root| root.downcast::<gtk::Window>().ok())
        else {
            self.status
                .set_label(&crate::tr!("Cannot ask for parameter values without a window"));
            return;
        };
        crate::ui::parameters_dialog::present(&window, &names, move |values| {
            sender.input(SqlEditorInput::RunWithParameters {
                sql: sql.clone(),
                statements: statements.clone(),
                error_policy,
                values,
            });
        });
    }

    pub(super) fn set_running(
        &self,
        running: bool,
        supports_server_cancellation: bool,
        sender: &ComponentSender<Self>,
    ) {
        self.run_button.set_sensitive(!running && !self.session_teardown_active);
        self.cancel_button
            .set_visible(show_cancel_button(running, supports_server_cancellation));
        self.running_spinner.set_visible(running);
        let _ = sender.output(SqlEditorOutput::RunStateChanged(running));
    }

    pub(super) fn finish_run(
        &mut self,
        generation: u64,
        sender: &ComponentSender<Self>,
    ) -> Option<(RunTerminal, ExecutionContext)> {
        let terminal = self.run_generation.finish(generation)?;
        let context = self.executions.remove(&generation)?;
        if terminal.became_idle {
            self.set_running(false, false, sender);
            if let Ok(elapsed) = context.started_at.elapsed() {
                finish_notice::notify_if_unattended(&self.source_view, elapsed);
            }
            self.try_start_session_teardown(sender);
        }
        Some((terminal, context))
    }

    pub(super) fn record_history(
        &self,
        context: ExecutionContext,
        duration_ms: i64,
        rows_affected: Option<i64>,
        outcome: Outcome,
    ) {
        let Some(history) = self.history.clone() else {
            return;
        };
        let entry = NewEntry {
            query: context.sql,
            driver_id: context.metadata.driver_id,
            connection_id: context.metadata.id,
            connection_name: context.metadata.name,
            executed_at: context.started_at,
            duration_ms: Some(duration_ms),
            rows_affected,
            outcome,
            source: tablepro_storage::query_history::Source::Editor,
        };
        relm4::spawn(async move {
            if let Err(e) = history.record(entry).await {
                tracing::warn!(error = %e, "history record failed");
            }
        });
    }
}
