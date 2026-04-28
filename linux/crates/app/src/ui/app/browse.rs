use relm4::adw::prelude::*;
use relm4::gtk::gio;
use relm4::{ComponentController, ComponentSender, gtk};

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
    /// the same tab via `AppMsg::RowsLoaded(tab_id, ...)`.
    pub(super) fn fetch_browse_page(&self, tab_id: Uuid, sender: ComponentSender<Self>) {
        let (schema, table, offset, limit, sort, driver_id) = {
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
                model.driver_id().to_string(),
            )
        };

        let Some(conn) = database_service::instance().active() else {
            sender.input(AppMsg::LoadFailed(Some(tab_id), "no active connection".into()));
            return;
        };
        let order_by = sort.and_then(|(idx, asc)| {
            let tabs = self.workspace_tabs.borrow();
            let cols = tabs
                .get(&tab_id)
                .and_then(|t| t.browse_controller())
                .map(|c| c.model().columns().to_vec())
                .unwrap_or_default();
            cols.get(idx).map(|c| {
                let name = tablepro_core::sql_dialect::quote_ident(&driver_id, &c.name);
                let dir = if asc { "ASC" } else { "DESC" };
                format!("{name} {dir}")
            })
        });
        let sender_clone = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    let result = match &order_by {
                        Some(order) => {
                            let qualified = match &schema {
                                Some(s) => format!(
                                    "{}.{}",
                                    tablepro_core::sql_dialect::quote_ident(&driver_id, s),
                                    tablepro_core::sql_dialect::quote_ident(&driver_id, &table)
                                ),
                                None => tablepro_core::sql_dialect::quote_ident(&driver_id, &table),
                            };
                            let sql =
                                format!("SELECT * FROM {qualified} ORDER BY {order} LIMIT {limit} OFFSET {offset}");
                            conn.query(&sql).await
                        }
                        None => conn.fetch_rows(schema.as_deref(), &table, offset, limit).await,
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
        let (schema, table, driver_id) = {
            let tabs = self.workspace_tabs.borrow();
            let Some(controller) = tabs.get(&tab_id).and_then(|t| t.browse_controller()) else {
                return;
            };
            let model = controller.model();
            (
                model.schema().map(str::to_owned),
                model.table().to_string(),
                model.driver_id().to_string(),
            )
        };

        let Some(conn) = database_service::instance().active() else {
            return;
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
                    let sql = format!("SELECT COUNT(*) FROM {qualified}");
                    if let Ok(qr) = conn.query(&sql).await
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
                Err(e) => toast_overlay.add_toast(relm4::adw::Toast::new(
                    &crate::tr!("Export failed: {error}").replace("{error}", &e.to_string()),
                )),
            }
        });
    }

    pub(super) fn on_find_in_results(&self) {
        if let Some(id) = self.selected_browse_tab_id() {
            self.dispatch_to_tab(id, BrowseTabInput::FindInResults);
        }
    }

    pub(super) fn on_refresh_active_tab(&self) {
        if let Some(id) = self.selected_browse_tab_id() {
            self.dispatch_to_tab(id, BrowseTabInput::Refresh);
        }
    }
}
