use tablepro_core::column::{ColumnKind, IntegerKind, IntegerWidth, TextLength};

use super::rule_operators::placeholder_column;
use super::*;
use crate::application::ShortcutOwner;
use crate::test_support::{
    SignalLog, assert_labelled, descendants, drain_main_context, first_descendant_of_type, tooltips_with_keys,
    unlabelled_icon_buttons,
};

fn rule(column: &str) -> FilterRule {
    FilterRule {
        column: column.to_owned(),
        op: FilterOp::Eq,
        value: Some(FilterValue::Single("1".to_owned())),
    }
}

fn new_strip(columns: Vec<ColumnInfo>, initial: &FilterSet) -> FilterStrip {
    crate::register_test_resources();
    FilterStrip::new(columns, initial)
}

fn strip_with(rules: Vec<FilterRule>) -> FilterStrip {
    new_strip(
        vec![placeholder_column("a"), placeholder_column("b")],
        &FilterSet {
            rules,
            ..FilterSet::default()
        },
    )
}

/// A strip in a window. Its buttons reach its actions only once it has
/// a root, as the browse tab's window gives it.
struct Hosted {
    window: gtk::Window,
    strip: FilterStrip,
}

impl Hosted {
    fn new(strip: FilterStrip) -> Self {
        let window = gtk::Window::new();
        window.set_child(Some(&strip));
        Self { window, strip }
    }
}

impl std::ops::Deref for Hosted {
    type Target = FilterStrip;

    fn deref(&self) -> &FilterStrip {
        &self.strip
    }
}

impl Drop for Hosted {
    fn drop(&mut self) {
        self.window.set_child(None::<&gtk::Widget>);
        self.window.destroy();
    }
}

fn integer(name: &str) -> ColumnInfo {
    let mut column = placeholder_column(name);
    column.column_type.kind = ColumnKind::Integer(IntegerKind {
        width: IntegerWidth::W32,
        signed: true,
    });
    column
}

fn blob(name: &str) -> ColumnInfo {
    let mut column = placeholder_column(name);
    column.column_type.kind = ColumnKind::Bytes {
        length: TextLength::Unbounded,
    };
    column
}

fn rows(strip: &FilterStrip) -> Vec<FilterRuleRow> {
    descendants(&strip.imp().rule_list.get())
        .into_iter()
        .filter_map(|widget| widget.downcast::<FilterRuleRow>().ok())
        .collect()
}

fn applied(strip: &FilterStrip) -> SignalLog<FilterSet> {
    SignalLog::connect(strip, "applied", |values| {
        values[1]
            .get::<glib::BoxedAnyObject>()
            .expect("the applied filter")
            .borrow::<FilterSet>()
            .clone()
    })
}

fn column_choices(row: &FilterRuleRow) -> Vec<String> {
    let model = row.imp().column_dropdown.model().expect("the column choices");
    (0..model.n_items())
        .filter_map(|position| model.item(position).and_downcast::<gtk::StringObject>())
        .map(|choice| choice.string().to_string())
        .collect()
}

#[gtk4::test]
fn escape_closes_the_strip_through_the_table() {
    use crate::test_support::shortcut_keys::{keystroke, owner_controller, shortcuts, trigger_keys};
    let strip = strip_with(vec![rule("a")]);
    strip.set_revealed(true);
    let escape = shortcuts(&owner_controller(&strip, ShortcutOwner::FilterStrip).expect("the strip's keys"))
        .into_iter()
        .find(|shortcut| {
            shortcut
                .trigger()
                .is_some_and(|trigger| trigger_keys(&trigger).contains(&keystroke("Escape")))
        })
        .and_then(|shortcut| shortcut.action())
        .expect("Escape is bound");

    assert!(escape.activate(gtk::ShortcutActionFlags::empty(), &strip, None));

    assert!(!strip.revealed());
    assert!(!strip.imp().revealer.reveals_child());
}

#[gtk4::test]
fn toggle_opens_onto_the_sql_field_and_closes_again() {
    let strip = strip_with(Vec::new());

    strip.toggle();
    assert!(strip.revealed());
    assert!(strip.imp().revealer.reveals_child());

    strip.toggle();
    assert!(!strip.imp().revealer.reveals_child());
}

