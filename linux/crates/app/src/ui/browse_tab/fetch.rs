use std::future::Future;
use std::sync::Arc;

use tablepro_core::browse::{BrowseSqlError, PageLayout, PageRequest, SortKey, build_page};
use tablepro_core::meta::{RowIdentity, TableRef};
use tablepro_core::statement::StatementBuilder;
use tablepro_core::{BuildFilterError, ColumnInfo, FilterSet, QueryResult, RowLimit};
use tablepro_session::{LinkGeneration, OperationError, OperationKind};

use super::column_recheck::RecheckAction;
use super::columns_fetch::{ColumnFreshness, load_columns};
use super::{
    BrowseCommand, BrowseModel, BrowseRequestKind, BrowseTabInput, BrowseTabOutput, ColumnsReply, Effects, PageReply,
};
use crate::runtime::{RequestTicket, Stamped};
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
    fn fetch_columns(&mut self, freshness: ColumnFreshness) {
        self.recheck.reset();
        self.read_columns(freshness);
    }

    fn read_columns(&mut self, freshness: ColumnFreshness) {
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
            let reply_position = position.clone();
            session
                .run_cancellable(OperationKind::Page, &cancel, move |lease, options| {
                    let plan = plan.clone();
                    let position = position.clone();
                    async move {
                        let spec = build_page(
                            &*lease.dialect(),
                            &PageRequest {
                                table: &plan.table,
                                columns: &plan.columns,
                                filter: &plan.filter,
                                sort: &plan.sort,
                                identity: &plan.identity,
                                position: &position,
                                limit: plan.limit,
                            },
                        )?;
                        let limit = RowLimit::new(plan.limit).unwrap_or(RowLimit::EDITOR_DEFAULT);
                        let result = lease.query_bound(&spec.statement, limit, options).await?;
                        check_shape(&result, &spec.layout)?;
                        Ok((result, spec.layout))
                    }
                })
                .await
                .map(|(result, layout)| PageReply {
                    position: reply_position,
                    result,
                    layout,
                })
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
                tab.send(BrowseTabInput::Command(command(Stamped { stamp, value })));
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
            limit: self.pager.page_size(),
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
    /// page is read under it. Rows already on screen stay with a toast,
    /// and a page still on its way under the old filter is stopped;
    /// without rows, the error page says why rather than a spinner that
    /// nothing will replace.
    fn on_filter_problem(&mut self, problem: BuildFilterError, fx: &mut Effects) {
        let failure = filter_failure(problem);
        if !self.load.has_content() {
            self.on_load_failed(failure, fx);
            return;
        }
        self.sequencer.cancel(BrowseRequestKind::Page);
        fx.output(BrowseTabOutput::ShowToast(failure.message()));
        let presentation = self.load.abandon();
        self.present(presentation, fx);
    }

    pub(super) fn on_command(&mut self, command: BrowseCommand, fx: &mut Effects) {
        match command {
            BrowseCommand::Columns(Stamped { stamp, value }) => {
                if !self.sequencer.accept(BrowseRequestKind::Columns, stamp) {
                    return;
                }
                self.failed.record(BrowseRequestKind::Columns, &value);
                match value {
                    Ok(reply) => {
                        self.identity = Some(reply.identity);
                        self.on_columns_loaded(reply.columns.to_vec(), fx);
                        for kind in std::mem::take(&mut self.after_columns) {
                            self.fetch(kind, fx);
                        }
                    }
                    Err(failure) => {
                        self.recheck.reset();
                        // What waited on the columns was never asked, so it
                        // is asked again with them rather than set off by a
                        // later read of the columns that wanted none of it.
                        for kind in std::mem::take(&mut self.after_columns) {
                            self.failed.insert(kind);
                        }
                        self.on_load_failed(failure, fx);
                        self.retry_if_link_moved(BrowseRequestKind::Columns, fx);
                    }
                }
            }
            BrowseCommand::Page(Stamped { stamp, value }) => {
                if !self.sequencer.accept(BrowseRequestKind::Page, stamp) {
                    return;
                }
                self.failed.record(BrowseRequestKind::Page, &value);
                match value {
                    Ok(reply) => self.on_page_read(reply, fx),
                    Err(error) => {
                        self.on_load_failed(LoadFailure::Page(Arc::new(error)), fx);
                        self.retry_if_link_moved(BrowseRequestKind::Page, fx);
                    }
                }
            }
            BrowseCommand::Estimate(Stamped { stamp, value }) => {
                if !self.sequencer.accept(BrowseRequestKind::Estimate, stamp) {
                    return;
                }
                self.failed.record(BrowseRequestKind::Estimate, &value);
                let failed = value.is_err();
                self.on_estimate(value, fx);
                if failed {
                    self.retry_if_link_moved(BrowseRequestKind::Estimate, fx);
                }
            }
            // A failed count is not asked again on a reconnect: Try Again
            // runs it, so a count that ran out of time does not run for
            // another deadline, or under a filter applied since.
            BrowseCommand::Count(Stamped { stamp, value }) => {
                if !self.sequencer.accept(BrowseRequestKind::Count, stamp) {
                    return;
                }
                if let Err(error) = &value {
                    tracing::debug!(
                        kind = failure_kind(error),
                        category = ?error.category(),
                        "the row count could not be read"
                    );
                }
                self.on_count(value, fx);
            }
        }
    }

    /// A page read under columns the table no longer has would put cells
    /// under the wrong headers, so the columns are read again once, then
    /// the page; a second mismatch fails the read.
    fn on_page_read(&mut self, reply: PageReply, fx: &mut Effects) {
        match self
            .recheck
            .check(&self.current_columns, &reply.result.columns, &reply.layout)
        {
            RecheckAction::Accept => {
                let offset = reply.offset().unwrap_or(self.pager.start_ordinal());
                self.on_rows_loaded(offset, reply, fx);
            }
            RecheckAction::Refetch => {
                tracing::debug!("a page came back with other columns; reading the columns again");
                self.after_columns.insert(BrowseRequestKind::Page);
                self.read_columns(ColumnFreshness::Refetch);
            }
            RecheckAction::Fail => self.on_load_failed(LoadFailure::ColumnsChanged, fx),
        }
    }

    /// The session reconnected. Reads that failed are asked again on the
    /// new connection; a tab whose reads all landed keeps its rows.
    pub(super) fn on_link_changed(&mut self, generation: LinkGeneration, fx: &mut Effects) {
        if generation <= self.link_generation {
            return;
        }
        self.link_generation = generation;
        self.dialect = self.session.current_dialect();
        self.retry_failed(fx);
    }

    /// A read that failed after its connection was already replaced
    /// would wait for a reconnect that has come and gone, so it is
    /// asked again now.
    fn retry_if_link_moved(&mut self, kind: BrowseRequestKind, fx: &mut Effects) {
        let issued = self.issued_on.get(&kind).copied();
        if issued.is_some_and(|issued| self.session.link_generation() > issued) {
            self.retry_failed(fx);
        }
    }

    fn retry_failed(&mut self, fx: &mut Effects) {
        if self.failed.is_empty() {
            return;
        }
        let kinds = self.failed.take();
        if kinds.contains(&BrowseRequestKind::Page) || kinds.contains(&BrowseRequestKind::Columns) {
            self.begin_read(fx);
        }
        match kinds.contains(&BrowseRequestKind::Columns) {
            true => {
                self.after_columns
                    .extend(kinds.into_iter().filter(|kind| *kind != BrowseRequestKind::Columns));
                self.fetch_columns(ColumnFreshness::Cached);
            }
            false => {
                for kind in kinds {
                    self.fetch(kind, fx);
                }
            }
        }
    }
}

