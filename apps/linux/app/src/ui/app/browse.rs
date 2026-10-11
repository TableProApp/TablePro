use relm4::adw::prelude::*;
use relm4::{ComponentController, ComponentSender, adw};

use tablepro_core::{ColumnInfo, QueryResult};
use uuid::Uuid;

use crate::services::browse_query::{BrowseTarget, PageQuery};
use crate::ui::browse_tab::{BrowseLoadFailure, BrowsePageRequest, BrowseRowCountRequest, BrowseTabInput};

use super::{App, AppMsg, ExportFormat, OpenMode};
use crate::services::read_scopes::ReadScope;

impl App {
    fn browse_cell_value_context(&self, tab_id: Uuid) -> Option<(Option<String>, String, Vec<ColumnInfo>, String)> {
        let tabs = self.workspace_tabs.borrow();
        let controller = tabs.get(&tab_id)?.browse_controller()?;
        let model = controller.model();
        Some((
            model.schema().map(str::to_owned),
            model.table().to_owned(),
            model.columns().to_vec(),
            model.driver_id().to_owned(),
        ))
    }

    pub(super) fn fetch_browse_cell_value(
        &self,
        tab_id: Uuid,
        request: crate::ui::browse_tab::BrowseCellValueRequest,
        col_index: usize,
        column_name: String,
        row_key: Vec<tablepro_core::Value>,
        sender: ComponentSender<Self>,
    ) {
        let Some((schema, table, columns, driver_id)) = self.browse_cell_value_context(tab_id) else {
            return;
        };
        let query = match browse_cell_value_query(
            schema.as_deref(),
            &table,
            &columns,
            &driver_id,
            col_index,
            &column_name,
            &row_key,
        ) {
            Ok(query) => query,
            Err(message) => {
                self.fail_browse_cell_value(&sender, tab_id, request, col_index, column_name, message);
                return;
            }
        };
        let Some(conn) = self.window_connection() else {
            self.fail_browse_cell_value(
                &sender,
                tab_id,
                request,
                col_index,
                column_name,
                crate::tr!("No active connection.").to_string(),
            );
            return;
        };
        let timeout_secs =
            crate::services::operation_control::timeout_for(&self.preferences, &self.database, self.connection_id);
        let reply = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    let control = crate::services::operation_control::bounded(timeout_secs);
                    let result = conn
                        .query_params_controlled(&query.sql, &query.params, &control)
                        .await
                        .map_err(|error| crate::ui::error_text::driver_message(&error))
                        .and_then(single_cell_value);
                    reply.input(AppMsg::BrowseCellValueLoaded(
                        tab_id,
                        request,
                        col_index,
                        column_name,
                        result,
                    ));
                })
                .drop_on_shutdown()
        });
    }

    fn fail_browse_cell_value(
        &self,
        sender: &ComponentSender<Self>,
        tab_id: Uuid,
        request: crate::ui::browse_tab::BrowseCellValueRequest,
        col_index: usize,
        column_name: String,
        message: String,
    ) {
        sender.input(AppMsg::BrowseCellValueLoaded(
            tab_id,
            request,
            col_index,
            column_name,
            Err(message),
        ));
    }

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
    /// Filter and sort are server-side; the row window is rendered by
    /// `sql_dialect::build_order_and_pagination` because the syntax is
    /// dialect-specific. Past `KEYSET_OFFSET_THRESHOLD`, sequential Next
    /// uses a primary-key seek when PKs and a cursor are available.
    pub(super) fn fetch_browse_page(&self, tab_id: Uuid, sender: ComponentSender<Self>) {
        let (schema, table, request, limit, sort, filter, columns, driver_id, keyset_cursor) = {
            let tabs = self.workspace_tabs.borrow();
            let Some(controller) = tabs.get(&tab_id).and_then(|t| t.browse_controller()) else {
                return;
            };
            let model = controller.model();
            (
                model.schema().map(str::to_owned),
                model.table().to_string(),
                model.begin_page_request(),
                model.page_size(),
                model.current_sort(),
                model.current_filter().clone(),
                model.columns().to_vec(),
                model.driver_id().to_string(),
                model.keyset_cursor().map(|v| v.to_vec()),
            )
        };

        let offset = request.offset;
        let Some(conn) = self.window_connection() else {
            sender.input(AppMsg::LoadFailed(
                Some(tab_id),
                BrowseLoadFailure {
                    request: Some(request),
                    message: "no active connection".into(),
                },
            ));
            return;
        };
        let pending =
            crate::services::change_tracker::with_tab_ref(tab_id, |tracker| tracker.has_pending()).unwrap_or(false);
        let hidden_columns = if pending {
            std::collections::HashSet::new()
        } else {
            self.connection_id
                .zip(self.persistence.column_widths.as_ref())
                .map(|(connection_id, store)| store.hidden_columns(connection_id, &table))
                .unwrap_or_default()
        };
        let target = BrowseTarget {
            driver_id: &driver_id,
            schema: schema.as_deref(),
            table: &table,
            columns: &columns,
            filter: &filter,
            hidden_columns: Some(&hidden_columns),
        };
        let query = match target.page(offset, limit, sort, keyset_cursor.as_deref()) {
            Ok(query) => query,
            Err(message) => {
                sender.input(AppMsg::LoadFailed(
                    Some(tab_id),
                    BrowseLoadFailure {
                        request: Some(request),
                        message,
                    },
                ));
                return;
            }
        };

        let timeout_secs =
            crate::services::operation_control::timeout_for(&self.preferences, &self.database, self.connection_id);
        let token = self.read_scopes.borrow_mut().start(tab_id, ReadScope::Page);
        let sender_clone = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    let control = crate::services::operation_control::bounded_with(timeout_secs, token);
                    let (result, projected_columns) = match query {
                        PageQuery::Native => (
                            conn.fetch_rows_controlled(schema.as_deref(), &table, offset, limit, &control)
                                .await,
                            None,
                        ),
                        PageQuery::Sql(query) => {
                            let projected_columns = query.projected_columns.clone();
                            (
                                conn.query_params_controlled(&query.sql, &query.params, &control).await,
                                projected_columns,
                            )
                        }
                    };
                    match result {
                        Ok(query_result) => {
                            sender_clone.input(AppMsg::RowsLoaded(tab_id, request, query_result, projected_columns))
                        }
                        Err(_) if control.cancellation_token().is_cancelled() => {}
                        Err(e) => sender_clone.input(AppMsg::LoadFailed(
                            Some(tab_id),
                            BrowseLoadFailure {
                                request: Some(request),
                                message: crate::ui::error_text::driver_message(&e),
                            },
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

        let Some(conn) = self.window_connection() else {
            return;
        };
        let timeout_secs =
            crate::services::operation_control::timeout_for(&self.preferences, &self.database, self.connection_id);
        let token = self.read_scopes.borrow_mut().start(tab_id, ReadScope::Columns);
        let sender_clone = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    let control = crate::services::operation_control::bounded_with(timeout_secs, token);
                    match conn.fetch_columns_controlled(schema.as_deref(), &table, &control).await {
                        Ok(_) | Err(_) if control.cancellation_token().is_cancelled() => {}
                        Ok(columns) => sender_clone.input(AppMsg::ColumnsLoaded(tab_id, columns)),
                        Err(error) => sender_clone.input(AppMsg::LoadFailed(
                            Some(tab_id),
                            BrowseLoadFailure {
                                request: None,
                                message: crate::ui::error_text::driver_message(&error),
                            },
                        )),
                    }
                })
                .drop_on_shutdown()
        });
    }

    pub(super) fn fetch_browse_foreign_keys(&self, tab_id: Uuid, sender: ComponentSender<Self>) {
        let (schema, table) = {
            let tabs = self.workspace_tabs.borrow();
            let Some(controller) = tabs.get(&tab_id).and_then(|t| t.browse_controller()) else {
                return;
            };
            let model = controller.model();
            (model.schema().map(str::to_owned), model.table().to_string())
        };

        let Some(conn) = self.window_connection() else {
            return;
        };
        let timeout_secs =
            crate::services::operation_control::timeout_for(&self.preferences, &self.database, self.connection_id);
        let token = self.read_scopes.borrow_mut().start(tab_id, ReadScope::ForeignKeys);
        let sender_clone = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    let control = crate::services::operation_control::bounded_with(timeout_secs, token);
                    // Foreign keys are used only to offer a value picker on
                    // the referencing cell -- a failed or unsupported read
                    // just means no picker, not a load failure for the tab.
                    if let Ok(foreign_keys) = conn
                        .fetch_foreign_keys_controlled(schema.as_deref(), &table, &control)
                        .await
                        && !control.cancellation_token().is_cancelled()
                    {
                        sender_clone.input(AppMsg::ForeignKeysLoaded(tab_id, foreign_keys));
                    }
                })
                .drop_on_shutdown()
        });
    }

    pub(super) fn fetch_browse_row_count(&self, tab_id: Uuid, sender: ComponentSender<Self>) {
        let (schema, table, request, filter, columns, driver_id) = {
            let tabs = self.workspace_tabs.borrow();
            let Some(controller) = tabs.get(&tab_id).and_then(|t| t.browse_controller()) else {
                return;
            };
            let model = controller.model();
            (
                model.schema().map(str::to_owned),
                model.table().to_string(),
                model.begin_row_count_request(),
                model.current_filter().clone(),
                model.columns().to_vec(),
                model.driver_id().to_string(),
            )
        };

        let Some(conn) = self.window_connection() else {
            return;
        };

        let target = BrowseTarget {
            driver_id: &driver_id,
            schema: schema.as_deref(),
            table: &table,
            columns: &columns,
            filter: &filter,
            hidden_columns: None,
        };
        let query = match target.count() {
            Ok(query) => query,
            Err(error) => {
                sender.input(AppMsg::RowCountFailed(tab_id, request));
                sender.input(AppMsg::ShowToast(error));
                return;
            }
        };

        let timeout_secs =
            crate::services::operation_control::timeout_for(&self.preferences, &self.database, self.connection_id);
        let token = self.read_scopes.borrow_mut().start(tab_id, ReadScope::Count);
        let sender_clone = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    let control = crate::services::operation_control::bounded_with(timeout_secs, token);
                    let qr_result = run_browse_count(conn, query, &control).await;
                    let count = qr_result.ok().and_then(|qr| row_count_from_result(&qr));
                    match count {
                        None if control.cancellation_token().is_cancelled() => {}
                        Some(count) => sender_clone.input(AppMsg::RowCountLoaded(tab_id, request, count)),
                        // A stale total left on screen after a failed
                        // recount can enable Last Page past the real
                        // end of the table -- clear it instead of
                        // leaving the last successful count displayed.
                        None => sender_clone.input(AppMsg::RowCountFailed(tab_id, request)),
                    }
                })
                .drop_on_shutdown()
        });
    }

    pub(super) fn on_browse_columns_loaded(
        &self,
        tab_id: Uuid,
        columns: Vec<ColumnInfo>,
        sender: ComponentSender<Self>,
    ) {
        self.dispatch_to_tab(tab_id, BrowseTabInput::ColumnsLoaded(columns));
        // Page order depends on the primary-key metadata, and filters depend
        // on column types. Start both queries only after ColumnsLoaded has
        // updated the tab model.
        sender.input(AppMsg::FetchBrowseRowCount(tab_id));
        sender.input(AppMsg::FetchBrowsePage(tab_id));
        sender.input(AppMsg::FetchBrowseForeignKeys(tab_id));
    }

    pub(super) fn on_browse_foreign_keys_loaded(&self, tab_id: Uuid, foreign_keys: Vec<tablepro_core::ForeignKeyInfo>) {
        self.dispatch_to_tab(tab_id, BrowseTabInput::ForeignKeysLoaded(foreign_keys));
    }

    pub(super) fn on_browse_rows_loaded(
        &self,
        tab_id: Uuid,
        request: BrowsePageRequest,
        result: QueryResult,
        projected_columns: Option<Vec<usize>>,
    ) {
        self.dispatch_to_tab(
            tab_id,
            BrowseTabInput::RowsLoaded {
                request,
                result,
                projected_columns,
            },
        );
    }

    pub(super) fn on_browse_row_count_loaded(&self, tab_id: Uuid, request: BrowseRowCountRequest, count: u64) {
        self.dispatch_to_tab(tab_id, BrowseTabInput::RowCountLoaded { request, count });
    }

    pub(super) fn on_browse_row_count_failed(&self, tab_id: Uuid, request: BrowseRowCountRequest) {
        self.dispatch_to_tab(tab_id, BrowseTabInput::RowCountFailed(request));
    }

    pub(super) fn on_browse_load_failed(&mut self, tab_id: Option<Uuid>, failure: BrowseLoadFailure) {
        match tab_id {
            Some(id) => {
                if let Some(request) = failure.request {
                    let accepts = self
                        .workspace_tabs
                        .borrow()
                        .get(&id)
                        .and_then(|tab| tab.browse_controller())
                        .is_some_and(|controller| controller.model().accepts_page_request(request));
                    if !accepts {
                        return;
                    }
                }
                self.dispatch_to_tab(id, BrowseTabInput::ShowError(failure.message));
            }
            None => {
                tracing::warn!(error = %failure.message, "app-level load failed");
                self.dismiss_loading_page();
                self.set_status_page(super::StatusKind::Error, &crate::tr!("Failed"), &failure.message);
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

        let (result, has_unfetched_columns) = {
            let tabs = self.workspace_tabs.borrow();
            let Some(model) = tabs
                .get(&active_id)
                .and_then(|t| t.browse_controller())
                .map(|c| c.model())
            else {
                self.show_toast(&crate::tr!("Nothing to export"));
                return;
            };
            (model.snapshot(), model.has_unfetched_columns())
        };
        let Some(result) = result else {
            let message = if has_unfetched_columns {
                crate::tr!("Show hidden columns and reload before exporting this page.")
            } else {
                crate::tr!("Nothing to export")
            };
            self.show_toast(&message);
            return;
        };
        let table_label = match &schema {
            Some(schema) => format!("{schema}.{table}"),
            None => table,
        };
        crate::ui::export_dialog::present_with_format(
            &self.window,
            &self.toast_overlay,
            crate::ui::export_dialog::ExportRequest {
                paged: None,
                result,
                suggested_name: table_label,
                driver_id: self.driver_id().to_string(),
            },
            matches!(format, ExportFormat::Json),
            &self.preferences,
        );
    }

    fn export_page_plan(&self, tab_id: Uuid) -> Option<(crate::services::export_pages::PagePlan, Option<usize>)> {
        let tabs = self.workspace_tabs.borrow();
        let model = tabs.get(&tab_id)?.browse_controller()?.model();
        let plan = crate::services::export_pages::PagePlan {
            driver_id: model.driver_id().to_string(),
            schema: model.schema().map(str::to_owned),
            table: model.table().to_string(),
            columns: model.columns().to_vec(),
            filter: model.current_filter().clone(),
            sort: model.current_sort(),
            timeout_secs: crate::services::operation_control::timeout_for(
                &self.preferences,
                &self.database,
                self.connection_id,
            ),
        };
        let total = model.total_rows().and_then(|total| usize::try_from(total).ok());
        Some((plan, total))
    }

    pub(super) fn on_export_all(&self, format: ExportFormat) {
        let planned = self
            .selected_browse_tab_id()
            .and_then(|id| self.export_page_plan(id))
            .zip(self.window_connection());
        let Some(((plan, total_rows), conn)) = planned else {
            self.show_toast(&crate::tr!("Nothing to export"));
            return;
        };
        let label = match &plan.schema {
            Some(schema) => format!("{schema}.{}", plan.table),
            None => plan.table.clone(),
        };
        let columns_only = QueryResult {
            columns: plan.columns.clone(),
            rows: Vec::new(),
            truncated: false,
        };
        crate::ui::export_dialog::present_with_format(
            &self.window,
            &self.toast_overlay,
            crate::ui::export_dialog::ExportRequest {
                paged: Some(crate::ui::export_dialog::PagedExport {
                    total_rows,
                    open: page_fetcher_factory(conn, plan),
                }),
                result: columns_only,
                suggested_name: label,
                driver_id: self.driver_id().to_string(),
            },
            matches!(format, ExportFormat::Json),
            &self.preferences,
        );
    }

    /// Ctrl+F / Filter button — toggle the inline filter strip on
    /// the active Browse tab. Strip lives inside the tab (always
    /// constructed at init), so this is just a reveal flip.
    pub(super) fn on_show_filter_dialog(&self) {
        if let Some(id) = self.selected_editor_tab_id() {
            self.dispatch_to_editor(id, crate::ui::editor::SqlEditorInput::ShowFind);
            return;
        }
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

fn browse_cell_value_query(
    schema: Option<&str>,
    table: &str,
    columns: &[ColumnInfo],
    driver_id: &str,
    col_index: usize,
    column_name: &str,
    row_key: &[tablepro_core::Value],
) -> Result<crate::services::browse_query::BoundQuery, String> {
    if columns.get(col_index).is_none_or(|column| column.name != column_name) {
        return Err(crate::tr!("The table columns changed before the value could be fetched.").to_string());
    }
    BrowseTarget {
        driver_id,
        schema,
        table,
        columns,
        filter: &tablepro_core::FilterSet::default(),
        hidden_columns: None,
    }
    .value_query(col_index, row_key)
}

fn single_cell_value(result: QueryResult) -> Result<tablepro_core::Value, String> {
    if result.columns.len() != 1 || result.truncated {
        return Err(crate::tr!("The row key did not identify exactly one cell.").to_string());
    }
    let [row] = result.rows.as_slice() else {
        return Err(crate::tr!("The row key did not identify exactly one cell.").to_string());
    };
    let [value] = row.as_slice() else {
        return Err(crate::tr!("The row key did not identify exactly one cell.").to_string());
    };
    Ok(value.clone())
}

fn row_count_from_result(result: &QueryResult) -> Option<u64> {
    let value = result.rows.first()?.first()?;
    match value {
        tablepro_core::Value::Int(i) if *i >= 0 => Some(*i as u64),
        tablepro_core::Value::Float(f) if *f >= 0.0 && f.is_finite() => Some(*f as u64),
        tablepro_core::Value::Decimal(d) => d.to_string().parse::<u64>().ok(),
        _ => None,
    }
}

async fn run_browse_count(
    connection: std::sync::Arc<dyn tablepro_core::Connection>,
    query: crate::services::browse_query::BoundQuery,
    control: &tablepro_core::OperationControl,
) -> Result<QueryResult, tablepro_core::DriverError> {
    if query.params.is_empty() {
        connection.query_controlled(&query.sql, control).await
    } else {
        connection
            .query_params_controlled(&query.sql, &query.params, control)
            .await
    }
}

fn page_fetcher_factory(
    conn: std::sync::Arc<dyn tablepro_core::Connection>,
    plan: crate::services::export_pages::PagePlan,
) -> crate::ui::export_dialog::PageFetcherFactory {
    let run: crate::services::export_pages::PageRunner = std::sync::Arc::new(|future| {
        let (reply, answer) = async_channel::bounded(1);
        relm4::spawn(async move {
            let _ = reply.send(future.await).await;
        });
        answer.recv_blocking().unwrap_or_else(|_| {
            Err(tablepro_core::export::ExportError::Source(
                "the export was interrupted".into(),
            ))
        })
    });
    std::sync::Arc::new(move |cancel| {
        Box::new(crate::services::export_pages::page_fetcher(
            conn.clone(),
            plan.clone(),
            run.clone(),
            cancel,
        ))
    })
}

#[cfg(test)]
mod tests {
    use super::{browse_cell_value_query, row_count_from_result, single_cell_value};
    use tablepro_core::{ColumnInfo, QueryResult, Value};

    fn scalar_result(row: Option<Value>) -> QueryResult {
        QueryResult {
            columns: Vec::new(),
            rows: row.map(|v| vec![vec![v]]).unwrap_or_default(),
            truncated: false,
        }
    }

    #[test]
    fn a_non_negative_integer_count_is_used() {
        assert_eq!(row_count_from_result(&scalar_result(Some(Value::Int(42)))), Some(42));
    }

    #[test]
    fn an_empty_result_has_no_count() {
        assert_eq!(row_count_from_result(&scalar_result(None)), None);
    }

    #[test]
    fn a_negative_or_non_finite_count_is_refused_instead_of_wrapping() {
        assert_eq!(row_count_from_result(&scalar_result(Some(Value::Int(-1)))), None);
        assert_eq!(
            row_count_from_result(&scalar_result(Some(Value::Float(f64::NAN)))),
            None
        );
        assert_eq!(row_count_from_result(&scalar_result(Some(Value::Float(-1.0)))), None);
    }

    #[test]
    fn a_non_numeric_scalar_has_no_count() {
        assert_eq!(
            row_count_from_result(&scalar_result(Some(Value::Text("x".into())))),
            None
        );
    }

    #[test]
    fn value_refetch_accepts_only_one_complete_cell() {
        let complete = QueryResult {
            columns: vec![column()],
            rows: vec![vec![Value::Bytes(vec![0, 255])]],
            truncated: false,
        };
        assert_eq!(single_cell_value(complete), Ok(Value::Bytes(vec![0, 255])));

        for result in [
            QueryResult {
                columns: vec![column()],
                rows: Vec::new(),
                truncated: false,
            },
            QueryResult {
                columns: vec![column()],
                rows: vec![vec![Value::Int(1)], vec![Value::Int(2)]],
                truncated: false,
            },
            QueryResult {
                columns: Vec::new(),
                rows: vec![vec![Value::Int(1)]],
                truncated: false,
            },
            QueryResult {
                columns: vec![column()],
                rows: vec![vec![Value::Int(1)]],
                truncated: true,
            },
        ] {
            assert!(single_cell_value(result).is_err());
        }
    }

    #[test]
    fn value_refetch_refuses_a_column_that_changed_since_the_request() {
        let columns = [column()];
        let error = browse_cell_value_query(None, "records", &columns, "postgres", 0, "old", &[]).unwrap_err();
        assert_eq!(error, "The table columns changed before the value could be fetched.");
    }

    fn column() -> ColumnInfo {
        ColumnInfo {
            name: "payload".into(),
            data_type: "bytea".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }
    }
}