/// Closing the strip gives the focus back to where it came from, before
/// GTK moves it to the window's first control.
#[gtk4::test]
fn close_gives_the_focus_back() {
    let strip = strip_with(vec![rule("a")]);
    let outside = gtk::Button::with_label("Rows");
    let column = gtk::Box::new(gtk::Orientation::Vertical, 0);
    column.append(&strip);
    column.append(&outside);
    let window = crate::test_support::OwnedWindow::presented(gtk::Window::builder().child(&column).build());
    let focus = || gtk::prelude::GtkWindowExt::focus(&*window);
    assert!(outside.grab_focus());

    strip.toggle();
    assert!(strip.revealed());
    assert!(crate::ui::a11y::holds_focus(&strip));

    strip.activate_action("filter.close", None).expect("filter.close");

    assert!(!strip.revealed());
    assert_eq!(focus().as_ref(), Some(outside.upcast_ref()));
}

#[gtk4::test]
fn strip_freed_after_drop() {
    let strip = strip_with(vec![rule("a"), rule("b")]);
    let rules = first_descendant_of_type::<gtk::ListBox>(&strip)
        .expect("the rule list")
        .downgrade();
    let row = rows(&strip).first().expect("a rule row").downgrade();
    let freed = strip.downgrade();

    drop(strip);
    drain_main_context();

    assert!(rules.upgrade().is_none(), "the rule list outlived the strip");
    assert!(row.upgrade().is_none(), "a rule row outlived the strip");
    assert!(freed.upgrade().is_none(), "the strip outlived its owner");
}

#[gtk4::test]
fn a_between_rule_frees_its_entries() {
    let strip = new_strip(
        vec![integer("amount")],
        &FilterSet {
            rules: vec![FilterRule {
                column: "amount".to_owned(),
                op: FilterOp::Between,
                value: Some(FilterValue::Pair("1".to_owned(), "2".to_owned())),
            }],
            ..FilterSet::default()
        },
    );
    let entry = |text: &str| {
        descendants(&strip)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::Entry>().ok())
            .find(|entry| entry.text() == text)
    };
    let from = entry("1").expect("the From entry");
    let to = entry("2").expect("the To entry");
    from.set_text("5");
    assert_eq!(
        strip.filter().rules[0].value,
        Some(FilterValue::Pair("5".to_owned(), "2".to_owned()))
    );
    to.set_text("9");
    assert_eq!(
        strip.filter().rules[0].value,
        Some(FilterValue::Pair("5".to_owned(), "9".to_owned()))
    );
    let freed = [from.downgrade(), to.downgrade()];

    drop((strip, from, to));
    drain_main_context();

    let alive = freed.iter().filter(|entry| entry.upgrade().is_some()).count();
    assert_eq!(alive, 0, "the From and To entries outlived the strip");
}

#[gtk4::test]
fn icon_buttons_are_labelled_without_accelerator_hints() {
    let strip = strip_with(vec![rule("a")]);
    strip.set_revealed(true);
    let remove = descendants(&strip)
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
        .find(|button| {
            button
                .icon_name()
                .is_some_and(|icon| icon.as_str() == crate::ui::icons::USER_TRASH)
        })
        .expect("the rule's Remove Rule button");

    assert!(gtk::test_accessible_has_property(
        &remove,
        gtk::AccessibleProperty::Label
    ));
    assert!(gtk::test_accessible_has_property(
        &strip.imp().close_button.get(),
        gtk::AccessibleProperty::KeyShortcuts
    ));
    assert_eq!(unlabelled_icon_buttons(&strip), Vec::<String>::new());
    assert_eq!(tooltips_with_keys(&strip), Vec::<String>::new());
}

