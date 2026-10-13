use relm4::ComponentSender;
use relm4::adw::prelude::*;

use tablepro_core::meta::TableRef;
use tablepro_core::save::{SavePlan, plan_save};
use tablepro_core::{ColumnInfo, DriverError, WriteKind};
use tablepro_session::runtime::Tasks;
use tablepro_session::{OperationError, OperationKind};
use uuid::Uuid;

use crate::services::change_tracker::{StatementSource, TrackedChanges, pk_identity};
use crate::ui::browse_tab::BrowseTabInput;
use crate::ui::error_text;

use super::ran_statements::RanStatements;
use super::{App, AppMsg};

impl App {
    /// Save a browse tab's pending changes as one batch.
    ///
    /// The plan is built inside the operation from the connection it
    /// runs on, so the SQL matches that server even after a reconnect.
    /// Every update and delete carries a row guard: a row another
    /// session changed or removed fails the whole save rather than
    /// passing as a save that touched nothing.
    pub(super) fn on_execute_browse_transaction(
        &self,
        tab_id: Uuid,
        table: TableRef,
        columns: Vec<ColumnInfo>,
        changes: TrackedChanges,
        sender: ComponentSender<App>,
    ) {
        let Some(session) = self.context.active.get() else {
            self.dispatch_to_tab(
                tab_id,
                BrowseTabInput::SaveFailed(crate::i18n::gettext("No active connection")),
            );
            return;
        };
        self.set_row_op_in_flight(true);
        // Window-close waits while this is above zero, so a save never
        // commits after its tab is gone. SaveCompletedForTab and
        // SaveFailedForTab bring it back down whatever the outcome.
        self.in_flight_saves.set(self.in_flight_saves.get() + 1);
        let history = self.history.store();
        let connection = self.context.active.metadata();
        let work = async move {
            let changes_for_plan = changes.changes.clone();
            let saved = session
                .run(OperationKind::Save(WriteKind::RowChanges), move |lease, options| {
                    let table = table.clone();
                    let columns = columns.clone();
                    let changes = changes_for_plan.clone();
                    async move {
                        let plan = plan_save(&*lease.dialect(), &table, &columns, &pk_identity(&columns), &changes)?;
                        // A row save changes the database, so it belongs
                        // in the same history as a statement run from the
                        // editor.
                        let sql: Vec<String> = plan
                            .batch
                            .steps
                            .iter()
                            .map(|step| step.statement.sql().to_owned())
                            .collect();
                        let outcome = lease.write_batch(&plan.batch, options).await;
                        Ok((plan, sql, outcome))
                    }
                })
                .await;
            (saved, changes)
        };
        let tasks = self.context.tasks.clone();
        let history_tasks = tasks.clone();
        let _delivery = crate::runtime::spawn_and_deliver(&tasks, work, move |finished| {
            let (saved, changes) = match finished {
                Ok(finished) => finished,
                Err(failure) => {
                    tracing::warn!(%failure, "the save task did not finish");
                    sender.input(AppMsg::SaveFailedForTab(
                        tab_id,
                        crate::i18n::gettext("The save did not finish."),
                    ));
                    return;
                }
            };
            let (plan, sql, outcome) = match saved {
                Ok(planned) => planned,
                Err(error) => {
                    sender.input(AppMsg::SaveFailedForTab(
                        tab_id,
                        error_text::operation_error_message(&error),
                    ));
                    return;
                }
            };
            let ran = RanStatements::starting(history, connection, sql);
            match outcome {
                Ok(report) => {
                    let touched = report.total_rows();
                    record(
                        &history_tasks,
                        ran,
                        touched.and_then(|rows| i64::try_from(rows).ok()),
                        None,
                    );
                    sender.input(AppMsg::SaveCompletedForTab(tab_id));
                }
                Err(error) => {
                    // The row behind the failing step is flashed before
                    // the error shows, so the user sees which one it was.
                    if let Some(source) = failing_source(&plan, &changes, &error) {
                        sender.input(AppMsg::FlashErrorRowForTab(tab_id, source));
                    }
                    let message = error_text::operation_error_message(&OperationError::Driver(error));
                    record(&history_tasks, ran, None, Some(message.clone()));
                    sender.input(AppMsg::SaveFailedForTab(tab_id, message));
                }
            }
        });
    }

    pub(super) fn set_row_op_in_flight(&self, in_flight: bool) {
        self.row_op_spinner.set_visible(in_flight);
    }

