use std::sync::Arc;

use tablepro_session::OperationError;

use super::column_recheck::RecheckAction;
use super::columns_fetch::ColumnFreshness;
use super::{BrowseCommand, BrowseModel, BrowseRequestKind, Effects, PageReply};
use crate::runtime::Stamped;
use crate::ui::tab_load::LoadFailure;

/// The replies to the tab's reads.
impl BrowseModel {
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

    /// A read that failed after its connection was already replaced
    /// would wait for a reconnect that has come and gone, so it is
    /// asked again now.
    fn retry_if_link_moved(&mut self, kind: BrowseRequestKind, fx: &mut Effects) {
        let issued = self.issued_on.get(&kind).copied();
        if issued.is_some_and(|issued| self.session.link_generation() > issued) {
            self.retry_failed(fx);
        }
    }

    pub(super) fn retry_failed(&mut self, fx: &mut Effects) {
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
