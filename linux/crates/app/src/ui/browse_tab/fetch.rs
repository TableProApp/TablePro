use std::future::Future;
use std::sync::Arc;

use tablepro_core::browse::{PageRequest, SortKey, read_page};
use tablepro_core::meta::{RowIdentity, TableRef};
use tablepro_core::statement::StatementBuilder;
use tablepro_core::{BuildFilterError, ColumnInfo, FilterSet};
use tablepro_session::{OperationError, OperationKind};

use super::columns_fetch::{ColumnFreshness, load_columns};
use super::{BrowseCommand, BrowseModel, BrowseRequestKind, ColumnsReply, DataInput, Effects, PageReply};
use crate::runtime::{RequestTicket, Stamped};
use crate::ui::export::TableExport;
use crate::ui::tab_load::LoadFailure;

/// What a page or a count reads, copied off the tab so the work owns
/// it. The SQL is built inside the operation from the lease it runs on,
/// so it is spelled for that server even when a reconnect lands first.
#[derive(Debug, Clone)]
pub(super) struct ReadPlan {
    pub(super) table: TableRef,
    pub(super) columns: Vec<ColumnInfo>,
    identity: RowIdentity,
    pub(super) filter: FilterSet,
    sort: Vec<SortKey>,
    limit: u64,
}

impl BrowseModel {
    /// Ask for one kind of read. A page or an estimate waits for the
    /// columns, since the tab reads nothing of a table whose columns it
    /// could not read. A count needs no such wait: it runs only once the
    /// user or an estimate asks, after the columns.
    pub(super) fn fetch(&mut self, kind: BrowseRequestKind, fx: &mut Effects) {
        match kind {
            BrowseRequestKind::Columns => self.fetch_columns(ColumnFreshness::Cached),
            BrowseRequestKind::Page | BrowseRequestKind::Estimate if self.identity.is_none() => {
                self.after_columns.insert(kind);
                if !self.sequencer.is_pending(BrowseRequestKind::Columns) {
                    self.fetch_columns(ColumnFreshness::Cached);
                }
            }
            BrowseRequestKind::Page => self.fetch_page(fx),
            BrowseRequestKind::Estimate => self.fetch_estimate(),
            BrowseRequestKind::Count => self.start_count(self.total.estimate(), fx),
        }
    }

    /// Read the columns, then the page built from them and the table's
    /// estimate. No page is asked for before the columns land, since a
    /// page is built from them, and a failure to read them fails the read
    /// at once rather than leave the tab waiting.
    pub(super) fn reload_from_columns(&mut self, freshness: ColumnFreshness) {
        self.after_columns.insert(BrowseRequestKind::Page);
        self.after_columns.insert(BrowseRequestKind::Estimate);
        self.fetch_columns(freshness);
    }

    pub(super) fn issue(&mut self, kind: BrowseRequestKind) -> RequestTicket {
        self.issued_on.insert(kind, self.session.link_generation());
        self.sequencer.issue(kind)
    }

    /// A new read of the columns, so the page read under them gets its
    /// own recheck.
    pub(super) fn fetch_columns(&mut self, freshness: ColumnFreshness) {
        self.recheck.reset();
        self.read_columns(freshness);
    }

    pub(super) fn read_columns(&mut self, freshness: ColumnFreshness) {
        let ticket = self.issue(BrowseRequestKind::Columns);
        let session = self.session.clone();
        let table = self.table_ref();
        let cancel = ticket.cancel.clone();
        let work = async move {
            // The catalog's read is shared with other views, so a
            // replaced request stops waiting on it without stopping it.
            let columns = tokio::select! {
                columns = load_columns(session.clone(), table.clone(), freshness) => columns?,
                () = cancel.cancelled() => return Err(LoadFailure::Columns(Arc::new(OperationError::Cancelled))),
            };
            let identity = session
                .run_cancellable(OperationKind::Metadata, &cancel, move |lease, options| {
                    let table = table.clone();
                    async move { Ok(lease.row_identity(&table, options).await?) }
                })
                .await
                .map_err(|error| {
                    if error != OperationError::Cancelled {
                        tracing::warn!(category = ?error.category(), "browse row identity failed");
                    }
                    LoadFailure::Columns(Arc::new(error))
                })?;
            Ok(ColumnsReply { columns, identity })
        };
        self.deliver(ticket, work, BrowseCommand::Columns, |failure| {
            LoadFailure::Columns(Arc::new(OperationError::from(failure)))
        });
    }

