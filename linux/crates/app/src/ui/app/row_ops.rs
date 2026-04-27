use relm4::adw::prelude::*;
use relm4::{Component, ComponentController, ComponentSender, adw};

use tablepro_core::Value;
use tablepro_core::sql_dialect::{placeholder_for, quote_ident};
use uuid::Uuid;

use crate::ui::browse_tab::BrowseTabInput;
use crate::ui::edit_dialog::{EditDialog, EditDialogInit, EditDialogOutput};
use crate::ui::error_text;
use crate::ui::insert_dialog::{InsertDialog, InsertDialogInit, InsertDialogOutput};

use super::{
    App, AppMsg, UndoBatch, build_insert_for_row, execute_many_then_refetch_for_tab, execute_then_refetch_for_tab,
    preview_pk, value_to_sql_literal,
};

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

    pub(super) fn on_show_insert_dialog(
        &mut self,
        tab_id: Uuid,
        table: String,
        columns: Vec<tablepro_core::ColumnInfo>,
        driver_id: String,
        sender: ComponentSender<Self>,
    ) {
        let dialog = InsertDialog::builder()
            .launch(InsertDialogInit {
                table,
                columns,
                driver_id,
            })
            .forward(sender.input_sender(), move |out| match out {
                InsertDialogOutput::Inserted => AppMsg::InsertCommitted(tab_id),
            });
        dialog.widget().present(Some(&self.window));
        self.insert_dialog = Some(dialog);
    }

    pub(super) fn on_insert_committed(&mut self, tab_id: Uuid) {
        self.insert_dialog = None;
        self.show_toast(&crate::tr!("Row inserted"));
        self.dispatch_to_tab(tab_id, BrowseTabInput::Refresh);
    }

    pub(super) fn on_show_edit_dialog(
        &mut self,
        tab_id: Uuid,
        table: String,
        columns: Vec<tablepro_core::ColumnInfo>,
        driver_id: String,
        row: Vec<Value>,
        sender: ComponentSender<Self>,
    ) {
        let dialog = EditDialog::builder()
            .launch(EditDialogInit {
                table,
                columns,
                driver_id,
                row,
            })
            .forward(sender.input_sender(), move |out| match out {
                EditDialogOutput::Updated => AppMsg::EditCommitted(tab_id),
            });
        dialog.widget().present(Some(&self.window));
        self.edit_dialog = Some(dialog);
    }

    pub(super) fn on_edit_committed(&mut self, tab_id: Uuid) {
        self.edit_dialog = None;
        self.show_toast(&crate::tr!("Row updated"));
        self.dispatch_to_tab(tab_id, BrowseTabInput::Refresh);
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn on_confirm_delete_selected(
        &self,
        tab_id: Uuid,
        table: String,
        columns: Vec<tablepro_core::ColumnInfo>,
        driver_id: String,
        positions: Vec<u32>,
        rows: Vec<Vec<Value>>,
        sender: ComponentSender<Self>,
    ) {
        let pk_indexes: Vec<usize> = columns
            .iter()
            .enumerate()
            .filter(|(_, c)| c.primary_key)
            .map(|(i, _)| i)
            .collect();
        if pk_indexes.is_empty() {
            self.show_error_alert(
                &crate::tr!("Cannot delete"),
                &error_text::build_sql_message(&tablepro_core::sql_dialect::BuildSqlError::NoPrimaryKey),
            );
            return;
        }
        let preview = if positions.len() == 1 {
            let row = &rows[positions[0] as usize];
            crate::tr!("Delete row where {pk}?").replace("{pk}", &preview_pk(&columns, &pk_indexes, row))
        } else {
            crate::tr!("Delete {n} rows?").replace("{n}", &positions.len().to_string())
        };
        let confirm_label = if positions.len() == 1 {
            crate::tr!("Delete")
        } else {
            crate::tr!("Delete {n}").replace("{n}", &positions.len().to_string())
        };
        self.confirm_and_execute_many(
            tab_id,
            sender,
            &table,
            &driver_id,
            &columns,
            &pk_indexes,
            &positions,
            &rows,
            &preview,
            &confirm_label,
        );
    }

    pub(super) fn on_cell_edited(
        &self,
        tab_id: Uuid,
        table: String,
        row_position: u32,
        col_index: usize,
        new_value: String,
        sender: ComponentSender<Self>,
    ) {
        let (columns, driver_id, snapshot) = {
            let tabs = self.workspace_tabs.borrow();
            let Some(super::WorkspaceTab::Browse(slot)) = tabs.get(&tab_id) else {
                return;
            };
            (
                slot.controller.model().columns().to_vec(),
                slot.controller.model().driver_id().to_string(),
                slot.controller.model().snapshot(),
            )
        };
        let Some(snapshot) = snapshot else { return };
        let Some(row) = snapshot.rows.get(row_position as usize).cloned() else {
            return;
        };
        if col_index >= columns.len() {
            return;
        }
        let col = &columns[col_index];
        let value = if new_value.is_empty() && col.nullable {
            Value::Null
        } else {
            Value::Text(new_value)
        };
        let original_value = row[col_index].clone();
        let (sql, params) = match tablepro_core::sql_dialect::build_single_cell_update(
            &driver_id, &table, &columns, &row, col_index, value,
        ) {
            Ok(t) => t,
            Err(e) => {
                self.show_error_alert(&crate::tr!("Cannot update cell"), &error_text::build_sql_message(&e));
                return;
            }
        };
        let undo = tablepro_core::sql_dialect::build_single_cell_update(
            &driver_id,
            &table,
            &columns,
            &row,
            col_index,
            original_value,
        )
        .ok()
        .map(|(s, p)| UndoBatch {
            label: crate::tr!("Cell updated"),
            statements: vec![(s, p)],
        });
        self.set_row_op_in_flight(true);
        execute_then_refetch_for_tab(tab_id, sender, sql, params, undo);
    }

    pub(super) fn on_set_cell_null(
        &self,
        tab_id: Uuid,
        table: String,
        row_position: u32,
        col_index: usize,
        sender: ComponentSender<Self>,
    ) {
        let (columns, driver_id, snapshot) = {
            let tabs = self.workspace_tabs.borrow();
            let Some(super::WorkspaceTab::Browse(slot)) = tabs.get(&tab_id) else {
                return;
            };
            (
                slot.controller.model().columns().to_vec(),
                slot.controller.model().driver_id().to_string(),
                slot.controller.model().snapshot(),
            )
        };
        let Some(snapshot) = snapshot else { return };
        let Some(row) = snapshot.rows.get(row_position as usize).cloned() else {
            return;
        };
        if col_index >= columns.len() {
            return;
        }
        let original_value = row[col_index].clone();
        let (sql, params) = match tablepro_core::sql_dialect::build_single_cell_update(
            &driver_id,
            &table,
            &columns,
            &row,
            col_index,
            Value::Null,
        ) {
            Ok(t) => t,
            Err(e) => {
                self.show_error_alert(&crate::tr!("Cannot set NULL"), &error_text::build_sql_message(&e));
                return;
            }
        };
        let undo = tablepro_core::sql_dialect::build_single_cell_update(
            &driver_id,
            &table,
            &columns,
            &row,
            col_index,
            original_value,
        )
        .ok()
        .map(|(s, p)| UndoBatch {
            label: crate::tr!("Cell cleared"),
            statements: vec![(s, p)],
        });
        self.set_row_op_in_flight(true);
        execute_then_refetch_for_tab(tab_id, sender, sql, params, undo);
    }

    pub(super) fn on_delete_row_at(
        &self,
        tab_id: Uuid,
        table: String,
        row_position: u32,
        sender: ComponentSender<Self>,
    ) {
        let (columns, driver_id, snapshot) = {
            let tabs = self.workspace_tabs.borrow();
            let Some(super::WorkspaceTab::Browse(slot)) = tabs.get(&tab_id) else {
                return;
            };
            (
                slot.controller.model().columns().to_vec(),
                slot.controller.model().driver_id().to_string(),
                slot.controller.model().snapshot(),
            )
        };
        let Some(snapshot) = snapshot else { return };
        let pk_indexes: Vec<usize> = columns
            .iter()
            .enumerate()
            .filter(|(_, c)| c.primary_key)
            .map(|(i, _)| i)
            .collect();
        if pk_indexes.is_empty() {
            self.show_error_alert(
                &crate::tr!("Cannot delete"),
                &error_text::build_sql_message(&tablepro_core::sql_dialect::BuildSqlError::NoPrimaryKey),
            );
            return;
        }
        let preview = snapshot
            .rows
            .get(row_position as usize)
            .map(|r| crate::tr!("Delete row where {pk}?").replace("{pk}", &preview_pk(&columns, &pk_indexes, r)))
            .unwrap_or_else(|| crate::tr!("Delete row?"));
        self.confirm_and_execute_many(
            tab_id,
            sender,
            &table,
            &driver_id,
            &columns,
            &pk_indexes,
            &[row_position],
            &snapshot.rows,
            &preview,
            &crate::tr!("Delete"),
        );
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
        let values: Vec<String> = row.iter().map(value_to_sql_literal).collect();
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

    #[allow(clippy::too_many_arguments)]
    fn confirm_and_execute_many(
        &self,
        tab_id: Uuid,
        sender: ComponentSender<Self>,
        table: &str,
        driver_id: &str,
        columns: &[tablepro_core::ColumnInfo],
        pk_indexes: &[usize],
        positions: &[u32],
        rows: &[Vec<Value>],
        preview: &str,
        confirm_label: &str,
    ) {
        let where_clause: String = pk_indexes
            .iter()
            .enumerate()
            .map(|(i, col_idx)| {
                let name = &columns[*col_idx].name;
                let placeholder = placeholder_for(driver_id, i);
                format!("{} = {}", quote_ident(driver_id, name), placeholder)
            })
            .collect::<Vec<_>>()
            .join(" AND ");
        let sql = format!("DELETE FROM {} WHERE {}", quote_ident(driver_id, table), where_clause);

        let mut batches: Vec<Vec<Value>> = Vec::with_capacity(positions.len());
        let mut undo_statements: Vec<(String, Vec<Value>)> = Vec::with_capacity(positions.len());
        for pos in positions {
            let Some(row) = rows.get(*pos as usize) else {
                continue;
            };
            batches.push(pk_indexes.iter().map(|i| row[*i].clone()).collect());
            undo_statements.push(build_insert_for_row(driver_id, table, columns, row));
        }

        let undo_label = if positions.len() == 1 {
            crate::tr!("1 row deleted")
        } else {
            crate::tr!("{n} rows deleted").replace("{n}", &positions.len().to_string())
        };
        let undo = if undo_statements.is_empty() {
            None
        } else {
            Some(UndoBatch {
                label: undo_label,
                statements: undo_statements,
            })
        };

        if !crate::services::preferences::load().confirm_destructive {
            sender.input(AppMsg::RowOpStarted);
            execute_many_then_refetch_for_tab(tab_id, sender, sql, batches, undo);
            return;
        }

        let alert_title = if positions.len() == 1 {
            crate::tr!("Delete row?")
        } else {
            crate::tr!("Delete {n} rows?").replace("{n}", &positions.len().to_string())
        };
        let dialog = adw::AlertDialog::new(Some(&alert_title), Some(preview));
        dialog.add_response("cancel", &crate::tr!("Cancel"));
        dialog.add_response("delete", confirm_label);
        dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");

        let sender_clone = sender;
        dialog.connect_response(None, move |dialog, response| {
            dialog.close();
            if response != "delete" {
                return;
            }
            let sql = sql.clone();
            let batches = batches.clone();
            let undo = undo.clone();
            sender_clone.input(AppMsg::RowOpStarted);
            execute_many_then_refetch_for_tab(tab_id, sender_clone.clone(), sql, batches, undo);
        });
        dialog.present(Some(&self.window));
    }
}
