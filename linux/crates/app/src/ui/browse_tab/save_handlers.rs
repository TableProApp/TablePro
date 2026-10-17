use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;

use super::{BrowseModel, BrowseRequestKind, BrowseTabOutput, Effects, SaveInput};
use crate::services::change_origins::ChangeOrigins;
use crate::services::change_tracker::{RowKey, StatementSource};

impl BrowseModel {
    pub(super) fn on_save(&mut self, input: SaveInput, fx: &mut Effects) {
        match input {
            SaveInput::CommitSave => fx.output(BrowseTabOutput::SaveRequested),
            SaveInput::SaveStarted => self.show_saving(true),
            SaveInput::StopSaving => fx.output(BrowseTabOutput::StopSaveRequested),
            SaveInput::DiscardAll => {
                let delta = self.tracker.discard();
                self.apply_tracker_delta(&delta, fx);
                self.fetch(BrowseRequestKind::Page, fx);
            }
            SaveInput::DiscardAndRefresh => {
                let delta = self.tracker.discard();
                self.apply_tracker_delta(&delta, fx);
                self.reload(fx);
            }
            SaveInput::SaveCommitted(origins) => self.save_committed(&origins, fx),
            SaveInput::SaveFailed(message) => {
                self.show_saving(false);
                fx.output(BrowseTabOutput::ShowSelectionAlert {
                    title: crate::i18n::gettext("Save Failed"),
                    body: message,
                });
            }
            SaveInput::SaveOutcomeUnknown(message) => {
                self.show_saving(false);
                fx.output(BrowseTabOutput::ShowSelectionAlert {
                    title: crate::i18n::gettext("Save Result Unknown"),
                    body: message,
                });
            }
            SaveInput::FlashErrorRow(source) => self.flash_error_row(&source),
            SaveInput::ErrorFlashEnded(key) => {
                if let Some(row) = self.row_index.get(&key) {
                    row.bump_revision();
                }
            }
        }
    }

    fn save_committed(&mut self, origins: &ChangeOrigins, fx: &mut Effects) {
        self.show_saving(false);
        // The tracker already let go of what the save wrote. The
        // reload replaces every row; dropping the saved drafts
        // from the store first would blank them until it lands.
        self.sync_pending_chrome(self.tracker.pending_count(), fx);
        self.capture_selection();
        // The save says how the total moved, so nothing is
        // counted again. A delete that emptied the last page
        // leaves an exact total that moves the tab back a page.
        self.total
            .adjust_after_save(origins.inserts, origins.deletes, !self.current_filter.is_empty());
        self.clamp_to_total(fx);
        self.sync_total_chrome();
        self.fetch(BrowseRequestKind::Page, fx);
    }

    /// While a save runs, Save and Discard are off, so a double click
    /// cannot send two, and Stop Saving takes their place.
    fn show_saving(&self, saving: bool) {
        self.saving.set(saving);
        self.actions.follow_tracker(&self.tracker, saving);
        self.widgets.pending_bar.show_saving(saving);
    }

    pub(super) fn refresh_pending_bar(&self, count: usize) {
        // The footer slides away once nothing is left to save, and the
        // grid holds what the user was working on.
        if count == 0
            && let Some(grid) = self.current_column_view.as_ref()
        {
            crate::ui::a11y::pass_focus(&self.widgets.pending_bar, grid);
        }
        self.widgets.pending_bar.show_pending(count);
        self.refresh_banner_visibility();
    }

    /// The footer and the tab's dirty flag, which App turns into the
    /// title bullet. App hears only real transitions.
    pub(super) fn sync_pending_chrome(&self, count: usize, fx: &mut Effects) {
        self.refresh_pending_bar(count);
        self.actions.follow_tracker(&self.tracker, self.saving.get());
        let dirty = count > 0;
        if dirty != self.was_dirty.replace(dirty) {
            fx.output(BrowseTabOutput::DirtyChanged(dirty));
        }
    }

    /// Scroll to the row behind a failed statement and flash it. A row
    /// paged, sorted or filtered away is not found, and the alert alone
    /// tells the user which statement failed.
    fn flash_error_row(&mut self, source: &StatementSource) {
        let key = match source {
            StatementSource::Insert { draft_id } => RowKey::Draft(*draft_id),
            StatementSource::Update { row_key } | StatementSource::Delete { row_key } => row_key.clone(),
        };
        let Some(store) = self.list_store() else {
            return;
        };
        let Some(row) = self.row_index.get(&key) else {
            return;
        };
        let Some(position) = store.find(&row) else {
            return;
        };
        if let Some(selection) = self.current_selection.as_ref() {
            selection.select_item(position, true);
        }
        if let Some(cv) = self.current_column_view.as_ref() {
            cv.scroll_to(
                position,
                None,
                gtk::ListScrollFlags::FOCUS | gtk::ListScrollFlags::SELECT,
                None,
            );
        }
        let flash = self.tracker.flash_error_row(key.clone());
        row.bump_revision();
        if let Some(replaced) = flash.replaced.and_then(|replaced| self.row_index.get(&replaced)) {
            replaced.bump_revision();
        }
        let generation = flash.generation;
        let tracker = self.tracker.clone();
        let tab = self.this.clone();
        // Matches the length of the flash animation in the stylesheet. The
        // row is looked up again then, since a reload may have replaced it.
        glib::timeout_add_local_once(std::time::Duration::from_millis(1800), move || {
            if tracker.clear_error_row_if(generation)
                && let Some(tab) = tab.upgrade()
            {
                tab.send(SaveInput::ErrorFlashEnded(key));
            }
        });
    }
}