    fn fetch_page(&mut self, fx: &mut Effects) {
        let Some(plan) = self.read_plan() else {
            return;
        };
        if let Some(problem) = self.filter_problem() {
            self.on_filter_problem(problem, fx);
            return;
        }
        self.begin_read(fx);
        let ticket = self.issue(BrowseRequestKind::Page);
        let session = self.session.clone();
        let cancel = ticket.cancel.clone();
        let position = self.pager.position();
        let work = async move {
            session
                .run_cancellable(OperationKind::Page, &cancel, move |lease, options| {
                    let plan = plan.clone();
                    let position = position.clone();
                    async move {
                        let request = PageRequest {
                            table: &plan.table,
                            columns: &plan.columns,
                            filter: &plan.filter,
                            sort: &plan.sort,
                            identity: &plan.identity,
                            position: &position,
                            limit: plan.limit,
                        };
                        read_page::<OperationError>(&*lease, &request, &options).await
                    }
                })
                .await
                .map(PageReply::from)
        };
        self.deliver(ticket, work, BrowseCommand::Page, OperationError::from);
    }

    /// Run `work` on the app runtime and hand its stamped reply back to
    /// the tab on the GTK thread. The delivery holds the tab weakly, so a
    /// tab closed meanwhile is not kept alive by its own reads.
    pub(super) fn deliver<T, E, W>(
        &self,
        ticket: RequestTicket,
        work: W,
        command: impl FnOnce(Stamped<Result<T, E>>) -> BrowseCommand + 'static,
        failed: impl FnOnce(tablepro_session::runtime::TaskFailure) -> E + 'static,
    ) where
        T: Send + 'static,
        E: Send + 'static,
        W: Future<Output = Result<T, E>> + Send + 'static,
    {
        let tab = self.this.clone();
        let stamp = ticket.stamp;
        let _delivery = crate::runtime::spawn_and_deliver(&self.tasks, work, move |joined| {
            let value = joined.unwrap_or_else(|failure| Err(failed(failure)));
            if let Some(tab) = tab.upgrade() {
                tab.send(DataInput::Command(command(Stamped { stamp, value })));
            }
        });
    }

    pub(super) fn read_plan(&self) -> Option<ReadPlan> {
        Some(ReadPlan {
            table: self.table_ref(),
            columns: self.current_columns.clone(),
            identity: self.identity.clone()?,
            filter: self.current_filter.clone(),
            sort: self
                .current_sort
                .map(|(column, ascending)| SortKey { column, ascending })
                .into_iter()
                .collect(),
            limit: self.pager.limit(),
        })
    }

    /// Every row the tab's filter and sort select, for an export. `None`
    /// until the columns and the row identity are in.
    pub(super) fn table_export(&self) -> Option<TableExport> {
        let plan = self.read_plan()?;
        Some(TableExport {
            table: plan.table,
            columns: plan.columns.into(),
            filter: plan.filter,
            sort: plan.sort,
            identity: plan.identity,
        })
    }

    /// Why the tab's filter cannot be written for the current server,
    /// if it cannot.
    pub(super) fn filter_problem(&self) -> Option<BuildFilterError> {
        let dialect = self.dialect.as_ref()?;
        let mut builder = StatementBuilder::new();
        tablepro_core::build_filter(&mut builder, &**dialect, &self.current_columns, &self.current_filter).err()
    }

    /// A filter the dialect cannot write is the user's to fix, and no
    /// page is read under it. A page still on its way under the old
    /// filter is stopped. The failure stays on screen until a read
    /// lands: on the banner over rows already shown, or on the error
    /// page when there are none.
    fn on_filter_problem(&mut self, problem: BuildFilterError, fx: &mut Effects) {
        self.sequencer.cancel(BrowseRequestKind::Page);
        self.load.abandon();
        self.on_load_failed(filter_failure(problem), fx);
    }
}

/// A filter the current server cannot write, as the tab reports it.
pub(super) fn filter_failure(problem: BuildFilterError) -> LoadFailure {
    LoadFailure::Page(Arc::new(OperationError::Browse(problem.into())))
}
