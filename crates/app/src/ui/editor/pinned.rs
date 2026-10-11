use super::{SqlEditor, StatementOutcome, StatementOutcomeKind, clear_box, render_outcomes};
use relm4::gtk::prelude::*;

pub(super) const MAX_PINNED: usize = 4;

#[derive(Default)]
pub(super) struct PinnedResults {
    pins: Vec<StatementOutcome>,
    last: Vec<StatementOutcome>,
}

impl PinnedResults {
    pub(super) fn is_pinned(&self) -> bool {
        !self.pins.is_empty()
    }

    pub(super) fn count(&self) -> usize {
        self.pins.len()
    }

    pub(super) fn has_results(&self) -> bool {
        self.last
            .iter()
            .any(|outcome| matches!(outcome.kind, StatementOutcomeKind::Rows(_)))
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
            .filter(|outcome| matches!(outcome.kind, StatementOutcomeKind::Rows(_)))
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
    }

    pub(super) fn toggle_pin(&mut self) {
        if self.pinned.is_pinned() {
            let remaining = self.pinned.unpin_all();
            self.refresh_pin_button();
            clear_box(&self.results_holder);
            render_outcomes(
                &self.results_holder,
                &remaining,
                &self.grid_sender,
                self.connection_id,
                self.database.clone(),
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
mod tests {
    use super::*;

    fn rows(sql: &str) -> StatementOutcome {
        StatementOutcome {
            sql_preview: sql.into(),
            elapsed_ms: 1,
            kind: StatementOutcomeKind::Rows(Vec::new()),
            pinned: false,
        }
    }

    fn failed(sql: &str) -> StatementOutcome {
        StatementOutcome {
            kind: StatementOutcomeKind::Error("boom".into()),
            ..rows(sql)
        }
    }

    #[test]
    fn nothing_is_pinned_until_asked() {
        let mut pins = PinnedResults::default();
        let shown = pins.show(vec![rows("SELECT 1")]);
        assert_eq!(shown.len(), 1);
        assert!(!pins.is_pinned());
        assert!(pins.has_results());
    }

    #[test]
    fn pinned_results_stay_ahead_of_the_next_run() {
        let mut pins = PinnedResults::default();
        pins.show(vec![rows("SELECT 1"), failed("SELECT x")]);
        assert_eq!(pins.pin_last(), 1);

        let shown = pins.show(vec![rows("SELECT 2")]);

        assert_eq!(shown.len(), 2);
        assert!(shown[0].pinned);
        assert_eq!(shown[0].sql_preview, "SELECT 1");
        assert!(!shown[1].pinned);
    }

    #[test]
    fn only_row_results_are_pinned() {
        let mut pins = PinnedResults::default();
        pins.show(vec![failed("SELECT x")]);
        assert!(!pins.has_results());
        assert_eq!(pins.pin_last(), 0);
    }

    #[test]
    fn the_oldest_pins_are_dropped_past_the_limit() {
        let mut pins = PinnedResults::default();
        for index in 0..=MAX_PINNED {
            pins.show(vec![rows(&format!("SELECT {index}"))]);
            pins.pin_last();
        }
        assert_eq!(pins.count(), MAX_PINNED);
        let shown = pins.show(Vec::new());
        assert_eq!(shown[0].sql_preview, "SELECT 1");
    }

    #[test]
    fn unpinning_returns_the_latest_run_alone() {
        let mut pins = PinnedResults::default();
        pins.show(vec![rows("SELECT 1")]);
        pins.pin_last();
        pins.show(vec![rows("SELECT 2")]);

        let remaining = pins.unpin_all();

        assert!(!pins.is_pinned());
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].sql_preview, "SELECT 2");
    }
}
