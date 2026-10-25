use super::{BrowseModel, BrowseRequestKind, BrowseTabOutput, Effects, SaveInput};
use crate::i18n::gettext;
use crate::services::change_origins::ChangeOrigins;
use crate::services::change_tracker::{RowKey, StatementSource};
use crate::ui::discard_alert::confirm_discard;

impl BrowseModel {
    pub(super) fn on_save(&mut self, input: SaveInput, fx: &mut Effects) {
        match input {
            // What is typed in an open editor is part of the save.
            SaveInput::CommitSave => {
                self.grid.commit_edit();
                fx.output(BrowseTabOutput::SaveRequested);
            }
            SaveInput::SaveStarted => {
                self.show_saving(true);
                // Starting the save took a failed row's mark off.
                self.grid.redraw();
            }
            SaveInput::StopSaving => fx.output(BrowseTabOutput::StopSaveRequested),
            SaveInput::ConfirmDiscard => self.confirm_discard(),
            SaveInput::DiscardAll => {
                self.discard();
                self.fetch(BrowseRequestKind::Page, fx);
            }
            SaveInput::DiscardAndRefresh => {
                self.discard();
                self.reload(fx);
            }
            SaveInput::SaveCommitted(origins) => self.save_committed(&origins, fx),
            SaveInput::SaveFailed(message) => self.save_failed(gettext("Save Failed"), message, fx),
            SaveInput::SaveOutcomeUnknown(message) => {
                self.save_failed(gettext("Save Result Unknown"), message, fx);
            }
            SaveInput::MarkErrorRow(source) => self.mark_error_row(&source),
        }
    }

    /// The window's close prompt discards through the tracker and keeps
    /// no delta, so the grid rebuilds its drafts from the tracker either
    /// way.
    fn discard(&self) {
        self.grid.discard();
        self.grid.resync();
    }

    fn confirm_discard(&self) {
        self.grid.commit_edit();
        let pending = self.tracker.pending_count();
        if pending == 0 {
            return;
        }
        let tab = self.this.clone();
        confirm_discard(&self.widgets.inner_stack, pending, move || {
            if let Some(tab) = tab.upgrade() {
                tab.send(SaveInput::DiscardAll);
            }
        });
    }

    /// The tracker already let go of what the save wrote, and the page
    /// read next replaces every row. The rows are not drawn again before
    /// it lands: a saved draft would draw empty.
    fn save_committed(&mut self, origins: &ChangeOrigins, fx: &mut Effects) {
        self.show_saving(false);
        self.sync_pending_chrome(self.tracker.pending_count(), fx);
        // The save says how the total moved, so nothing is counted
        // again. A delete that emptied the last page leaves an exact
        // total that moves the tab back a page.
        self.total
            .adjust_after_save(origins.inserts, origins.deletes, !self.current_filter.is_empty());
        self.clamp_to_total(fx);
        self.sync_total_chrome();
        self.fetch(BrowseRequestKind::Page, fx);
    }

    /// The changes stay pending, rebased by the tracker on what was
    /// read, so every row draws again.
    fn save_failed(&self, title: String, body: String, fx: &mut Effects) {
        self.show_saving(false);
        self.grid.redraw();
        fx.output(BrowseTabOutput::ShowAlert { title, body });
    }

    /// While a save runs, Save and Discard are off, so a double click
    /// cannot send two, and Stop Saving takes their place.
    fn show_saving(&self, saving: bool) {
        self.saving.set(saving);
        self.follow_tracker();
        self.widgets.pending_bar.show_saving(saving);
    }

    pub(super) fn refresh_pending_bar(&self, count: usize) {
        // The footer slides away once nothing is left to save, and the
        // grid holds what the user was working on.
        if count == 0 {
            crate::ui::a11y::pass_focus(&self.widgets.pending_bar, &self.grid.column_view());
        }
        self.widgets.pending_bar.show_pending(count);
        self.refresh_banner_visibility();
    }

    /// The footer and the tab's dirty flag, which App turns into the
    /// title bullet. App hears only real transitions.
    pub(super) fn sync_pending_chrome(&self, count: usize, fx: &mut Effects) {
        self.refresh_pending_bar(count);
        self.follow_tracker();
        let dirty = count > 0;
        if dirty != self.was_dirty.replace(dirty) {
            fx.output(BrowseTabOutput::DirtyChanged(dirty));
        }
    }

    /// Mark the row behind a failed statement and bring it into view. It
    /// keeps the mark until it is changed or saved again. A row paged,
    /// sorted or filtered away is not found, and the alert alone tells
    /// the user which statement failed.
    fn mark_error_row(&self, source: &StatementSource) {
        let key = match source {
            StatementSource::Insert { draft_id } => RowKey::Draft(*draft_id),
            StatementSource::Update { row_key } | StatementSource::Delete { row_key } => row_key.clone(),
        };
        let delta = self.tracker.mark_error_row(key.clone());
        self.grid.apply_delta(&delta);
        self.grid.reveal_row(&key);
    }
}
