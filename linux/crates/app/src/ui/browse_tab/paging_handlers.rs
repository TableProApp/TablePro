use gtk4::prelude::*;
use tablepro_core::FilterSet;
use tablepro_core::meta::PagePosition;

use super::columns_fetch::ColumnFreshness;
use super::fetch::filter_failure;
use super::{BrowseModel, BrowseRequestKind, BrowseTabOutput, Effects, PagingInput};

impl BrowseModel {
    pub(super) fn on_paging(&mut self, input: PagingInput, fx: &mut Effects) {
        match input {
            PagingInput::Refresh => self.reload(fx),
            PagingInput::RequestRefresh => fx.output(BrowseTabOutput::RefreshRequested),
            PagingInput::ToggleFilterStrip => self.filter_strip.toggle(),
            PagingInput::ShowFilterStrip => self.filter_strip.open(),
            PagingInput::FilterApplied(set) => self.apply_filter(set, fx),
            PagingInput::FirstPage => self.turn_page(self.pager.first(), fx),
            PagingInput::PrevPage => self.turn_page(self.pager.prev(), fx),
            PagingInput::NextPage => self.turn_page(self.pager.next(self.rows_on_page()), fx),
            PagingInput::LastPage => self.turn_page(self.pager.last(&self.total), fx),
            PagingInput::SortChanged { col_idx, ascending } => self.sort_by(Some((col_idx, ascending)), fx),
            PagingInput::SortCleared => self.sort_by(None, fx),
            PagingInput::PageSizeChanged(size) => {
                if self.suppress_combo_emit.get() || self.pager.page_size() == size {
                    return;
                }
                self.pager.resize(size);
                self.fetch(BrowseRequestKind::Page, fx);
                fx.output(BrowseTabOutput::StateChanged);
            }
            PagingInput::CountRows => self.count_rows(fx),
        }
    }

    /// F5: read the columns again, in case the table changed under the
    /// tab, then the page and the count built from them. The rows on
    /// screen stay until the new page lands.
    pub(super) fn reload(&mut self, fx: &mut Effects) {
        self.capture_selection();
        self.begin_read(fx);
        self.stop_count(true);
        self.reload_from_columns(ColumnFreshness::Refetch);
    }

    fn apply_filter(&mut self, set: FilterSet, fx: &mut Effects) {
        // The same rules again would only duplicate F5.
        if set == self.current_filter {
            return;
        }
        self.current_filter = set.clone();
        if let Some(conn_id) = self.connection_id {
            self.filter_settings
                .set_filters(conn_id, self.schema.as_deref(), &self.table, set.clone());
        }
        // Filtered counts shift, so back to page 1.
        self.pager.go_to(0);
        self.refresh_filter_chrome();
        self.filter_strip.set_filter(&set);
        self.stop_count(false);
        self.fetch(BrowseRequestKind::Page, fx);
        self.fetch(BrowseRequestKind::Estimate, fx);
        fx.output(BrowseTabOutput::StateChanged);
    }

    fn sort_by(&mut self, next: Option<(usize, bool)>, fx: &mut Effects) {
        // The sorter notifies twice for one click on a new column
        // (column, then order), with the same final pair.
        if self.current_sort == next {
            return;
        }
        self.current_sort = next;
        self.pager.go_to(0);
        self.capture_selection();
        self.fetch(BrowseRequestKind::Page, fx);
        fx.output(BrowseTabOutput::StateChanged);
    }

    fn count_rows(&mut self, fx: &mut Effects) {
        if let Some(problem) = self.filter_problem() {
            fx.output(BrowseTabOutput::ShowToast(filter_failure(problem).message()));
            return;
        }
        if self.total.exact().is_none() && !self.sequencer.is_pending(BrowseRequestKind::Count) {
            self.start_count(self.total.estimate(), fx);
        }
    }

    /// Read the page a paginator move landed on, if it moved.
    fn turn_page(&mut self, target: Option<(PagePosition, u64)>, fx: &mut Effects) {
        let Some((_, start)) = target else {
            return;
        };
        self.pager.go_to(start);
        self.fetch(BrowseRequestKind::Page, fx);
        fx.output(BrowseTabOutput::StateChanged);
    }

    pub(super) fn refresh_filter_chrome(&self) {
        let n = self.current_filter.len();
        if n == 0 {
            self.widgets.filter_badge.set_visible(false);
            self.widgets.filter_badge.set_label("");
            self.widgets
                .filter_button
                .set_tooltip_text(Some(&crate::i18n::gettext("Filter Rows")));
        } else {
            self.widgets.filter_badge.set_label(&n.to_string());
            self.widgets.filter_badge.set_visible(true);
            self.widgets
                .filter_button
                .set_tooltip_text(Some(&crate::i18n::ngettext_f(
                    "{n} Filter Rule Active",
                    "{n} Filter Rules Active",
                    u32::try_from(n).unwrap_or(u32::MAX),
                    &[("n", &n.to_string())],
                )));
        }
    }

    /// A page turn moves the pager before its read lands, so a failed
    /// read leaves the pager on a page the grid does not show. The way
    /// back goes from the pager, and Next waits for a page on screen.
    pub(super) fn sync_pager_buttons(&self) {
        self.widgets.pager_bar.show_position(&self.pager, self.rows_on_page());
    }
}
