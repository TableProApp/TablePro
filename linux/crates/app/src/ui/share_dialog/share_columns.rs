use std::cell::RefCell;
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::masking::detect::{MaskSuggestion, SuggestionReason};
use tablepro_core::masking::{MaskingStyle, ShareChoice, SharePlan};

use crate::i18n::{gettext, gettext_f, ngettext_f};
use crate::services::share_subject::SharedRows;
use crate::ui::masking_text::{style_label, values_reason};

const KEEP: &str = "keep";
const MASK: &str = "mask";
const REMOVE: &str = "remove";

// One shared column as the sheet starts it (PLAN-MASKING 8.4).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ShareColumn {
    pub name: String,
    // The style the connection's rules mask it with on the way out, which no choice can show past.
    pub rule: Option<MaskingStyle>,
    // The rule is only that nothing traced the column to a table column.
    pub untraced: bool,
    pub suggestion: Option<MaskSuggestion>,
}

impl ShareColumn {
    // A share hides what looks sensitive unless the user keeps it.
    pub(crate) fn initial(&self) -> ShareChoice {
        match (self.rule, self.suggestion) {
            (Some(rule), _) => ShareChoice::Mask(rule),
            (None, Some(suggestion)) => ShareChoice::Mask(suggestion.style),
            (None, None) => ShareChoice::Keep,
        }
    }

    pub(crate) fn keeps(&self) -> bool {
        self.rule.is_none()
    }

    // The styles it may take: for a ruled column, its rule's and those that hide at least as much.
    pub(crate) fn styles(&self) -> Vec<MaskingStyle> {
        MaskingStyle::ALL
            .into_iter()
            .filter(|style| self.rule.is_none_or(|rule| style.hides_at_least(rule)))
            .collect()
    }

    pub(crate) fn reason(&self) -> Option<String> {
        if self.rule.is_some() {
            return Some(match self.untraced {
                true => gettext("Masked because TablePro cannot tell which table column this comes from."),
                false => gettext("A masking rule hides this column"),
            });
        }
        Some(match self.suggestion?.reason {
            SuggestionReason::ColumnName { .. } => gettext("The name looks like personal data"),
            SuggestionReason::Values { kind } => values_reason(kind),
        })
    }
}

pub(crate) fn share_columns(rows: &SharedRows, max_rows: u64, max_columns: u64) -> Vec<ShareColumn> {
    rows.suggestions(max_rows, max_columns)
        .into_iter()
        .zip(rows.columns.iter())
        .enumerate()
        .map(|(index, (suggestion, column))| ShareColumn {
            name: column.name.clone(),
            rule: rows.rules.style(index),
            untraced: rows.rules.is_masked(index) && rows.untraced.contains(&index),
            suggestion,
        })
        .collect()
}

// The line under the list.
pub(crate) fn summary(plan: &SharePlan, choices: &[ShareChoice]) -> String {
    let masked = plan.masked().iter().filter(|style| style.is_some()).count() as u64;
    let removed = choices.iter().filter(|choice| **choice == ShareChoice::Remove).count();
    ngettext_f(
        "{n} column masked, {m} removed.",
        "{n} columns masked, {m} removed.",
        masked,
        &[("n", &masked.to_string()), ("m", &removed.to_string())],
    )
}

pub(crate) fn detection_note(columns: &[ShareColumn]) -> Option<String> {
    columns
        .iter()
        .any(|column| column.rule.is_none() && column.suggestion.is_some())
        .then(|| gettext("TablePro masked columns that look sensitive. Check them before sharing."))
}

pub(super) fn columns_group(
    columns: &[ShareColumn],
    choices: &Rc<RefCell<Vec<ShareChoice>>>,
    changed: &Rc<dyn Fn()>,
    summary: &gtk::Label,
) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder().title(gettext("Columns")).build();
    if let Some(note) = detection_note(columns) {
        group.set_description(Some(&note));
    }
    for (index, column) in columns.iter().enumerate() {
        let choice = choices.borrow().get(index).copied().unwrap_or(ShareChoice::Keep);
        group.add(&column_row(column, index, choice, choices, changed));
    }
    group.add(summary);
    group
}

pub(super) fn summary_label() -> gtk::Label {
    gtk::Label::builder()
        .xalign(0.0)
        .wrap(true)
        .margin_top(12)
        .css_classes(["dimmed", "caption"])
        .build()
}

