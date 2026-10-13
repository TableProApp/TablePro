use std::future::Future;
use std::sync::Arc;

use tablepro_core::browse::{PageRequest, SortKey, build_count, build_page, split_page};
use tablepro_core::meta::{PagePosition, RowIdentity, TableRef};
use tablepro_core::statement::StatementBuilder;
use tablepro_core::{ColumnInfo, FilterSet, QueryResult, RowLimit};
use tablepro_session::{LinkGeneration, OperationError, OperationKind};

use super::{
    BrowseCommand, BrowseModel, BrowseRequestKind, BrowseTabInput, BrowseTabOutput, ColumnsReply, Effects, PageReply,
};
use crate::runtime::{RequestTicket, Stamped};

/// What a page or a count reads, copied off the tab so the work owns
/// it. The SQL is built inside the operation from the lease it runs on,
/// so it is spelled for that server even when a reconnect lands first.
#[derive(Debug, Clone)]
struct ReadPlan {
    table: TableRef,
    columns: Vec<ColumnInfo>,
    identity: RowIdentity,
    filter: FilterSet,
    sort: Vec<SortKey>,
    offset: u64,
    limit: u64,
}

impl BrowseModel {
    /// Ask for one kind of read. A page or a count waits for the
    /// columns it is built from.
    pub(super) fn fetch(&mut self, kind: BrowseRequestKind, fx: &mut Effects) {
        match kind {
            BrowseRequestKind::Columns => self.fetch_columns(false),
            BrowseRequestKind::Page | BrowseRequestKind::Count if self.identity.is_none() => {
                self.after_columns.insert(kind);
                if !self.sequencer.is_pending(BrowseRequestKind::Columns) {
                    self.fetch_columns(false);
                }
            }
            BrowseRequestKind::Page => self.fetch_page(fx),
            BrowseRequestKind::Count => self.fetch_count(),
        }
    }

    /// Read the columns, then the page and the count built from them.
    /// `refresh` asks the server even when the catalog has the columns.
    pub(super) fn reload_from_columns(&mut self, refresh: bool) {
        self.after_columns.insert(BrowseRequestKind::Page);
        self.after_columns.insert(BrowseRequestKind::Count);
        self.fetch_columns(refresh);
    }

    fn issue(&mut self, kind: BrowseRequestKind) -> RequestTicket {
        self.issued_on.insert(kind, self.session.link_generation());
        self.sequencer.issue(kind)
    }

    fn fetch_columns(&mut self, refresh: bool) {
        let ticket = self.issue(BrowseRequestKind::Columns);
        let session = self.session.clone();
        let table = self.table_ref();
        let cancel = ticket.cancel.clone();
        let work = async move {
            // The catalog's read is shared with other views, so a
            // replaced request stops waiting on it without stopping it.
            let columns = tokio::select! {
                columns = async {
                    match refresh {
                        true => session.refresh_columns(table.clone()).await,
                        false => session.columns(table.clone()).await,
                    }
                } => columns?,
                () = cancel.cancelled() => return Err(Arc::new(OperationError::Cancelled)),
            };
            let identity = session
                .run_cancellable(OperationKind::Metadata, &cancel, move |lease, options| {
                    let table = table.clone();
                    async move { Ok(lease.row_identity(&table, options).await?) }
                })
                .await
                .map_err(Arc::new)?;
            Ok(ColumnsReply { columns, identity })
        };
        self.deliver(ticket, work, BrowseCommand::Columns, |failure| {
            Arc::new(OperationError::from(failure))
        });
    }

