//! The Highlight Rules popover: the rules of the grid in front, each a
//! condition on a column and the colour it paints, as the macOS bar's
//! pencil opens (`HighlightRulesPopover`). Every change applies at once.

use std::cell::RefCell;
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use tablepro_core::filter::{FilterOp, FilterValue};

use super::DataGrid;
use crate::i18n::gettext;
use crate::services::grid::{HighlightColor, HighlightRule, HighlightTarget};

/// The operators a rule offers, in the order the dropdown lists them.
const OPERATORS: [FilterOp; 16] = [
    FilterOp::Eq,
    FilterOp::NotEq,
    FilterOp::Gt,
    FilterOp::GtEq,
    FilterOp::Lt,
    FilterOp::LtEq,
    FilterOp::Contains,
    FilterOp::StartsWith,
    FilterOp::EndsWith,
    FilterOp::Like,
    FilterOp::NotLike,
    FilterOp::IsNull,
    FilterOp::IsNotNull,
    FilterOp::In,
    FilterOp::NotIn,
    FilterOp::Between,
];

fn operator_label(op: FilterOp) -> String {
    match op {
        FilterOp::Eq => gettext("equals"),
        FilterOp::NotEq => gettext("doesn't equal"),
        FilterOp::Gt => gettext("greater than"),
        FilterOp::GtEq => gettext("at least"),
        FilterOp::Lt => gettext("less than"),
        FilterOp::LtEq => gettext("at most"),
        FilterOp::Contains => gettext("contains"),
        FilterOp::StartsWith => gettext("starts with"),
        FilterOp::EndsWith => gettext("ends with"),
        FilterOp::Like | FilterOp::Ilike => gettext("matches pattern"),
        FilterOp::NotLike => gettext("doesn't match pattern"),
        FilterOp::IsNull => gettext("is empty"),
        FilterOp::IsNotNull => gettext("is not empty"),
        FilterOp::In => gettext("is one of"),
        FilterOp::NotIn => gettext("is none of"),
        FilterOp::Between => gettext("between"),
    }
}

fn color_label(color: HighlightColor) -> String {
    match color {
        HighlightColor::Red => gettext("Red"),
        HighlightColor::Orange => gettext("Orange"),
        HighlightColor::Yellow => gettext("Yellow"),
        HighlightColor::Green => gettext("Green"),
        HighlightColor::Blue => gettext("Blue"),
        HighlightColor::Purple => gettext("Purple"),
        HighlightColor::Gray => gettext("Gray"),
    }
}

/// The blank value an operator takes, so a rule never holds one of another shape.
fn blank_for(op: FilterOp) -> Option<FilterValue> {
    match op {
        FilterOp::IsNull | FilterOp::IsNotNull => None,
        FilterOp::In | FilterOp::NotIn => Some(FilterValue::List(Vec::new())),
        FilterOp::Between => Some(FilterValue::Pair(String::new(), String::new())),
        _ => Some(FilterValue::Single(String::new())),
    }
}

/// What the value entry shows for a rule, and the other way: a list is
/// comma separated, a range is `low, high`.
fn value_text(value: &Option<FilterValue>) -> String {
    match value {
        None => String::new(),
        Some(FilterValue::Single(text)) => text.clone(),
        Some(FilterValue::Pair(low, high)) => format!("{low}, {high}"),
        Some(FilterValue::List(items)) => items.join(", "),
    }
}

fn value_from(op: FilterOp, text: &str) -> Option<FilterValue> {
    let parts = || text.split(',').map(|part| part.trim().to_owned());
    match op {
        FilterOp::IsNull | FilterOp::IsNotNull => None,
        FilterOp::In | FilterOp::NotIn => Some(FilterValue::List(parts().filter(|part| !part.is_empty()).collect())),
        FilterOp::Between => {
            let mut parts = parts();
            Some(FilterValue::Pair(
                parts.next().unwrap_or_default(),
                parts.next().unwrap_or_default(),
            ))
        }
        _ => Some(FilterValue::Single(text.to_owned())),
    }
}

type Rules = Rc<RefCell<Vec<HighlightRule>>>;

