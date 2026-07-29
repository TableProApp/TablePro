use relm4::adw::prelude::*;
use relm4::{ComponentController, ComponentSender};

use tablepro_core::{DriverError, Value};
use uuid::Uuid;

use crate::services::change_tracker::StatementSource;
use crate::ui::browse_tab::BrowseTabInput;
use crate::ui::error_text;

use super::{App, AppMsg};

impl App {
    /// Atomic Save handler for the inline-spreadsheet pattern.
    /// Receives a fully-materialised `Vec<(SQL, params)>` from a
    /// BrowseTab's `TabChangeTracker` and runs them all inside one
    /// transaction. On success, dispatches `BrowseTabInput::
    /// SaveCompleted` so the tab clears its tracker + refetches. On
    /// failure, the entire transaction has already been rolled back
    /// by the driver; we just surface the error message.
    pub(super) fn on_execute_browse_transaction(
        &self,
        tab_id: Uuid,
        statements: Vec<(String, Vec<Value>)>,
        sources: Vec<StatementSource>,
        sender: ComponentSender<App>,
    ) {
        let Some(conn) = crate::services::database_service::instance().active() else {
            self.dispatch_to_tab(tab_id, BrowseTabInput::SaveFailed(crate::tr!("No active connection")));
            return;
        };
        // Drivers that cannot report a row count for UPDATE / DELETE
        // return 0 for every statement, which the concurrency guard
        // below would read as "every row vanished". Skip the guard for
        // them rather than warn on every successful save.
        let reports_rows_affected = self
            .current_driver_id
            .as_ref()
            .and_then(|id| self.registry.get(id))
            .is_none_or(|driver| driver.reports_rows_affected());
        self.set_row_op_in_flight(true);
        // Increment the in-flight counter so window-close blocks until
        // the transaction resolves. Decrement happens in the
        // SaveCompletedForTab / SaveFailedForTab handlers regardless of
        // outcome.
        self.in_flight_saves.set(self.in_flight_saves.get() + 1);
        let sender_for_cmd = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    match conn.execute_in_transaction(&statements).await {
                        Ok(affected) => {
                            // Optimistic-concurrency guard: every UPDATE
                            // and DELETE in our materialised set targets
                            // a single PK-identified row, so each must
                            // affect exactly one row. Zero affected for
                            // any of them means the row was modified or
                            // deleted by another session between fetch
                            // and save. The transaction still committed
                            // — there's nothing to roll back — but the
                            // user must hear about it so a phantom save
                            // doesn't pass silently.
                            let warning = reports_rows_affected
                                .then(|| compute_concurrency_warning(&statements, &affected))
                                .flatten();
                            sender_for_cmd.input(AppMsg::RowOpStarted);
                            sender_for_cmd.input(AppMsg::WorkspaceSchemaWordsChanged);
                            sender_for_cmd.input(AppMsg::SaveCompletedForTab(tab_id, warning));
                        }
                        Err(e) => {
                            // If the driver pinpointed which statement
                            // failed, look up its source and ask the
                            // tab to scroll-and-select that row before
                            // showing the error dialog. The user sees
                            // the row in question without scanning the
                            // whole grid.
                            if let DriverError::Transaction { statement_index, .. } = &e
                                && let Some(source) = sources.get(*statement_index).cloned()
                            {
                                sender_for_cmd.input(AppMsg::FlashErrorRowForTab(tab_id, source));
                            }
                            let msg = error_text::driver_message(&e);
                            sender_for_cmd.input(AppMsg::SaveFailedForTab(tab_id, msg));
                        }
                    }
                })
                .drop_on_shutdown()
        });
    }

    pub(super) fn set_row_op_in_flight(&self, in_flight: bool) {
        self.row_op_spinner.set_visible(in_flight);
        if in_flight {
            self.row_op_spinner.start();
        } else {
            self.row_op_spinner.stop();
        }
    }

    pub(super) fn on_copy_row_as_insert(&self, tab_id: Uuid, row_position: u32) {
        let (columns, driver_id, snapshot, table) = {
            let tabs = self.workspace_tabs.borrow();
            let Some(controller) = tabs.get(&tab_id).and_then(|t| t.browse_controller()) else {
                return;
            };
            let model = controller.model();
            (
                model.columns().to_vec(),
                model.driver_id().to_string(),
                model.snapshot(),
                model.table().to_string(),
            )
        };
        let Some(snapshot) = snapshot else { return };
        let Some(row) = snapshot.rows.get(row_position as usize) else {
            return;
        };
        let cols: Vec<String> = columns
            .iter()
            .map(|c| tablepro_core::sql_dialect::quote_ident(&driver_id, &c.name))
            .collect();
        let values: Vec<String> = row.iter().map(format_sql_literal).collect();
        let sql = format!(
            "INSERT INTO {} ({}) VALUES ({});",
            tablepro_core::sql_dialect::quote_ident(&driver_id, &table),
            cols.join(", "),
            values.join(", "),
        );
        self.window.clipboard().set_text(&sql);
        self.show_toast(&crate::tr!("INSERT statement copied"));
    }

    pub(super) fn on_copy_to_clipboard(&self, text: String) {
        self.window.clipboard().set_text(&text);
        self.show_toast(&crate::tr!("Copied to clipboard"));
    }
}

