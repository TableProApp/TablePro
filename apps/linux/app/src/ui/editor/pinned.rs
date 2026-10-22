use super::stream_pages::StreamTerminal;
use super::{SqlEditor, StatementOutcome, StatementOutcomeKind, clear_results_box, render_outcomes};
use relm4::gtk;
use relm4::gtk::prelude::*;

pub(super) const MAX_PINNED: usize = 4;

fn has_grid_result(outcome: &StatementOutcome) -> bool {
    match &outcome.kind {
        StatementOutcomeKind::Rows(_) => true,
        StatementOutcomeKind::Streamed(result) => !matches!(result.terminal, StreamTerminal::Loading),
        _ => false,
    }
}

#[derive(Default)]
pub(super) struct PinnedResults {
    pins: Vec<StatementOutcome>,
    last: Vec<StatementOutcome>,
}

impl PinnedResults {
    pub(super) fn latest(&self) -> &[StatementOutcome] {
        &self.last
    }

    pub(super) fn is_pinned(&self) -> bool {
        !self.pins.is_empty()
    }

    pub(super) fn count(&self) -> usize {
        self.pins.len()
    }

    pub(super) fn has_results(&self) -> bool {
        self.last.iter().any(has_grid_result)
    }

    pub(super) fn show(&mut self, fresh: Vec<StatementOutcome>) -> Vec<StatementOutcome> {
        let mut shown: Vec<StatementOutcome> = self.pins.clone();
        shown.extend(fresh.iter().cloned());
        self.last = fresh;
        shown
    }

    pub(super) fn pin_last(&mut self) -> usize {
        let pinnable = self
            .last
            .iter()
            .filter(|outcome| has_grid_result(outcome))
            .cloned()
            .map(|outcome| StatementOutcome {
                pinned: true,
                ..outcome
            });
        self.pins.extend(pinnable);
        let excess = self.pins.len().saturating_sub(MAX_PINNED);
        self.pins.drain(..excess);
        self.pins.len()
    }

    pub(super) fn unpin_all(&mut self) -> Vec<StatementOutcome> {
        self.pins.clear();
        self.last.clone()
    }
}

impl SqlEditor {
    pub(super) fn refresh_pin_button(&self) {
        let label = if self.pinned.is_pinned() {
            crate::tr!("Unpin results ({n})").replace("{n}", &self.pinned.count().to_string())
        } else {
            crate::tr!("Pin results")
        };
        self.pin_button.set_label(&label);
        self.pin_button
            .set_sensitive(self.pinned.is_pinned() || self.pinned.has_results());
        self.refresh_result_exports();
        self.panel.refresh_errors(self.pinned.latest());
    }

    pub(super) fn show_pins_above(&mut self, page: &impl IsA<gtk::Widget>) {
        clear_results_box(&self.results_holder);
        let pins = self.pinned.show(Vec::new());
        if !pins.is_empty() {
            render_outcomes(
                &self.results_holder,
                &pins,
                &self.grid_sender,
                self.connection_id,
                self.database.clone(),
                self.result_view_settings.clone(),
            );
        }
        self.results_holder.append(page);
        self.refresh_pin_button();
    }

    pub(super) fn toggle_pin(&mut self) {
        if self.pinned.is_pinned() {
            let remaining = self.pinned.unpin_all();
            self.refresh_pin_button();
            clear_results_box(&self.results_holder);
            render_outcomes(
                &self.results_holder,
                &remaining,
                &self.grid_sender,
                self.connection_id,
                self.database.clone(),
                self.result_view_settings.clone(),
            );
            return;
        }
        let kept = self.pinned.pin_last();
        self.refresh_pin_button();
        let kept = kept.to_string();
        self.status
            .set_label(&crate::tr!("{n} pinned; they stay above the next run").replace("{n}", &kept));
    }
}

#[cfg(test)]
#[path = "../../../tests/support/pinned_tests.rs"]
mod tests;
