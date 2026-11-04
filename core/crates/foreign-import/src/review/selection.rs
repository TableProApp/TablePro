use std::collections::{HashMap, HashSet};

use super::{ConnectionRow, ImportReview, QueryRow, Resolution};

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ImportSelection {
    selected: HashSet<String>,
    // Kept across uncheck, so checking a row again restores what the user picked.
    chosen: HashMap<String, Resolution>,
    query_overrides: HashMap<String, bool>,
}

impl ImportSelection {
    pub fn defaults(review: &ImportReview) -> Self {
        let mut selection = Self::default();
        for row in review.connections() {
            if let Some(first) = row.resolutions.first() {
                selection.chosen.insert(row.reference.clone(), *first);
            }
            if row.selected_by_default {
                selection.selected.insert(row.reference.clone());
            }
        }
        selection
    }

    pub fn resolution(&self, reference: &str) -> Option<Resolution> {
        if !self.selected.contains(reference) {
            return None;
        }
        self.chosen.get(reference).copied()
    }

    pub fn is_selected(&self, reference: &str) -> bool {
        self.selected.contains(reference)
    }

    pub fn set_selected(&mut self, selected: bool, reference: &str, review: &ImportReview) {
        if !selected {
            self.selected.remove(reference);
            return;
        }
        let Some(row) = review.connection_row(reference) else {
            return;
        };
        let Some(fallback) = row.resolutions.first().copied() else {
            return;
        };
        let keeps_stored = self
            .chosen
            .get(reference)
            .is_some_and(|stored| row.resolutions.contains(stored) && !self.is_replace_held(*stored, reference));
        if !keeps_stored {
            self.chosen.insert(reference.to_owned(), fallback);
        }
        self.selected.insert(reference.to_owned());
    }

    pub fn resolve(&mut self, reference: &str, resolution: Resolution, review: &ImportReview) -> bool {
        let offered = review
            .connection_row(reference)
            .is_some_and(|row| row.resolutions.contains(&resolution));
        if !offered || self.is_replace_held(resolution, reference) {
            return false;
        }
        self.chosen.insert(reference.to_owned(), resolution);
        true
    }

    pub fn offered_resolutions(&self, row: &ConnectionRow) -> Vec<Resolution> {
        row.resolutions
            .iter()
            .copied()
            .filter(|resolution| !self.is_replace_held(*resolution, &row.reference))
            .collect()
    }

    pub fn set_included(&mut self, included: bool, reference: &str) {
        self.query_overrides.insert(reference.to_owned(), included);
    }

    // The user's choice for a row, which can differ from whether it imports: a row another selected
    // row already adds keeps its choice for when that row is unchecked.
    pub fn wants_query(&self, row: &QueryRow) -> bool {
        self.query_overrides
            .get(&row.reference)
            .copied()
            .unwrap_or(row.suggested)
    }

    pub fn query_override(&self, reference: &str) -> Option<bool> {
        self.query_overrides.get(reference).copied()
    }

    fn is_replace_held(&self, resolution: Resolution, reference: &str) -> bool {
        let Resolution::Replace(target) = resolution else {
            return false;
        };
        self.selected
            .iter()
            .any(|other| other != reference && self.chosen.get(other) == Some(&Resolution::Replace(target)))
    }
}
