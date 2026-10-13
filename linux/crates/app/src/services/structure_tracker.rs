//! What a Structure tab would save, kept so the close prompt and the
//! save dispatcher can read it without reaching into the tab. The tab
//! replaces it on every edit; DDL has no per-change undo, only Discard
//! back to the table as it was read.

use super::pending_structure::PendingStructure;
use crate::workspace::{PendingState, SaveOutcome, SaveRejection, UnknownCause};

#[derive(Debug, Default)]
pub struct StructureChangeTracker {
    pending: Option<PendingStructure>,
    saving: bool,
    /// A save that may have landed. Nothing saves until the tab reads
    /// the table again or its changes are discarded.
    outcome_unknown: Option<UnknownCause>,
}

impl StructureChangeTracker {
    pub fn has_pending(&self) -> bool {
        self.pending.as_ref().is_some_and(PendingStructure::has_changes)
    }

    pub fn set_pending(&mut self, pending: Option<PendingStructure>) {
        self.pending = pending;
    }

    pub fn pending_state(&self) -> PendingState {
        if let Some(cause) = &self.outcome_unknown {
            return PendingState::OutcomeUnknown(cause.clone());
        }
        if self.saving {
            return PendingState::Saving;
        }
        match self.has_pending() {
            true => PendingState::Unsaved,
            false => PendingState::Clean,
        }
    }

    /// What Save writes, held as in flight until it settles, or `None`
    /// when there is nothing to. The tab's own checks run here too, so a
    /// save from a close prompt cannot skip them.
    pub fn begin_save(&mut self) -> Result<Option<PendingStructure>, SaveRejection> {
        if self.outcome_unknown.is_some() {
            return Err(SaveRejection::OutcomeUnknown);
        }
        if self.saving {
            return Err(SaveRejection::AlreadySaving);
        }
        let Some(pending) = self.pending.clone().filter(PendingStructure::has_changes) else {
            return Ok(None);
        };
        pending
            .check()
            .map_err(|blocker| SaveRejection::Invalid(crate::ui::structure_tab::save_blocker_text(&blocker)))?;
        self.saving = true;
        Ok(Some(pending))
    }

    /// A commit leaves nothing pending: the tab reads the table again and
    /// diffs against what is there now.
    pub fn settle_save(&mut self, outcome: &SaveOutcome) {
        self.saving = false;
        match outcome {
            SaveOutcome::Committed { .. } => self.pending = None,
            SaveOutcome::RolledBack(_) => {}
            SaveOutcome::Unknown(cause) => self.outcome_unknown = Some(cause.clone()),
        }
    }

    /// Drop what is pending, and with it a save whose outcome was
    /// unknown: the tab reads the table again.
    pub fn clear(&mut self) {
        self.pending = None;
        self.outcome_unknown = None;
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::ddl::{DraftColumn, DraftType, TableChanges, TableDraft};
    use tablepro_core::meta::TableRef;

    use super::*;

    fn new_table(columns: usize) -> PendingStructure {
        let mut draft = TableDraft::new(TableRef::unqualified("t"));
        for index in 0..columns {
            draft.columns.push(DraftColumn::new(
                format!("c{index}"),
                DraftType::Typed("int".to_owned()),
            ));
        }
        PendingStructure {
            original: None,
            draft,
            changes: TableChanges::default(),
            unparsed_defaults: Vec::new(),
        }
    }

    #[test]
    fn empty_tracker_has_no_pending() {
        let mut tracker = StructureChangeTracker::default();

        assert!(!tracker.has_pending());
        assert_eq!(tracker.begin_save(), Ok(None));
    }

    #[test]
    fn only_a_structure_with_changes_is_saved() {
        let mut tracker = StructureChangeTracker::default();
        tracker.set_pending(Some(new_table(0)));
        assert!(!tracker.has_pending());
        assert_eq!(tracker.begin_save(), Ok(None));

        tracker.set_pending(Some(new_table(1)));
        assert!(tracker.has_pending());
        assert_eq!(tracker.begin_save(), Ok(Some(new_table(1))));
        tracker.settle_save(&SaveOutcome::Committed { rows: None });

        assert!(!tracker.has_pending());
    }

    #[test]
    fn a_save_runs_once_and_an_unknown_outcome_holds_the_next() {
        let mut tracker = StructureChangeTracker::default();
        tracker.set_pending(Some(new_table(1)));

        assert!(matches!(tracker.begin_save(), Ok(Some(_))));
        assert_eq!(tracker.begin_save(), Err(SaveRejection::AlreadySaving));
        tracker.settle_save(&SaveOutcome::Unknown(UnknownCause::Closed));

        assert_eq!(tracker.begin_save(), Err(SaveRejection::OutcomeUnknown));
        assert!(tracker.has_pending());
        tracker.clear();
        assert_eq!(tracker.pending_state(), PendingState::Clean);
    }

    #[test]
    fn a_draft_the_tab_would_refuse_is_refused_here_too() {
        let mut tracker = StructureChangeTracker::default();
        let mut unnamed = new_table(1);
        unnamed.draft.columns[0].name = String::new();
        tracker.set_pending(Some(unnamed));

        assert!(matches!(tracker.begin_save(), Err(SaveRejection::Invalid(_))));
        assert_eq!(tracker.pending_state(), PendingState::Unsaved);
    }
}