/// Placeholders go once text is typed, so each field, and the row that
/// holds a rule, has a name of its own.
#[gtk4::test]
fn every_field_of_the_strip_is_named() {
    let rule = |column: &str, op: FilterOp, value: Option<FilterValue>| FilterRule {
        column: column.to_owned(),
        op,
        value,
    };
    let strip = new_strip(
        vec![integer("amount"), placeholder_column("name")],
        &FilterSet {
            rules: vec![
                rule("name", FilterOp::Eq, Some(FilterValue::Single("x".to_owned()))),
                rule(
                    "amount",
                    FilterOp::Between,
                    Some(FilterValue::Pair("1".to_owned(), "2".to_owned())),
                ),
                rule("name", FilterOp::In, Some(FilterValue::List(vec!["a".to_owned()]))),
            ],
            ..FilterSet::default()
        },
    );
    strip.set_revealed(true);
    let fields: Vec<gtk::Widget> = descendants(&strip)
        .into_iter()
        .filter(|widget| widget.is::<gtk::Entry>() || widget.is::<gtk::DropDown>() || widget.is::<FilterRuleRow>())
        .collect();
    assert_eq!(fields.len(), 1 + 1 + 3 * 3 + 1 + 2 + 1, "the strip's fields");

    for field in fields {
        assert_eq!(assert_labelled(&field), Ok(()), "{}", field.type_().name());
    }
}

#[gtk4::test]
fn an_applied_filter_rebuilds_the_rule_list() {
    let strip = strip_with(vec![rule("a"), rule("b")]);
    assert_eq!(rows(&strip).len(), 2);

    strip.set_filter(&FilterSet {
        rules: vec![rule("b")],
        ..FilterSet::default()
    });

    assert_eq!(rows(&strip).len(), 1);
}

#[gtk4::test]
fn a_saved_filter_opens_the_rule_editor_and_an_empty_one_does_not() {
    assert!(strip_with(vec![rule("a")]).imp().rules_expander.is_expanded());
    assert!(!strip_with(Vec::new()).imp().rules_expander.is_expanded());
}

#[gtk4::test]
fn add_rule_appends_a_row_for_the_first_filterable_column() {
    let strip = Hosted::new(new_strip(
        vec![blob("payload"), placeholder_column("name")],
        &FilterSet::default(),
    ));
    assert!(!strip.imp().rule_list.get_visible(), "an empty rule list is shown");
    // A collapsed expander holds its content out of the window, so the
    // button is reached the way the user reaches it.
    strip.imp().rules_expander.set_expanded(true);

    strip.imp().add_rule_button.emit_clicked();

    assert_eq!(rows(&strip).len(), 1);
    assert!(strip.imp().rule_list.get_visible());
    assert_eq!(
        strip.filter().rules,
        [FilterRule {
            column: "name".to_owned(),
            op: FilterOp::Eq,
            value: Some(FilterValue::Single(String::new())),
        }]
    );
}

#[gtk4::test]
fn apply_emits_the_rules_and_sql_as_edited() {
    let strip = Hosted::new(strip_with(vec![rule("a"), rule("b")]));
    strip.set_revealed(true);
    let applied = applied(&strip);
    let value = descendants(&rows(&strip)[1])
        .into_iter()
        .find_map(|widget| widget.downcast::<gtk::Entry>().ok())
        .expect("the second rule's value");
    value.set_text("2");
    strip.imp().combinator_dropdown.set_selected(1);
    strip.imp().raw_entry.set_text("id > 3");

    strip.imp().apply_button.emit_clicked();

    let mut second = rule("b");
    second.value = Some(FilterValue::Single("2".to_owned()));
    assert_eq!(
        applied.take(),
        [FilterSet {
            combinator: Combinator::Or,
            rules: vec![rule("a"), second],
            extra_sql: Some("id > 3".to_owned()),
        }]
    );
    assert!(!strip.revealed(), "Apply left the strip open");
}

#[gtk4::test]
fn enter_in_the_sql_field_applies() {
    let strip = strip_with(Vec::new());
    let applied = applied(&strip);
    strip.imp().raw_entry.set_text("  ");

    strip.imp().raw_entry.emit_activate();

    assert_eq!(applied.take(), [FilterSet::default()], "blank SQL is not a predicate");
}

#[gtk4::test]
fn remove_rule_drops_it_from_the_next_apply() {
    let strip = Hosted::new(strip_with(vec![rule("a"), rule("b")]));
    let applied = applied(&strip);

    rows(&strip)[0].imp().remove_button.emit_clicked();
    strip.imp().apply_button.emit_clicked();

    assert_eq!(rows(&strip).len(), 1);
    assert_eq!(applied.take()[0].rules, [rule("b")]);
}

