use relm4::adw::prelude::*;
use relm4::gtk::gio;
use relm4::{ComponentController, ComponentSender, adw, gtk};

use tablepro_core::{ColumnInfo, QueryResult};
use uuid::Uuid;

use crate::services::database_service;
use crate::ui::browse_tab::BrowseTabInput;

use super::{App, AppMsg, ExportFormat, OpenMode, render_csv, render_json};

impl App {
    /// Sidebar click — routes via OpenMode (smart switch / new tab).
    pub(super) fn on_select_table(
        &mut self,
        schema: Option<String>,
        name: String,
        open_mode: OpenMode,
        sender: ComponentSender<Self>,
    ) {
        self.dispatch_select_table(schema, name, open_mode, sender);
    }

    /// Fire the SELECT * query for a specific browse tab. Result goes to
    /// the same tab via `AppMsg::RowsLoaded(tab_id, ...)`. Composes the
    /// SELECT from the tab's current sort + filter + pagination state.
    /// Filter and sort are server-side; pagination uses LIMIT/OFFSET.
    pub(super) fn fetch_browse_page(&self, tab_id: Uuid, sender: ComponentSender<Self>) {
        let (schema, table, offset, limit, sort, filter, columns, driver_id) = {
            let tabs = self.workspace_tabs.borrow();
            let Some(controller) = tabs.get(&tab_id).and_then(|t| t.browse_controller()) else {
                return;
            };
            let model = controller.model();
            (
                model.schema().map(str::to_owned),
                model.table().to_string(),
                model.current_offset(),
                model.page_size(),
                model.current_sort(),
                model.current_filter().clone(),
                model.columns().to_vec(),
                model.driver_id().to_string(),
            )
        };

        let Some(conn) = database_service::instance().active() else {
            sender.input(AppMsg::LoadFailed(Some(tab_id), "no active connection".into()));
            return;
        };
        let order_by = sort.and_then(|(idx, asc)| {
            columns.get(idx).map(|c| {
                let name = tablepro_core::sql_dialect::quote_ident(&driver_id, &c.name);
                let dir = if asc { "ASC" } else { "DESC" };
                format!("{name} {dir}")
            })
        });

        // Build WHERE up front so a filter validation error short-
        // circuits to a toast without spawning the async command.
        // Build returns None when the filter is empty; that path
        // matches today's no-filter behaviour exactly.
        let where_result = tablepro_core::build_filter_where(&driver_id, &columns, &filter);
        let (where_sql, params) = match where_result {
            Ok(Some((sql, p))) => (Some(sql), p),
            Ok(None) => (None, Vec::new()),
            Err(e) => {
                sender.input(AppMsg::ShowToast(format!("{e}")));
                return;
            }
        };

        let sender_clone = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    // No WHERE + no ORDER BY: keep the existing
                    // fetch_rows fast-path so unchanged callers don't
                    // pay the parametric overhead.
                    let result = if where_sql.is_none() && order_by.is_none() {
                        conn.fetch_rows(schema.as_deref(), &table, offset, limit).await
                    } else {
                        let qualified = match &schema {
                            Some(s) => format!(
                                "{}.{}",
                                tablepro_core::sql_dialect::quote_ident(&driver_id, s),
                                tablepro_core::sql_dialect::quote_ident(&driver_id, &table)
                            ),
                            None => tablepro_core::sql_dialect::quote_ident(&driver_id, &table),
                        };
                        let mut sql = format!("SELECT * FROM {qualified}");
                        if let Some(w) = &where_sql {
                            sql.push_str(" WHERE ");
                            sql.push_str(w);
                        }
                        if let Some(order) = &order_by {
                            sql.push_str(" ORDER BY ");
                            sql.push_str(order);
                        }
                        sql.push_str(&format!(" LIMIT {limit} OFFSET {offset}"));
                        conn.query_params(&sql, &params).await
                    };
                    match result {
                        Ok(query_result) => sender_clone.input(AppMsg::RowsLoaded(tab_id, offset, query_result)),
                        Err(e) => sender_clone.input(AppMsg::LoadFailed(
                            Some(tab_id),
                            crate::ui::error_text::driver_message(&e),
                        )),
                    }
                })
                .drop_on_shutdown()
        });
    }

    pub(super) fn fetch_browse_columns(&self, tab_id: Uuid, sender: ComponentSender<Self>) {
        let (schema, table) = {
            let tabs = self.workspace_tabs.borrow();
            let Some(controller) = tabs.get(&tab_id).and_then(|t| t.browse_controller()) else {
                return;
            };
            let model = controller.model();
            (model.schema().map(str::to_owned), model.table().to_string())
        };

        let Some(conn) = database_service::instance().active() else {
            return;
        };
        let sender_clone = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    if let Ok(columns) = conn.fetch_columns(schema.as_deref(), &table).await {
                        sender_clone.input(AppMsg::ColumnsLoaded(tab_id, columns));
                    }
                })
                .drop_on_shutdown()
        });
    }

    pub(super) fn fetch_browse_row_count(&self, tab_id: Uuid, sender: ComponentSender<Self>) {
        let (schema, table, filter, columns, driver_id) = {
            let tabs = self.workspace_tabs.borrow();
            let Some(controller) = tabs.get(&tab_id).and_then(|t| t.browse_controller()) else {
                return;
            };
            let model = controller.model();
            (
                model.schema().map(str::to_owned),
                model.table().to_string(),
                model.current_filter().clone(),
                model.columns().to_vec(),
                model.driver_id().to_string(),
            )
        };

        let Some(conn) = database_service::instance().active() else {
            return;
        };

        // Same WHERE the page fetch uses, so the "of N" total matches
        // the filtered result set. Validation errors are silently
        // suppressed here — fetch_browse_page surfaces the toast for
        // the same filter on the same tick, no need to double-toast.
        let (where_sql, params) = match tablepro_core::build_filter_where(&driver_id, &columns, &filter) {
            Ok(Some((sql, p))) => (Some(sql), p),
            _ => (None, Vec::new()),
        };

        let sender_clone = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    let qualified = match schema {
                        Some(s) => format!(
                            "{}.{}",
                            tablepro_core::sql_dialect::quote_ident(&driver_id, &s),
                            tablepro_core::sql_dialect::quote_ident(&driver_id, &table)
                        ),
                        None => tablepro_core::sql_dialect::quote_ident(&driver_id, &table),
                    };
                    let mut sql = format!("SELECT COUNT(*) FROM {qualified}");
                    if let Some(w) = &where_sql {
                        sql.push_str(" WHERE ");
                        sql.push_str(w);
                    }
                    let qr_result = if where_sql.is_some() {
                        conn.query_params(&sql, &params).await
                    } else {
                        conn.query(&sql).await
                    };
                    if let Ok(qr) = qr_result
                        && let Some(row) = qr.rows.first()
                        && let Some(value) = row.first()
                    {
                        let count = match value {
                            tablepro_core::Value::Int(i) if *i >= 0 => Some(*i as u64),
                            tablepro_core::Value::Float(f) if *f >= 0.0 && f.is_finite() => Some(*f as u64),
                            tablepro_core::Value::Decimal(d) => d.to_string().parse::<u64>().ok(),
                            _ => None,
                        };
                        if let Some(count) = count {
                            sender_clone.input(AppMsg::RowCountLoaded(tab_id, count));
                        }
                    }
                })
                .drop_on_shutdown()
        });
    }

    pub(super) fn on_browse_columns_loaded(&self, tab_id: Uuid, columns: Vec<ColumnInfo>) {
        self.dispatch_to_tab(tab_id, BrowseTabInput::ColumnsLoaded(columns));
    }

    pub(super) fn on_browse_rows_loaded(&self, tab_id: Uuid, offset: u64, result: QueryResult) {
        self.dispatch_to_tab(tab_id, BrowseTabInput::RowsLoaded { offset, result });
    }

    pub(super) fn on_browse_row_count_loaded(&self, tab_id: Uuid, count: u64) {
        self.dispatch_to_tab(tab_id, BrowseTabInput::RowCountLoaded(count));
    }

    pub(super) fn on_browse_load_failed(&mut self, tab_id: Option<Uuid>, msg: String) {
        match tab_id {
            Some(id) => self.dispatch_to_tab(id, BrowseTabInput::ShowError(msg)),
            None => {
                tracing::warn!(error = %msg, "app-level load failed");
                // Connect attempt failed → drop the in-progress toast so
                // the alert isn't competing with stale "Connecting…" UI.
                self.dismiss_loading_page();
                self.set_status_page(super::StatusKind::Error, &crate::tr!("Failed"), &msg);
            }
        }
    }

    pub(super) fn on_export(&self, format: ExportFormat) {
        let Some((schema, table)) = self.selected_browse_slot_table() else {
            self.show_toast(&crate::tr!("Nothing to export"));
            return;
        };
        let Some(active_id) = self.selected_browse_tab_id() else {
            self.show_toast(&crate::tr!("Nothing to export"));
            return;
        };
        let result = {
            let tabs = self.workspace_tabs.borrow();
            tabs.get(&active_id)
                .and_then(|t| t.browse_controller())
                .and_then(|c| c.model().snapshot())
        };
        let Some(result) = result else {
            self.show_toast(&crate::tr!("Nothing to export"));
            return;
        };
        let table_label = match &schema {
            Some(s) => format!("{s}.{table}"),
            None => table.clone(),
        };
        let suggested = match format {
            ExportFormat::Csv => format!("{table_label}.csv"),
            ExportFormat::Json => format!("{table_label}.json"),
        };
        let filter = gtk::FileFilter::new();
        match format {
            ExportFormat::Csv => {
                filter.set_name(Some(&crate::tr!("CSV files")));
                filter.add_mime_type("text/csv");
                filter.add_suffix("csv");
            }
            ExportFormat::Json => {
                filter.set_name(Some(&crate::tr!("JSON files")));
                filter.add_mime_type("application/json");
                filter.add_suffix("json");
            }
        };
        let filters = gio::ListStore::new::<gtk::FileFilter>();
        filters.append(&filter);
        let dialog = gtk::FileDialog::builder()
            .title(match format {
                ExportFormat::Csv => crate::tr!("Export as CSV"),
                ExportFormat::Json => crate::tr!("Export as JSON"),
            })
            .modal(true)
            .initial_name(&suggested)
            .default_filter(&filter)
            .filters(&filters)
            .build();
        let parent = self.window.clone();
        let parent_for_alert = parent.clone();
        let toast_overlay = self.toast_overlay.clone();
        dialog.save(Some(&parent), gtk::gio::Cancellable::NONE, move |outcome| {
            let Ok(file) = outcome else { return };
            let Some(path) = file.path() else { return };
            let bytes = match format {
                ExportFormat::Csv => render_csv(&result),
                ExportFormat::Json => render_json(&result),
            };
            match std::fs::write(&path, bytes) {
                Ok(()) => toast_overlay.add_toast(relm4::adw::Toast::new(
                    &crate::tr!("Exported to {path}").replace("{path}", &path.display().to_string()),
                )),
                // Failures use AdwAlertDialog instead of a transient
                // toast — the user needs time to read the IO error
                // (and probably copy the path to retry elsewhere).
                // Matches the Save / Drop error-handling pattern.
                Err(e) => {
                    let alert = adw::AlertDialog::new(
                        Some(&crate::tr!("Couldn't export")),
                        Some(
                            &crate::tr!("Writing {path} failed: {error}")
                                .replace("{path}", &path.display().to_string())
                                .replace("{error}", &e.to_string()),
                        ),
                    );
                    alert.add_response("close", &crate::tr!("Close"));
                    alert.set_default_response(Some("close"));
                    alert.set_close_response("close");
                    alert.present(Some(&parent_for_alert));
                }
            }
        });
    }

    /// Ctrl+F / Filter button — toggle the inline filter strip on
    /// the active Browse tab. Strip lives inside the tab (always
    /// constructed at init), so this is just a reveal flip.
    pub(super) fn on_show_filter_dialog(&self) {
        let Some(id) = self.selected_browse_tab_id() else {
            self.show_toast(&crate::tr!("Open a table to filter rows."));
            return;
        };
        self.dispatch_to_tab(id, BrowseTabInput::ToggleFilterStrip);
    }

    pub(super) fn on_refresh_active_tab(&self) {
        let Some(id) = self.selected_browse_tab_id() else {
            return;
        };
        let dirty = crate::services::change_tracker::with_tab_ref(id, |tr| tr.has_pending()).unwrap_or(false);
        if !dirty {
            self.dispatch_to_tab(id, BrowseTabInput::Refresh);
            return;
        }
        // F5 mid-edit: a refetch overwrites the model and silently
        // drops every pending row edit / insert / delete. Confirm
        // with a destructive AlertDialog mirroring the close-with-
        // pending path so the user has to opt in to the data loss.
        let dialog = adw::AlertDialog::new(
            Some(&crate::tr!("Discard pending changes?")),
            Some(&crate::tr!(
                "Refreshing reloads the table from the database and drops every unsaved edit on this tab."
            )),
        );
        dialog.add_response("cancel", &crate::tr!("Cancel"));
        dialog.add_response("discard", &crate::tr!("Discard and refresh"));
        dialog.set_response_appearance("discard", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        let workspace_tabs = self.workspace_tabs.clone();
        dialog.connect_response(None, move |dlg: &adw::AlertDialog, response: &str| {
            dlg.close();
            if response == "discard" {
                crate::services::change_tracker::with_tab(id, |t| t.clear());
                if let Some(controller) = workspace_tabs.borrow().get(&id).and_then(|t| t.browse_controller()) {
                    let _ = controller.sender().send(BrowseTabInput::Refresh);
                }
            }
        });
        dialog.present(Some(&self.window));
    }
}
