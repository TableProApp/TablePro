use tablepro_core::browse::build_count;
use tablepro_core::meta::{RowCountEstimate, TableEstimate};
use tablepro_session::{OperationError, OperationKind};

use super::count_failure_text::count_failure_text;
use super::count_policy::{CountAction, decide};
use super::row_total::RowTotal;
use super::{BrowseCommand, BrowseModel, BrowseRequestKind, BrowseTabOutput, Effects};

impl BrowseModel {
    /// The server's guess at the table's size, which is all the "of N"
    /// total needs, and which decides whether a count runs on its own.
    pub(super) fn fetch_estimate(&mut self) {
        let ticket = self.issue(BrowseRequestKind::Estimate);
        let session = self.session.clone();
        let table = self.table_ref();
        let cancel = ticket.cancel.clone();
        let work = async move {
            session
                .run_cancellable(OperationKind::Metadata, &cancel, move |lease, options| {
                    let table = table.clone();
                    async move {
                        lease
                            .table_estimate(&table, options)
                            .await
                            .map_err(OperationError::from)
                    }
                })
                .await
        };
        self.deliver(ticket, work, BrowseCommand::Estimate, OperationError::from);
    }

    pub(super) fn on_estimate(&mut self, value: Result<TableEstimate, OperationError>, fx: &mut Effects) {
        let estimate = value.map(|estimate| estimate.rows).map_err(|error| {
            tracing::warn!(category = ?error.category(), "row estimate unavailable");
        });
        let filtered = !self.current_filter.is_empty();
        // The count gives the total, so an estimate that lands while it
        // runs only fills in what shows meanwhile.
        if self.sequencer.is_pending(BrowseRequestKind::Count) {
            let shown = estimate
                .ok()
                .and_then(RowCountEstimate::value)
                .filter(|_| !filtered)
                .or(self.total.estimate());
            self.set_total(RowTotal::Counting { estimate: shown }, fx);
            return;
        }
        match decide(estimate, filtered) {
            CountAction::UseExact(rows) => self.set_total(RowTotal::Exact(rows), fx),
            CountAction::UseEstimate(rows) => self.set_total(RowTotal::Estimated(rows), fx),
            CountAction::CountNow => {
                // The whole table's estimate is no total for a filtered view.
                let estimate = estimate
                    .ok()
                    .and_then(|estimate| estimate.value())
                    .filter(|_| !filtered);
                self.start_count(estimate, fx);
            }
            CountAction::OfferCount => self.set_total(RowTotal::Unknown, fx),
        }
    }

    /// Count the rows under the tab's filter. `estimate` shows while it
    /// runs.
    pub(super) fn start_count(&mut self, estimate: Option<u64>, fx: &mut Effects) {
        let Some(plan) = self.read_plan() else {
            return;
        };
        // The page says why such a filter cannot be read.
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
        self.set_total(RowTotal::Counting { estimate }, fx);
    }

    pub(super) fn on_count(&mut self, value: Result<u64, OperationError>, fx: &mut Effects) {
        match value {
            Ok(rows) => self.set_total(RowTotal::Exact(rows), fx),
            Err(error) => {
                let reason = count_failure_text(&error, self.deadlines.deadline(OperationKind::Count));
                let estimate = self.total.estimate();
                self.set_total(RowTotal::Unavailable { estimate, reason }, fx);
            }
        }
    }

    /// A refresh or a new filter reads other rows than the running count
    /// counts, so it stops. A refresh keeps what the count started from;
    /// a filter has no total until its own estimate lands.
    pub(super) fn stop_count(&mut self, keep_total: bool) {
        self.sequencer.cancel(BrowseRequestKind::Count);
        self.total = match (keep_total, &self.total) {
            (false, _) => RowTotal::Unknown,
            (
                true,
                RowTotal::Counting {
                    estimate: Some(estimate),
                },
            ) => RowTotal::Estimated(*estimate),
            (true, RowTotal::Counting { estimate: None }) => RowTotal::Unknown,
            (true, total) => total.clone(),
        };
        self.sync_total_chrome();
    }

    pub(super) fn set_total(&mut self, total: RowTotal, fx: &mut Effects) {
        self.total = total;
        if self.clamp_to_total(fx) {
            self.fetch(BrowseRequestKind::Page, fx);
        }
        self.sync_total_chrome();
    }

    /// Only an exact total says where the table ends, so only an exact
    /// one moves a page left past the end back to the last page. Says
    /// whether it moved, for the caller to read that page.
    pub(super) fn clamp_to_total(&mut self, fx: &mut Effects) -> bool {
        let Some(target) = self.total.exact().and_then(|rows| self.pager.clamp(rows)) else {
            return false;
        };
        self.pager.move_to(target);
        fx.output(BrowseTabOutput::StateChanged);
        true
    }

    /// The paginator's label, the Count Rows button and Last, which only
    /// an exact total enables.
    pub(super) fn sync_total_chrome(&self) {
        self.widgets
            .pager_bar
            .show_total(&self.pager, self.shown_page(), &self.total);
        let counting = matches!(self.total, RowTotal::Counting { .. });
        self.actions
            .count_rows
            .set_enabled(self.shown_page().is_some() && self.total.exact().is_none() && !counting);
    }
}