fn column_row(
    column: &ShareColumn,
    index: usize,
    choice: ShareChoice,
    choices: &Rc<RefCell<Vec<ShareChoice>>>,
    changed: &Rc<dyn Fn()>,
) -> adw::ActionRow {
    let row = adw::ActionRow::builder().title(&column.name).use_markup(false).build();
    if let Some(reason) = column.reason() {
        row.set_subtitle(&reason);
    }
    let styles = column.styles();
    let labels: Vec<String> = styles.iter().map(|style| style_label(*style)).collect();
    let refs: Vec<&str> = labels.iter().map(String::as_str).collect();
    let style = gtk::DropDown::from_strings(&refs);
    style.set_valign(gtk::Align::Center);
    style.update_property(&[gtk::accessible::Property::Label(&gettext_f(
        "Mask style for {column}",
        &[("column", &column.name)],
    ))]);
    let toggles = adw::ToggleGroup::builder().valign(gtk::Align::Center).build();
    for (name, label, enabled) in [
        (KEEP, gettext("Keep"), column.keeps()),
        (MASK, gettext("Mask"), true),
        (REMOVE, gettext("Remove"), true),
    ] {
        toggles.add(adw::Toggle::builder().name(name).label(label).enabled(enabled).build());
    }
    toggles.update_property(&[gtk::accessible::Property::Label(&gettext_f(
        "What the link does with {column}",
        &[("column", &column.name)],
    ))]);
    let (active, masked) = match choice {
        ShareChoice::Keep => (KEEP, None),
        ShareChoice::Mask(style) => (MASK, Some(style)),
        ShareChoice::Remove => (REMOVE, None),
    };
    toggles.set_active_name(Some(active));
    let shown = masked
        .or(column.suggestion.map(|suggestion| suggestion.style))
        .or(column.rule);
    if let Some(at) = shown.and_then(|shown| styles.iter().position(|style| *style == shown)) {
        style.set_selected(at as u32);
    }
    style.set_visible(active == MASK);
    let read = {
        let (toggles, style, choices, changed) =
            (toggles.downgrade(), style.downgrade(), choices.clone(), changed.clone());
        move || {
            let (Some(toggles), Some(style)) = (toggles.upgrade(), style.upgrade()) else {
                return;
            };
            let choice = match toggles.active_name().as_deref() {
                Some(MASK) => styles
                    .get(style.selected() as usize)
                    .copied()
                    .map_or(ShareChoice::Keep, ShareChoice::Mask),
                Some(REMOVE) => ShareChoice::Remove,
                _ => ShareChoice::Keep,
            };
            style.set_visible(matches!(choice, ShareChoice::Mask(_)));
            if let Some(slot) = choices.borrow_mut().get_mut(index) {
                *slot = choice;
            }
            changed();
        }
    };
    let read = Rc::new(read);
    let on_toggle = read.clone();
    toggles.connect_active_name_notify(move |_| on_toggle());
    style.connect_selected_notify(move |_| read());
    row.add_suffix(&style);
    row.add_suffix(&toggles);
    row
}

#[cfg(test)]
mod tests {
    use tablepro_core::masking::ColumnMasks;
    use tablepro_core::masking::detect::SensitiveKind;

    use super::*;

    fn column(rule: Option<MaskingStyle>, suggestion: Option<MaskingStyle>) -> ShareColumn {
        ShareColumn {
            name: "c".to_owned(),
            rule,
            untraced: false,
            suggestion: suggestion.map(|style| MaskSuggestion {
                style,
                reason: SuggestionReason::Values {
                    kind: SensitiveKind::Email,
                },
            }),
        }
    }

    #[test]
    fn a_ruled_column_starts_masked_and_never_offers_keep_or_a_weaker_style() {
        let ruled = column(Some(MaskingStyle::Email), None);

        assert_eq!(ruled.initial(), ShareChoice::Mask(MaskingStyle::Email));
        assert!(!ruled.keeps());
        assert_eq!(
            ruled.styles(),
            [MaskingStyle::Full, MaskingStyle::Email, MaskingStyle::Null]
        );
        assert_eq!(ruled.reason().as_deref(), Some("A masking rule hides this column"));
        let untraced = ShareColumn {
            untraced: true,
            ..column(Some(MaskingStyle::Full), None)
        };
        assert_eq!(
            untraced.reason().as_deref(),
            Some("Masked because TablePro cannot tell which table column this comes from.")
        );
        assert!(!untraced.keeps());
    }

    #[test]
    fn a_detected_column_starts_masked_and_may_be_kept() {
        let detected = column(None, Some(MaskingStyle::Email));
        let plain = column(None, None);

        assert_eq!(detected.initial(), ShareChoice::Mask(MaskingStyle::Email));
        assert!(detected.keeps());
        assert_eq!(detected.styles().len(), 5);
        assert_eq!(plain.initial(), ShareChoice::Keep);
        assert_eq!(plain.reason(), None);
        assert!(detection_note(std::slice::from_ref(&plain)).is_none());
        assert!(detection_note(&[plain, detected]).is_some());
    }

    #[test]
    fn the_summary_counts_masked_and_removed_columns() {
        let choices = [
            ShareChoice::Remove,
            ShareChoice::Mask(MaskingStyle::Hash),
            ShareChoice::Keep,
        ];
        let rules = ColumnMasks::new(vec![None, None, Some(MaskingStyle::Full)]);
        let plan = SharePlan::new(3, &rules, &ColumnMasks::none(), &choices, 100);

        assert_eq!(summary(&plan, &choices), "2 columns masked, 1 removed.");
    }
}