/// A filter the current server cannot write, as the tab reports it.
pub(super) fn filter_failure(problem: BuildFilterError) -> LoadFailure {
    LoadFailure::Page(Arc::new(OperationError::Browse(problem.into())))
}

/// Every row has the columns the page asked for, visible then identity,
/// so the split on the GTK thread takes each row apart at the same place.
fn check_shape(result: &QueryResult, layout: &PageLayout) -> Result<(), BrowseSqlError> {
    let expected = layout.width();
    let found = std::iter::once(result.columns.len())
        .chain(result.rows.iter().map(Vec::len))
        .find(|width| *width != expected);
    match found {
        Some(found) => Err(BrowseSqlError::ShapeMismatch { expected, found }),
        None => Ok(()),
    }
}

/// What a failed read was, for the log. A server's message can quote
/// the statement it rejected, and with it a literal from the user's
/// filter, so the log names the failure and leaves its text to the UI.
fn failure_kind(error: &OperationError) -> &'static str {
    match error {
        OperationError::Driver(_) => "driver",
        OperationError::Sql(_) | OperationError::Browse(_) | OperationError::Build(_) => "statement",
        OperationError::Panicked(_) => "panic",
        OperationError::Cancelled => "cancelled",
        OperationError::Closed => "closed",
    }
}