    fn fetch_page(&mut self, fx: &mut Effects) {
        let Some(plan) = self.read_plan() else {
            return;
        };
        if let Some(message) = self.filter_problem() {
            self.on_filter_problem(&message, fx);
            return;
        }
        let ticket = self.issue(BrowseRequestKind::Page);
        let session = self.session.clone();
        let cancel = ticket.cancel.clone();
        let position = match plan.offset {
            0 => PagePosition::First,
            offset => PagePosition::Offset(offset),
        };
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
                        let page = split_page(result, &spec)?;
                        Ok(QueryResult::new(page.columns, page.rows).truncated(page.truncated))
                    }
                })
                .await
                .map(|result| PageReply {
                    position: reply_position,
                    result,
                })
        };
        self.deliver(ticket, work, BrowseCommand::Page, OperationError::from);
    }

    /// The "of N" total, under the same filter as the page so the two
    /// agree. The page toasts a filter that cannot be written, so the
    /// count stays quiet about it.
    fn fetch_count(&mut self) {
        let Some(plan) = self.read_plan() else {
            return;
        };
        if self.filter_problem().is_some() {
            return;
        }
        let ticket = self.issue(BrowseRequestKind::Count);
        let session = self.session.clone();
        let cancel = ticket.cancel.clone();
        let work = async move {
            session
                .run_cancellable(OperationKind::Count, &cancel, move |lease, options| {
                    let plan = plan.clone();
                    async move {
                        let statement = build_count(&*lease.dialect(), &plan.table, &plan.columns, &plan.filter)?;
                        Ok(lease.count_rows(&statement, options).await?)
                    }
                })
                .await
        };
        self.deliver(ticket, work, BrowseCommand::Count, OperationError::from);
    }

    /// Run `work` on the app runtime and hand its stamped reply back to
    /// the tab on the GTK thread. The delivery holds the tab weakly, so a
    /// tab closed meanwhile is not kept alive by its own reads.
    fn deliver<T, E, W>(
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

    fn read_plan(&self) -> Option<ReadPlan> {
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
            offset: self.current_offset,
            limit: self.page_size,
        })
    }

    /// Why the tab's filter cannot be written for the current server,
    /// if it cannot.
    fn filter_problem(&self) -> Option<String> {
        let dialect = self.dialect.as_ref()?;
        let mut builder = StatementBuilder::new();
        tablepro_core::build_filter(&mut builder, &**dialect, &self.current_columns, &self.current_filter)
            .err()
            .map(|error| error.to_string())
    }

    /// A filter the dialect cannot write is the user's to fix, and no
    /// page is read under it. A page already read under these columns
    /// stays with a toast; without one, the error page says why rather
    /// than a spinner that nothing will replace.
    fn on_filter_problem(&mut self, message: &str, fx: &mut Effects) {
        if self.current_result.is_some() {
            self.refresh_inner_stack_visibility();
            fx.output(BrowseTabOutput::ShowToast(message.to_owned()));
            return;
        }
        self.show_error(message);
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
                    Err(error) => {
                        tracing::warn!(%error, "could not read the table's columns");
                        self.on_read_failed(&crate::ui::error_text::operation_error_message(&error), fx);
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
                    Ok(reply) => {
                        let offset = reply.offset().unwrap_or(self.current_offset);
                        self.on_rows_loaded(offset, reply.result, fx);
                    }
                    Err(error) => {
                        self.on_read_failed(&crate::ui::error_text::operation_error_message(&error), fx);
                        self.retry_if_link_moved(BrowseRequestKind::Page, fx);
                    }
                }
            }
            BrowseCommand::Count(Stamped { stamp, value }) => {
                if !self.sequencer.accept(BrowseRequestKind::Count, stamp) {
                    return;
                }
                self.failed.record(BrowseRequestKind::Count, &value);
                match value {
                    Ok(count) => self.on_row_count_loaded(count, fx),
                    Err(error) => {
                        tracing::debug!(%error, "the row count could not be read");
                        self.retry_if_link_moved(BrowseRequestKind::Count, fx);
                    }
                }
            }
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
            self.show_loading();
        }
        match kinds.contains(&BrowseRequestKind::Columns) {
            true => {
                self.after_columns
                    .extend(kinds.into_iter().filter(|kind| *kind != BrowseRequestKind::Columns));
                self.fetch_columns(false);
            }
            false => {
                for kind in kinds {
                    self.fetch(kind, fx);
                }
            }
        }
    }
}