#[gtk4::test]
fn clear_all_reports_an_empty_filter_and_closes() {
    let strip = Hosted::new(strip_with(vec![rule("a")]));
    strip.set_revealed(true);
    let applied = applied(&strip);

    strip.imp().clear_button.emit_clicked();

    assert_eq!(applied.take(), [FilterSet::default()]);
    assert!(!strip.revealed());
}

#[gtk4::test]
fn set_columns_rebuilds_the_column_choices() {
    let strip = strip_with(vec![rule("a")]);
    assert_eq!(column_choices(&rows(&strip)[0]), ["a", "b"]);

    strip.set_columns(vec![placeholder_column("a"), blob("payload"), integer("total")]);

    let [row] = rows(&strip).try_into().expect("one rule row");
    assert_eq!(column_choices(&row), ["a", "total"]);
    assert_eq!(strip.filter().rules, [rule("a")], "new columns changed the rule");
}

#[gtk4::test]
fn the_match_row_shows_once_two_clauses_meet() {
    let strip = Hosted::new(strip_with(vec![rule("a")]));
    let shown = || strip.imp().match_revealer.reveals_child();
    assert!(!shown(), "one rule has nothing to combine with");

    strip.imp().raw_entry.set_text("id > 3");
    assert!(shown(), "a rule and SQL are two clauses");

    strip.imp().raw_entry.set_text("");
    strip.imp().add_rule_button.emit_clicked();
    assert!(shown(), "two rules are two clauses");
}

#[gtk4::test]
fn set_filter_shows_its_combinator_and_sql() {
    let strip = strip_with(Vec::new());
    strip.imp().combinator_dropdown.set_selected(1);

    strip.set_filter(&FilterSet {
        combinator: Combinator::And,
        rules: vec![rule("a")],
        extra_sql: Some("id > 3".to_owned()),
    });

    assert_eq!(strip.imp().combinator_dropdown.selected(), 0);
    assert_eq!(strip.imp().raw_entry.text(), "id > 3");
    assert_eq!(strip.filter().combinator, Combinator::And);
}

#[gtk4::test]
fn picking_a_column_resets_the_operator_to_one_it_allows() {
    let strip = new_strip(
        vec![placeholder_column("name"), integer("amount")],
        &FilterSet {
            rules: vec![FilterRule {
                column: "name".to_owned(),
                op: FilterOp::IsNull,
                value: None,
            }],
            ..FilterSet::default()
        },
    );
    let row = rows(&strip)[0].clone();
    assert!(!row.imp().value_slot.get_visible(), "a null test shows a value field");

    row.imp().column_dropdown.set_selected(1);

    let picked = strip.filter().rules[0].clone();
    let first = tablepro_core::operators_for(&integer("amount").column_type.kind)[0];
    assert_eq!(picked.column, "amount");
    assert_eq!(picked.op, first);
    assert_eq!(row.imp().operator_dropdown.selected(), 0);
    assert!(row.imp().value_slot.get_visible());
}

#[gtk4::test]
fn picking_an_operator_resets_the_value_to_its_shape() {
    let strip = new_strip(
        vec![integer("amount")],
        &FilterSet {
            rules: vec![FilterRule {
                column: "amount".to_owned(),
                op: FilterOp::Eq,
                value: Some(FilterValue::Single("7".to_owned())),
            }],
            ..FilterSet::default()
        },
    );
    let row = rows(&strip)[0].clone();
    let between = rule_operators::operators_for(&integer("amount"))
        .iter()
        .position(|entry| entry.op == FilterOp::Between)
        .expect("an integer takes between");

    row.imp()
        .operator_dropdown
        .set_selected(u32::try_from(between).expect("a small index"));

    assert_eq!(
        strip.filter().rules[0].value,
        Some(FilterValue::Pair(String::new(), String::new()))
    );
    let entries = descendants(&row.imp().value_slot.get())
        .into_iter()
        .filter(|widget| widget.is::<gtk::Entry>())
        .count();
    assert_eq!(entries, 2, "between shows From and To");
}