/// The popover for `grid`, holding the rules it has now.
pub(crate) fn build(grid: &DataGrid) -> gtk::Popover {
    let rules: Rules = Rc::new(RefCell::new(grid.highlight_rules()));
    let list = gtk::Box::new(gtk::Orientation::Vertical, 8);
    let scrolled = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .propagate_natural_height(true)
        .max_content_height(360)
        .child(&list)
        .build();
    let add = gtk::Button::with_label(&gettext("Add Rule"));
    add.set_halign(gtk::Align::Start);
    let heading = gtk::Label::builder()
        .label(gettext("Highlight Rules"))
        .xalign(0.0)
        .build();
    heading.add_css_class("heading");
    let empty = gtk::Label::builder()
        .label(gettext("No rules. Add one to colour the rows or cells that meet it."))
        .wrap(true)
        .xalign(0.0)
        .build();
    empty.add_css_class("dimmed");
    let body = gtk::Box::new(gtk::Orientation::Vertical, 10);
    body.set_margin_top(12);
    body.set_margin_bottom(12);
    body.set_margin_start(12);
    body.set_margin_end(12);
    body.set_width_request(380);
    body.append(&heading);
    body.append(&empty);
    body.append(&scrolled);
    body.append(&add);
    let popover = gtk::Popover::builder().child(&body).build();

    let weak = grid.downgrade();
    let apply = {
        let rules = rules.clone();
        move || {
            if let Some(grid) = weak.upgrade() {
                grid.set_highlight_rules(rules.borrow().clone());
            }
        }
    };
    let rebuild: Rc<RefCell<Option<Box<dyn Fn()>>>> = Rc::default();
    let rebuild_now = {
        let (rules, list, empty, apply, rebuild, grid) = (
            rules.clone(),
            list.clone(),
            empty.clone(),
            apply.clone(),
            rebuild.clone(),
            grid.downgrade(),
        );
        move || {
            while let Some(child) = list.first_child() {
                list.remove(&child);
            }
            empty.set_visible(rules.borrow().is_empty());
            let columns: Vec<String> = grid
                .upgrade()
                .map(|grid| grid.grid_columns().iter().map(|column| column.name.clone()).collect())
                .unwrap_or_default();
            let count = rules.borrow().len();
            for index in 0..count {
                list.append(&rule_row(index, &rules, &columns, &apply, &rebuild));
            }
        }
    };
    rebuild.replace(Some(Box::new(rebuild_now.clone())));
    rebuild_now();

    add.connect_clicked({
        let (rules, apply, rebuild) = (rules.clone(), apply.clone(), rebuild.clone());
        let columns: Vec<String> = grid.grid_columns().iter().map(|column| column.name.clone()).collect();
        move |_| {
            let Some(first) = columns.first() else {
                return;
            };
            rules.borrow_mut().push(HighlightRule::new(first.clone()));
            apply();
            if let Some(rebuild) = rebuild.borrow().as_ref() {
                rebuild();
            }
        }
    });
    popover
}

