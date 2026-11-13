use std::cell::RefCell;
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::masking::detect::{MaskSuggestion, SuggestionReason};
use tablepro_core::masking::{MaskingStyle, ShareChoice, SharePlan};

use super::masking_text::{style_label, values_reason};
use crate::i18n::{gettext, gettext_f, ngettext_f};
use crate::services::share_subject::SharedRows;

// One shared column as the sheet starts it (PLAN-MASKING 8.4).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ShareColumn {
    pub name: String,
    pub suggestion: Option<MaskSuggestion>,
}

impl ShareColumn {
    // A share hides what looks sensitive unless the user keeps it.
    pub(crate) fn initial(&self) -> ShareChoice {
        match self.suggestion {
            Some(suggestion) => ShareChoice::Mask(suggestion.style),
            None => ShareChoice::Keep,
        }
    }

    // What the picker offers, in order: Keep, each style, then Remove.
    pub(crate) fn options() -> Vec<ShareChoice> {
        [ShareChoice::Keep]
            .into_iter()
            .chain(MaskingStyle::ALL.into_iter().map(ShareChoice::Mask))
            .chain([ShareChoice::Remove])
            .collect()
    }

    pub(crate) fn reason(&self) -> Option<String> {
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
        .map(|(suggestion, column)| ShareColumn {
            name: column.name.clone(),
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
        .any(|column| column.suggestion.is_some())
        .then(|| gettext("TablePro masked columns that look sensitive. Check them before sharing."))
}

// The Columns group with its counts line; the rows go in once the detectors have read the columns.
pub(super) fn columns_group(summary: &gtk::Label) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder().title(gettext("Columns")).build();
    group.add(summary);
    group
}

// Each shared column with Keep, Mask or Remove and, for Mask, its style, above the counts line.
pub(super) fn fill_columns(
    group: &adw::PreferencesGroup,
    columns: &[ShareColumn],
    choices: &Rc<RefCell<Vec<ShareChoice>>>,
    changed: &Rc<dyn Fn()>,
    summary: &gtk::Label,
) {
    if let Some(note) = detection_note(columns) {
        group.set_description(Some(&note));
    }
    group.remove(summary);
    for (index, column) in columns.iter().enumerate() {
        let choice = choices.borrow().get(index).copied().unwrap_or(ShareChoice::Keep);
        group.add(&column_row(column, index, choice, choices, changed));
    }
    group.add(summary);
}

pub(super) fn summary_label() -> gtk::Label {
    gtk::Label::builder()
        .xalign(0.0)
        .wrap(true)
        .margin_top(12)
        .css_classes(["dimmed", "caption"])
        .build()
}

// One picker per column, Keep, Mask as each style, then Remove. The row shows the short form of the choice,
// so it fits the sheet's width; the list names each in full.
fn column_row(
    column: &ShareColumn,
    index: usize,
    choice: ShareChoice,
    choices: &Rc<RefCell<Vec<ShareChoice>>>,
    changed: &Rc<dyn Fn()>,
) -> adw::ComboRow {
    let options = ShareColumn::options();
    let labels: Vec<String> = options.iter().map(|option| choice_label(*option)).collect();
    let refs: Vec<&str> = labels.iter().map(String::as_str).collect();
    let row = adw::ComboRow::builder()
        .title(&column.name)
        .use_markup(false)
        .model(&gtk::StringList::new(&refs))
        .expression(gtk::PropertyExpression::new(
            gtk::StringObject::static_type(),
            None::<gtk::Expression>,
            "string",
        ))
        .build();
    let short: Vec<(String, String)> = options
        .iter()
        .map(|option| (choice_label(*option), short_label(*option)))
        .collect();
    row.set_factory(Some(&label_factory(move |full| {
        short
            .iter()
            .find(|(long, _)| long == full)
            .map_or_else(|| full.to_owned(), |(_, short)| short.clone())
    })));
    row.set_list_factory(Some(&label_factory(str::to_owned)));
    if let Some(reason) = column.reason() {
        row.set_subtitle(&reason);
    }
    let at = options
        .iter()
        .position(|option| *option == choice)
        .or_else(|| options.iter().position(|option| *option == column.initial()))
        .unwrap_or_default();
    row.set_selected(at as u32);
    let (choices, changed) = (choices.clone(), changed.clone());
    row.connect_selected_notify(move |row| {
        let Some(picked) = options.get(row.selected() as usize).copied() else {
            return;
        };
        if let Some(slot) = choices.borrow_mut().get_mut(index) {
            *slot = picked;
        }
        changed();
    });
    row
}

// A label per choice, from the full text the model holds.
fn label_factory(text: impl Fn(&str) -> String + 'static) -> gtk::SignalListItemFactory {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(|_, item| {
        if let Some(item) = item.downcast_ref::<gtk::ListItem>() {
            item.set_child(Some(&gtk::Label::builder().xalign(0.0).build()));
        }
    });
    factory.connect_bind(move |_, item| {
        let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        if let (Some(label), Some(full)) = (
            item.child().and_downcast::<gtk::Label>(),
            item.item().and_downcast::<gtk::StringObject>(),
        ) {
            label.set_label(&text(&full.string()));
        }
    });
    factory
}

// What the row shows of a choice: a style alone reads as masking under the column's name.
pub(crate) fn short_label(choice: ShareChoice) -> String {
    match choice {
        ShareChoice::Mask(style) => style_label(style),
        other => choice_label(other),
    }
}

pub(crate) fn choice_label(choice: ShareChoice) -> String {
    match choice {
        ShareChoice::Keep => gettext("Keep"),
        ShareChoice::Mask(style) => gettext_f("Mask as {style}", &[("style", &style_label(style))]),
        ShareChoice::Remove => gettext("Remove"),
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::masking::detect::SensitiveKind;

    use super::*;

    fn column(suggestion: Option<MaskingStyle>) -> ShareColumn {
        ShareColumn {
            name: "c".to_owned(),
            suggestion: suggestion.map(|style| MaskSuggestion {
                style,
                reason: SuggestionReason::Values {
                    kind: SensitiveKind::Email,
                },
            }),
        }
    }

    #[test]
    fn every_column_offers_keep_each_style_and_remove() {
        assert_eq!(
            ShareColumn::options(),
            [
                ShareChoice::Keep,
                ShareChoice::Mask(MaskingStyle::Full),
                ShareChoice::Mask(MaskingStyle::LastFour),
                ShareChoice::Mask(MaskingStyle::Email),
                ShareChoice::Mask(MaskingStyle::Hash),
                ShareChoice::Mask(MaskingStyle::Null),
                ShareChoice::Remove
            ]
        );
    }

    #[test]
    fn a_detected_column_starts_masked_and_may_be_kept() {
        let detected = column(Some(MaskingStyle::Email));
        let plain = column(None);

        assert_eq!(detected.initial(), ShareChoice::Mask(MaskingStyle::Email));
        assert_eq!(detected.reason().as_deref(), Some("Values look like email addresses"));
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
            ShareChoice::Mask(MaskingStyle::Full),
            ShareChoice::Keep,
        ];
        let plan = SharePlan::new(4, &choices, 100);

        assert_eq!(summary(&plan, &choices), "2 columns masked, 1 removed.");
    }
}
