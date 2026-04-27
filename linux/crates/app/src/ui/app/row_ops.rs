use relm4::adw::prelude::*;
use relm4::{ComponentController, ComponentSender};

use tablepro_core::Value;
use uuid::Uuid;

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
        sender: ComponentSender<App>,
    ) {
        let Some(conn) = crate::services::database_service::instance().active() else {
            self.dispatch_to_tab(tab_id, BrowseTabInput::SaveFailed(crate::tr!("No active connection")));
            return;
        };
        self.set_row_op_in_flight(true);
        let sender_for_cmd = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    match conn.execute_in_transaction(&statements).await {
                        Ok(_affected) => {
                            sender_for_cmd.input(AppMsg::RowOpStarted);
                            // Reuse the cell-edited "completed" path
                            // for spinner reset + tab notification.
                            sender_for_cmd.input(AppMsg::WorkspaceSchemaWordsChanged);
                            // Dispatch the per-tab SaveCompleted so the
                            // tab clears its tracker and refetches.
                            sender_for_cmd.input(AppMsg::SaveCompletedForTab(tab_id));
                        }
                        Err(e) => {
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
            let Some(super::WorkspaceTab::Browse(slot)) = tabs.get(&tab_id) else {
                return;
            };
            (
                slot.controller.model().columns().to_vec(),
                slot.controller.model().driver_id().to_string(),
                slot.controller.model().snapshot(),
                slot.controller.model().table().to_string(),
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