/// Inspect the SQL prefix of each statement and compare its expected
/// affected-row count against the driver's reported count. Returns
/// `Some(message)` if any UPDATE / DELETE matched zero rows.
///
/// `materialize` always emits one UPDATE / DELETE per PK-identified
/// row, so each is expected to affect exactly one row. Zero means the
/// target row was modified or deleted out-of-band between fetch and
/// save. INSERTs are ignored — auto-increment / generated-column rows
/// can plausibly affect zero according to driver quirks (e.g. ON
/// CONFLICT DO NOTHING in user-extended SQL), and we don't produce
/// those today.
fn compute_concurrency_warning(statements: &[(String, Vec<Value>)], affected: &[u64]) -> Option<String> {
    let mut zero_updates = 0usize;
    let mut zero_deletes = 0usize;
    for (idx, (sql, _)) in statements.iter().enumerate() {
        let count = affected.get(idx).copied().unwrap_or(0);
        if count > 0 {
            continue;
        }
        let trimmed = sql.trim_start().to_ascii_uppercase();
        if trimmed.starts_with("UPDATE") {
            zero_updates += 1;
        } else if trimmed.starts_with("DELETE") {
            zero_deletes += 1;
        }
    }
    if zero_updates == 0 && zero_deletes == 0 {
        return None;
    }
    let total = zero_updates + zero_deletes;
    Some(
        crate::tr!("{n} rows could not be located. They may have been changed by another session. Refresh and review.")
            .replace("{n}", &total.to_string()),
    )
}

/// Render a `Value` as a SQL literal — used by the "Copy row as
/// INSERT" clipboard helper to produce a self-contained statement
/// that round-trips through any SQL client.
fn format_sql_literal(v: &Value) -> String {
    match v {
        Value::Null => "NULL".into(),
        Value::Bool(b) => b.to_string(),
        Value::Int(i) => i.to_string(),
        Value::Float(f) => f.to_string(),
        Value::Decimal(d) => d.to_string(),
        Value::Text(s) => format!("'{}'", s.replace('\'', "''")),
        Value::Bytes(_) => "/* bytes omitted */ NULL".into(),
        Value::Date(d) => format!("'{}'", d.format("%Y-%m-%d")),
        Value::Time(t) => format!("'{}'", t.format("%H:%M:%S")),
        Value::DateTime(dt) => format!("'{}'", dt.format("%Y-%m-%d %H:%M:%S")),
        Value::TimestampTz(ts) => format!("'{}'", ts.to_rfc3339()),
        Value::Uuid(u) => format!("'{u}'"),
        Value::Json(j) => format!("'{}'", j.to_string().replace('\'', "''")),
    }
}

#[cfg(test)]
mod tests {
    use super::compute_concurrency_warning;

    fn stmt(sql: &str) -> (String, Vec<tablepro_core::Value>) {
        (sql.to_string(), Vec::new())
    }

    #[test]
    fn warning_none_when_all_match() {
        let stmts = vec![stmt("UPDATE \"t\" SET …"), stmt("DELETE FROM \"t\" …")];
        assert!(compute_concurrency_warning(&stmts, &[1, 1]).is_none());
    }

    #[test]
    fn warning_present_when_update_matches_zero() {
        let stmts = vec![stmt("UPDATE \"t\" SET …"), stmt("DELETE FROM \"t\" …")];
        let w = compute_concurrency_warning(&stmts, &[0, 1]).unwrap();
        assert!(w.contains("1 rows"));
    }

    #[test]
    fn warning_counts_update_and_delete_zero_together() {
        let stmts = vec![stmt("UPDATE a"), stmt("DELETE FROM b"), stmt("UPDATE c")];
        let w = compute_concurrency_warning(&stmts, &[0, 0, 1]).unwrap();
        assert!(w.contains("2 rows"));
    }

    #[test]
    fn warning_ignores_zero_inserts() {
        // INSERT with affected=0 is unusual but not necessarily a phantom
        // — keep the warning specific to UPDATE / DELETE for now.
        let stmts = vec![stmt("INSERT INTO t (a) VALUES (?)"), stmt("UPDATE t SET …")];
        assert!(compute_concurrency_warning(&stmts, &[0, 1]).is_none());
    }

    #[test]
    fn warning_handles_lowercase_and_whitespace() {
        let stmts = vec![stmt("  update t set x = 1 where id = 5")];
        assert!(compute_concurrency_warning(&stmts, &[0]).is_some());
    }
}