fn rule_row(
    index: usize,
    rules: &Rules,
    columns: &[String],
    apply: &(impl Fn() + Clone + 'static),
    rebuild: &Rc<RefCell<Option<Box<dyn Fn()>>>>,
) -> gtk::Widget {
    let rule = rules.borrow()[index].clone();
    let card = gtk::Box::new(gtk::Orientation::Vertical, 6);
    card.add_css_class("card");
    card.set_margin_start(1);
    card.set_margin_end(1);
    let inner = gtk::Box::new(gtk::Orientation::Vertical, 6);
    inner.set_margin_top(8);
    inner.set_margin_bottom(8);
    inner.set_margin_start(8);
    inner.set_margin_end(8);
    card.append(&inner);

    let edit = {
        let (rules, apply) = (rules.clone(), apply.clone());
        move |change: &dyn Fn(&mut HighlightRule)| {
            if let Some(rule) = rules.borrow_mut().get_mut(index) {
                change(rule);
            }
            apply();
        }
    };

    let top = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    let enabled = gtk::Switch::builder()
        .active(rule.enabled)
        .valign(gtk::Align::Center)
        .build();
    enabled.update_property(&[gtk::accessible::Property::Label(&gettext("Rule enabled"))]);
    enabled.connect_active_notify({
        let edit = edit.clone();
        move |switch| edit(&|rule| rule.enabled = switch.is_active())
    });
    let names: Vec<&str> = columns.iter().map(String::as_str).collect();
    let column = gtk::DropDown::from_strings(&names);
    column.set_hexpand(true);
    column.set_selected(
        columns
            .iter()
            .position(|name| *name == rule.column)
            .map_or(0, |at| at as u32),
    );
    column.update_property(&[gtk::accessible::Property::Label(&gettext("Column"))]);
    column.connect_selected_notify({
        let (edit, columns) = (edit.clone(), columns.to_vec());
        move |dropdown| {
            if let Some(name) = columns.get(dropdown.selected() as usize) {
                edit(&|rule| rule.column = name.clone());
            }
        }
    });
    let remove = gtk::Button::from_icon_name("edit-delete-symbolic");
    remove.add_css_class("flat");
    remove.set_tooltip_text(Some(&gettext("Remove Rule")));
    remove.update_property(&[gtk::accessible::Property::Label(&gettext("Remove Rule"))]);
    remove.connect_clicked({
        let (rules, apply, rebuild) = (rules.clone(), apply.clone(), rebuild.clone());
        move |_| {
            if index < rules.borrow().len() {
                rules.borrow_mut().remove(index);
            }
            apply();
            if let Some(rebuild) = rebuild.borrow().as_ref() {
                rebuild();
            }
        }
    });
    top.append(&enabled);
    top.append(&column);
    top.append(&remove);
    inner.append(&top);

    let middle = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    let labels: Vec<String> = OPERATORS.iter().map(|op| operator_label(*op)).collect();
    let label_refs: Vec<&str> = labels.iter().map(String::as_str).collect();
    let operator = gtk::DropDown::from_strings(&label_refs);
    operator.set_selected(OPERATORS.iter().position(|op| *op == rule.op).map_or(0, |at| at as u32));
    operator.update_property(&[gtk::accessible::Property::Label(&gettext("Condition"))]);
    let value = gtk::Entry::builder()
        .hexpand(true)
        .placeholder_text(gettext("Value"))
        .text(value_text(&rule.value))
        .visible(!matches!(rule.op, FilterOp::IsNull | FilterOp::IsNotNull))
        .build();
    value.update_property(&[gtk::accessible::Property::Label(&gettext("Value"))]);
    operator.connect_selected_notify({
        let (edit, value, rebuild) = (edit.clone(), value.clone(), rebuild.clone());
        move |dropdown| {
            let Some(op) = OPERATORS.get(dropdown.selected() as usize).copied() else {
                return;
            };
            edit(&|rule| {
                rule.op = op;
                rule.value = blank_for(op);
            });
            value.set_visible(!matches!(op, FilterOp::IsNull | FilterOp::IsNotNull));
            value.set_text("");
            let _ = &rebuild;
        }
    });
    value.connect_changed({
        let (edit, operator) = (edit.clone(), operator.clone());
        move |entry| {
            let Some(op) = OPERATORS.get(operator.selected() as usize).copied() else {
                return;
            };
            let text = entry.text();
            edit(&|rule| rule.value = value_from(op, &text));
        }
    });
    middle.append(&operator);
    middle.append(&value);
    inner.append(&middle);

    let bottom = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    let color_labels: Vec<String> = HighlightColor::ALL.iter().map(|color| color_label(*color)).collect();
    let color_refs: Vec<&str> = color_labels.iter().map(String::as_str).collect();
    let color = gtk::DropDown::from_strings(&color_refs);
    color.set_selected(
        HighlightColor::ALL
            .iter()
            .position(|c| *c == rule.color)
            .map_or(0, |at| at as u32),
    );
    color.update_property(&[gtk::accessible::Property::Label(&gettext("Colour"))]);
    color.connect_selected_notify({
        let edit = edit.clone();
        move |dropdown| {
            if let Some(color) = HighlightColor::ALL.get(dropdown.selected() as usize).copied() {
                edit(&|rule| rule.color = color);
            }
        }
    });
    let targets = [gettext("Row"), gettext("Cell")];
    let target_refs: Vec<&str> = targets.iter().map(String::as_str).collect();
    let target = gtk::DropDown::from_strings(&target_refs);
    target.set_selected(u32::from(rule.target == HighlightTarget::Cell));
    target.update_property(&[gtk::accessible::Property::Label(&gettext("Paints"))]);
    target.connect_selected_notify({
        let edit = edit.clone();
        move |dropdown| {
            let target = if dropdown.selected() == 1 {
                HighlightTarget::Cell
            } else {
                HighlightTarget::Row
            };
            edit(&|rule| rule.target = target);
        }
    });
    let case = gtk::CheckButton::with_label(&gettext("Match case"));
    case.set_active(rule.case_sensitive);
    case.connect_toggled({
        let edit = edit.clone();
        move |check| edit(&|rule| rule.case_sensitive = check.is_active())
    });
    bottom.append(&color);
    bottom.append(&target);
    bottom.append(&case);
    inner.append(&bottom);
    card.upcast()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_value_reads_back_the_way_it_was_written() {
        for (op, text, expected) in [
            (FilterOp::Eq, "open", Some(FilterValue::Single("open".to_owned()))),
            (
                FilterOp::In,
                "a, b ,, c",
                Some(FilterValue::List(vec!["a".to_owned(), "b".to_owned(), "c".to_owned()])),
            ),
            (
                FilterOp::Between,
                "5, 10",
                Some(FilterValue::Pair("5".to_owned(), "10".to_owned())),
            ),
            (FilterOp::IsNull, "ignored", None),
        ] {
            assert_eq!(value_from(op, text), expected);
        }
        assert_eq!(value_text(&value_from(FilterOp::Between, "5, 10")), "5, 10");
        assert_eq!(value_text(&value_from(FilterOp::In, "a, b")), "a, b");
    }

    #[test]
    fn an_operator_starts_with_a_blank_value_of_its_shape() {
        assert_eq!(blank_for(FilterOp::IsNotNull), None);
        assert_eq!(blank_for(FilterOp::In), Some(FilterValue::List(Vec::new())));
        assert_eq!(
            blank_for(FilterOp::Between),
            Some(FilterValue::Pair(String::new(), String::new()))
        );
        assert_eq!(blank_for(FilterOp::Eq), Some(FilterValue::Single(String::new())));
    }
}