    pub(super) fn on_copy_row_as_insert(&self, tab_id: Uuid, row_position: u32) {
        let Some(browse) = self
            .workspace_tabs
            .borrow()
            .get(&tab_id)
            .and_then(|t| t.browse_tab())
            .cloned()
        else {
            return;
        };
        let (columns, snapshot, table) = (browse.columns(), browse.snapshot(), browse.table());
        let Some(snapshot) = snapshot else { return };
        let Some(row) = snapshot.rows.get(row_position as usize) else {
            return;
        };
        let Some(dialect) = self.context.active.get().and_then(|session| session.current_dialect()) else {
            self.show_toast(&crate::i18n::gettext("Connect to a database first."));
            return;
        };
        let result_columns: Vec<_> = columns.iter().map(|column| column.result_column()).collect();
        let sql =
            tablepro_core::export::render_sql_insert(&*dialect, &table, &result_columns, std::slice::from_ref(row));
        let sql = sql.trim_end().to_owned();
        self.window.clipboard().set_text(&sql);
        self.show_toast(&crate::i18n::gettext("INSERT statement copied"));
    }

    pub(super) fn on_copy_to_clipboard(&self, text: String) {
        self.window.clipboard().set_text(&text);
        self.show_toast(&crate::i18n::gettext("Copied to clipboard"));
    }
}

/// The grid row behind the statement a save failed at, when the
/// engine said which one it was.
fn failing_source(plan: &SavePlan, changes: &TrackedChanges, error: &DriverError) -> Option<StatementSource> {
    let step = match error {
        DriverError::RolledBack { statement_index, .. }
        | DriverError::RowGuardFailed { statement_index, .. }
        | DriverError::GuardUnsupported { statement_index }
        | DriverError::PartiallyApplied { statement_index, .. } => *statement_index,
        _ => return None,
    };
    changes.source(plan.origin(step)?)
}

/// Record a save in the history. The history database needs the
/// runtime, and a history that cannot be written is worth a log line,
/// never a lost edit, so nothing waits for it.
fn record(tasks: &Tasks, ran: RanStatements, rows_affected: Option<i64>, failure: Option<String>) {
    let outcome = match failure {
        None => tablepro_storage::query_history::Outcome::Success,
        Some(message) => tablepro_storage::query_history::Outcome::Error(message),
    };
    drop(tasks.spawn_task(ran.finished(rows_affected, outcome)));
}

#[cfg(test)]
mod tests {
    use tablepro_core::Value;
    use tablepro_core::column::{ColumnDefault, ColumnKind, ColumnType, IntegerKind, IntegerWidth};

    use super::*;
    use crate::services::change_tracker::RowKey;
    use crate::services::tab_tracker_handle::TabTrackerHandle;
    use crate::services::tracker_edit::TrackerEdit;

    fn column(name: &str, primary_key: bool) -> ColumnInfo {
        let mut column_type = ColumnType::untyped_text("integer");
        column_type.kind = ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W32,
            signed: true,
        });
        ColumnInfo {
            name: name.to_owned(),
            column_type,
            nullable: false,
            primary_key,
            is_auto_increment: false,
            is_generated: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn planned() -> (SavePlan, TrackedChanges, RowKey) {
        let columns = vec![column("id", true), column("n", false)];
        let edited = RowKey::from_pk_values(&[Value::Int(3)]).unwrap();
        let tracker = TabTrackerHandle::default();
        let _ = tracker.apply(TrackerEdit::Insert {
            values: vec![Value::Int(10), Value::Int(1)],
        });
        let _ = tracker.apply(TrackerEdit::Cell {
            row_key: edited.clone(),
            col: 1,
            original: Value::Int(1),
            value: Value::Int(2),
        });
        let changes = tracker.change_set(&columns).unwrap();
        let dialect = drivers_sqlite::SqliteDialect::new(drivers_sqlite::SqliteVersion::new(3, 45, 0));
        let plan = plan_save(
            &dialect,
            &TableRef::unqualified("t"),
            &columns,
            &pk_identity(&columns),
            &changes.changes,
        )
        .unwrap();
        (plan, changes, edited)
    }

    #[test]
    fn a_guard_failure_flashes_the_row_it_was_about() {
        let (plan, changes, edited) = planned();
        let error = DriverError::RowGuardFailed {
            statement_index: 1,
            expected: 1,
            actual: 0,
        };

        let source = failing_source(&plan, &changes, &error);

        assert!(matches!(source, Some(StatementSource::Update { row_key }) if row_key == edited));
    }

    #[test]
    fn a_rolled_back_insert_flashes_its_draft() {
        let (plan, changes, _) = planned();
        let error = DriverError::RolledBack {
            statement_index: 0,
            source: Box::new(DriverError::server("duplicate key")),
        };

        assert!(matches!(
            failing_source(&plan, &changes, &error),
            Some(StatementSource::Insert { .. })
        ));
    }

    #[test]
    fn an_error_that_names_no_statement_flashes_nothing() {
        let (plan, changes, _) = planned();

        assert!(failing_source(&plan, &changes, &DriverError::Busy).is_none());
        let past_the_end = DriverError::RowGuardFailed {
            statement_index: 7,
            expected: 1,
            actual: 0,
        };
        assert!(failing_source(&plan, &changes, &past_the_end).is_none());
    }
}
