use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use tablepro_core::{ColumnInfo, FilterValue};

use super::filter_rule_object::FilterRuleObject;
use super::rule_operators::ValueShape;

/// The widget a rule's value is typed into, for the operator's value
/// shape, filled from the rule and writing each edit back into it.
/// The null tests take no value, so they have none.
pub(super) fn value_editor(rule: &FilterRuleObject, column: &ColumnInfo, shape: ValueShape) -> Option<gtk::Widget> {
    match shape {
        ValueShape::None => None,
        ValueShape::Single => Some(single_editor(rule, column).upcast()),
        ValueShape::Pair => Some(pair_editor(rule, column).upcast()),
        ValueShape::List => Some(list_editor(rule).upcast()),
    }
}

fn single_editor(rule: &FilterRuleObject, column: &ColumnInfo) -> gtk::Entry {
    let entry = gtk::Entry::builder()
        .placeholder_text(crate::i18n::gettext("Value"))
        .valign(gtk::Align::Center)
        .hexpand(true)
        .input_purpose(input_purpose_for(column))
        .build();
    if let Some(FilterValue::Single(text)) = rule.rule().value {
        entry.set_text(&text);
    }
    let rule = rule.clone();
    entry.connect_changed(move |entry| {
        rule.update(|rule| rule.value = Some(FilterValue::Single(entry.text().to_string())));
    });
    entry
}

fn pair_editor(rule: &FilterRuleObject, column: &ColumnInfo) -> gtk::Box {
    let bound = |placeholder: &str| {
        gtk::Entry::builder()
            .placeholder_text(placeholder)
            .valign(gtk::Align::Center)
            .input_purpose(input_purpose_for(column))
            .build()
    };
    let low = bound(&crate::i18n::gettext("From"));
    let high = bound(&crate::i18n::gettext("To"));
    if let Some(FilterValue::Pair(from, to)) = rule.rule().value {
        low.set_text(&from);
        high.set_text(&to);
    }
    // Each entry reads the other, so neither may hold it strongly.
    low.connect_changed(glib::clone!(
        #[weak]
        high,
        #[strong]
        rule,
        move |low| {
            rule.update(|rule| {
                rule.value = Some(FilterValue::Pair(low.text().to_string(), high.text().to_string()));
            });
        }
    ));
    high.connect_changed(glib::clone!(
        #[weak]
        low,
        #[strong]
        rule,
        move |high| {
            rule.update(|rule| {
                rule.value = Some(FilterValue::Pair(low.text().to_string(), high.text().to_string()));
            });
        }
    ));
    let pair = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(6)
        .build();
    pair.append(&low);
    pair.append(&high);
    pair
}

fn list_editor(rule: &FilterRuleObject) -> gtk::Entry {
    let entry = gtk::Entry::builder()
        .placeholder_text(crate::i18n::gettext("a, b, c"))
        .valign(gtk::Align::Center)
        .hexpand(true)
        .build();
    if let Some(FilterValue::List(items)) = rule.rule().value {
        entry.set_text(&items.join(", "));
    }
    let rule = rule.clone();
    entry.connect_changed(move |entry| {
        rule.update(|rule| rule.value = Some(FilterValue::List(list_items(&entry.text()))));
    });
    entry
}

/// The comma-separated items of a list value, with blanks dropped.
fn list_items(text: &str) -> Vec<String> {
    text.split(',')
        .map(|item| item.trim().to_owned())
        .filter(|item| !item.is_empty())
        .collect()
}

/// A numeric column gets the number keypad on a touch keyboard.
fn input_purpose_for(column: &ColumnInfo) -> gtk::InputPurpose {
    match column.column_type.kind.is_numeric() {
        true => gtk::InputPurpose::Number,
        false => gtk::InputPurpose::FreeForm,
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::{FilterOp, FilterRule};

    use super::super::rule_operators::placeholder_column;
    use super::*;
    use crate::test_support::descendants;

    fn rule_with(op: FilterOp, value: Option<FilterValue>) -> FilterRuleObject {
        FilterRuleObject::new(FilterRule {
            column: "a".to_owned(),
            op,
            value,
        })
    }

    fn entries(widget: &gtk::Widget) -> Vec<gtk::Entry> {
        std::iter::once(widget.clone())
            .chain(descendants(widget))
            .filter_map(|widget| widget.downcast::<gtk::Entry>().ok())
            .collect()
    }

    #[gtk4::test]
    fn the_null_tests_have_no_editor() {
        let rule = rule_with(FilterOp::IsNull, None);

        assert!(value_editor(&rule, &placeholder_column("a"), ValueShape::None).is_none());
    }

    #[gtk4::test]
    fn a_single_value_is_shown_and_written_back() {
        let rule = rule_with(FilterOp::Eq, Some(FilterValue::Single("1".to_owned())));
        let editor = value_editor(&rule, &placeholder_column("a"), ValueShape::Single).expect("an editor");
        let [entry] = entries(&editor).try_into().expect("one entry");
        assert_eq!(entry.text(), "1");

        entry.set_text("42");

        assert_eq!(rule.rule().value, Some(FilterValue::Single("42".to_owned())));
    }

    #[gtk4::test]
    fn a_list_value_splits_on_commas_and_drops_blanks() {
        let rule = rule_with(
            FilterOp::In,
            Some(FilterValue::List(vec!["x".to_owned(), "y".to_owned()])),
        );
        let editor = value_editor(&rule, &placeholder_column("a"), ValueShape::List).expect("an editor");
        let [entry] = entries(&editor).try_into().expect("one entry");
        assert_eq!(entry.text(), "x, y");

        entry.set_text(" a, ,b ,");

        assert_eq!(
            rule.rule().value,
            Some(FilterValue::List(vec!["a".to_owned(), "b".to_owned()]))
        );
    }

    #[gtk4::test]
    fn a_numeric_column_asks_for_the_number_keypad() {
        let mut amount = placeholder_column("amount");
        amount.column_type.kind = tablepro_core::column::ColumnKind::Integer(tablepro_core::column::IntegerKind {
            width: tablepro_core::column::IntegerWidth::W32,
            signed: true,
        });
        let rule = rule_with(FilterOp::Between, ValueShape::Pair.empty_value());
        let editor = value_editor(&rule, &amount, ValueShape::Pair).expect("an editor");

        let purposes: Vec<gtk::InputPurpose> = entries(&editor).iter().map(gtk::Entry::input_purpose).collect();

        assert_eq!(purposes, [gtk::InputPurpose::Number, gtk::InputPurpose::Number]);
    }
}
