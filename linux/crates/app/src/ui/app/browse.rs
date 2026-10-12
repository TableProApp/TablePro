use relm4::adw::prelude::*;
use relm4::{ComponentController, ComponentSender, adw};

use tablepro_core::browse::{PageRequest, SortKey, build_count, build_page, split_page};
use tablepro_core::meta::{PagePosition, TableRef};
use tablepro_core::statement::StatementBuilder;
use tablepro_core::{CallOptions, ColumnInfo, DriverError, FilterSet, QueryResult, RowLimit};
use tablepro_session::{ConnectionLease, OperationKind, Session};
use uuid::Uuid;

use crate::ui::browse_tab::BrowseTabInput;

use super::{App, AppMsg, OpenMode};

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

    /// Fetch the current page of a browse tab, under its sort, filter
    /// and position. The SQL is built inside the operation from the
    /// connection it runs on, so it matches that server's dialect even
    /// when a reconnect lands in between.
    pub(super) fn fetch_browse_page(&self, tab_id: Uuid, sender: ComponentSender<Self>) {
        let Some(request) = self.browse_request(tab_id) else {
            return;
        };
        let Some(session) = self.context.active.get() else {
            sender.input(AppMsg::LoadFailed(
                Some(tab_id),
                crate::i18n::gettext("No active connection"),
            ));
            return;
        };
        // A filter the dialect cannot write is the user's to fix, so it
        // is a toast now rather than a failed page later.
        if let Some(message) = filter_problem(&session, &request) {
            sender.input(AppMsg::ShowToast(message));
            return;
        }
        let offset = request.offset;
        let work = async move {
            session
                .run(OperationKind::Page, move |lease, options| {
                    let request = request.clone();
                    async move {
                        let columns = request.columns(&lease, &options).await?;
                        let identity = lease.row_identity(&request.table, options.clone()).await?;
                        let position = match request.offset {
                            0 => PagePosition::First,
                            offset => PagePosition::Offset(offset),
                        };
                        let spec = build_page(
                            &*lease.dialect(),
                            &PageRequest {
                                table: &request.table,
                                columns: &columns,
                                filter: &request.filter,
                                sort: &request.sort,
                                identity: &identity,
                                position: &position,
                                limit: request.limit,
                            },
                        )?;
                        let limit = RowLimit::new(request.limit).unwrap_or(RowLimit::EDITOR_DEFAULT);
                        let result = lease.query_bound(&spec.statement, limit, options).await?;
                        let page = split_page(result, &spec)?;
                        Ok(QueryResult::new(page.columns, page.rows).truncated(page.truncated))
                    }
                })
                .await
        };
        self.context.tasks.spawn_task(async move {
            match work.await {
                Ok(result) => sender.input(AppMsg::RowsLoaded(tab_id, offset, result)),
                Err(error) => sender.input(AppMsg::LoadFailed(
                    Some(tab_id),
                    crate::ui::error_text::operation_error_message(&error),
                )),
            }
        });
    }

    pub(super) fn fetch_browse_columns(&self, tab_id: Uuid, sender: ComponentSender<Self>) {
        let Some(table) = self.browse_request(tab_id).map(|request| request.table) else {
            return;
        };
        let Some(session) = self.context.active.get() else {
            return;
        };
        self.context.tasks.spawn_task(async move {
            let columns = session
                .run(OperationKind::Metadata, move |lease, options| {
                    let table = table.clone();
                    async move { Ok(lease.fetch_columns(&table, options).await?) }
                })
                .await;
            match columns {
                Ok(columns) => sender.input(AppMsg::ColumnsLoaded(tab_id, columns)),
                Err(error) => tracing::warn!(%error, "could not read the table's columns"),
            }
        });
    }

    /// The "of N" total, under the same filter as the page so the two
    /// agree.
    pub(super) fn fetch_browse_row_count(&self, tab_id: Uuid, sender: ComponentSender<Self>) {
        let Some(request) = self.browse_request(tab_id) else {
            return;
        };
        let Some(session) = self.context.active.get() else {
            return;
        };
        // The page fetch toasts a bad filter on the same tick, so the
        // count stays quiet about it.
        if filter_problem(&session, &request).is_some() {
            return;
        }
        self.context.tasks.spawn_task(async move {
            let counted = session
                .run(OperationKind::Count, move |lease, options| {
                    let request = request.clone();
                    async move {
                        let columns = request.columns(&lease, &options).await?;
                        let statement = build_count(&*lease.dialect(), &request.table, &columns, &request.filter)?;
                        Ok(lease.count_rows(&statement, options).await?)
                    }
                })
                .await;
            match counted {
                Ok(count) => sender.input(AppMsg::RowCountLoaded(tab_id, count)),
                Err(error) => tracing::debug!(%error, "the row count could not be read"),
            }
        });
    }

    /// What a page or count of this tab depends on, read on the GTK
    /// thread so the work that follows owns its copy.
    fn browse_request(&self, tab_id: Uuid) -> Option<BrowseRequest> {
        let tabs = self.workspace_tabs.borrow();
        let model = tabs.get(&tab_id)?.browse_controller()?.model();
        Some(BrowseRequest {
            table: TableRef::new(model.schema().map(str::to_owned), model.table()),
            columns: model.columns().to_vec(),
            filter: model.current_filter().clone(),
            sort: model
                .current_sort()
                .map(|(column, ascending)| SortKey { column, ascending })
                .into_iter()
                .collect(),
            offset: model.current_offset(),
            limit: model.page_size(),
        })
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
                self.set_status_page(super::StatusKind::Error, &crate::i18n::gettext("Failed"), &msg);
            }
        }
    }

    /// Ctrl+F / Filter button — toggle the inline filter strip on
    /// the active Browse tab. Strip lives inside the tab (always
    /// constructed at init), so this is just a reveal flip.
    pub(super) fn on_show_filter_dialog(&self) {
        let Some(id) = self.selected_browse_tab_id() else {
            self.show_toast(&crate::i18n::gettext("Open a table to filter rows."));
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
            Some(&crate::i18n::gettext("Discard pending changes?")),
            Some(&crate::i18n::gettext(
                "Refreshing reloads the table from the database and drops every unsaved edit on this tab.",
            )),
        );
        dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
        dialog.add_response("discard", &crate::i18n::gettext("Discard and refresh"));
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

/// One browse tab's view of its table: the part of a page or count
/// that does not depend on the connection it runs on.
#[derive(Debug, Clone)]
struct BrowseRequest {
    table: TableRef,
    /// Empty until the tab has read them from the catalogue.
    columns: Vec<ColumnInfo>,
    filter: FilterSet,
    sort: Vec<SortKey>,
    offset: u64,
    limit: u64,
}

impl BrowseRequest {
    /// The tab's columns, or the catalogue's when the tab has not read
    /// them yet: a page names every column it selects.
    async fn columns(&self, lease: &ConnectionLease, options: &CallOptions) -> Result<Vec<ColumnInfo>, DriverError> {
        match self.columns.is_empty() {
            true => lease.fetch_columns(&self.table, options.clone()).await,
            false => Ok(self.columns.clone()),
        }
    }
}

/// Why the tab's filter cannot be written for the current server, if it
/// cannot.
///
/// Before the tab has its columns there is nothing to check against;
/// the page reads them and reports a filter that does not fit.
fn filter_problem(session: &Session, request: &BrowseRequest) -> Option<String> {
    if request.columns.is_empty() {
        return None;
    }
    let dialect = session.current_dialect()?;
    let mut builder = StatementBuilder::new();
    tablepro_core::build_filter(&mut builder, &*dialect, &request.columns, &request.filter)
        .err()
        .map(|error| error.to_string())
}
