use std::cell::{Cell, OnceCell};
use std::rc::Rc;
use std::sync::OnceLock;

use glib::subclass::Signal;
use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::ColumnInfo;

use super::filter_rule_object::FilterRuleObject;
use super::rule_operators::{ValueShape, operators_for, placeholder_column};
use super::rule_value_editor::value_editor;

mod imp {
    use libadwaita::subclass::prelude::*;

    use super::*;

    #[derive(Default, gtk::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/filter-rule-row.ui")]
    pub struct FilterRuleRow {
        #[template_child]
        pub column_dropdown: TemplateChild<gtk::DropDown>,
        #[template_child]
        pub operator_dropdown: TemplateChild<gtk::DropDown>,
        #[template_child]
        pub value_slot: TemplateChild<adw::Bin>,
        #[template_child]
        pub remove_button: TemplateChild<gtk::Button>,
        pub(super) rule: OnceCell<FilterRuleObject>,
        /// The strip's filterable columns when the row was built.
        pub(super) columns: OnceCell<Rc<[ColumnInfo]>>,
        /// Set while the row fills its own dropdowns, whose `selected`
        /// notifications are then not the user's choice.
        pub(super) syncing: Cell<bool>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for FilterRuleRow {
        const NAME: &'static str = "TableProFilterRuleRow";
        type Type = super::FilterRuleRow;
        type ParentType = adw::ActionRow;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
            klass.install_action("rule.remove", None, |row, _, _| {
                row.emit_by_name::<()>("remove", &[]);
            });
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for FilterRuleRow {
        fn signals() -> &'static [Signal] {
            static SIGNALS: OnceLock<Vec<Signal>> = OnceLock::new();
            SIGNALS.get_or_init(|| vec![Signal::builder("remove").build()])
        }

        fn constructed(&self) {
            self.parent_constructed();
            let remove = self.remove_button.get();
            remove.set_icon_name(crate::ui::icons::USER_TRASH);
            crate::ui::a11y::describe_icon_button(&remove, &crate::i18n::gettext("Remove Rule"), None);
            // The row has no title, its controls being the rule, and
            // libadwaita names a row by its title label alone.
            let row = self.obj();
            let row = row.upcast_ref::<gtk::Widget>();
            row.reset_relation(gtk::AccessibleRelation::LabelledBy);
            row.update_property(&[gtk::accessible::Property::Label(&crate::i18n::gettext("Filter Rule"))]);
        }
    }

    impl WidgetImpl for FilterRuleRow {}
    impl ListBoxRowImpl for FilterRuleRow {}
    impl PreferencesRowImpl for FilterRuleRow {}
    impl ActionRowImpl for FilterRuleRow {}
}

glib::wrapper! {
    /// One rule of the filter strip: its column, its operator and the
    /// value it compares against, each written into the rule as the
    /// user picks it.
    pub struct FilterRuleRow(ObjectSubclass<imp::FilterRuleRow>)
        @extends adw::ActionRow, adw::PreferencesRow, gtk::ListBoxRow, gtk::Widget,
        @implements gtk::Accessible, gtk::Actionable, gtk::Buildable, gtk::ConstraintTarget;
}

impl Default for FilterRuleRow {
    fn default() -> Self {
        glib::Object::new()
    }
}

impl FilterRuleRow {
    pub(super) fn new(rule: &FilterRuleObject, columns: Rc<[ColumnInfo]>) -> Self {
        let row = Self::default();
        let imp = row.imp();
        let _ = imp.rule.set(rule.clone());
        let _ = imp.columns.set(columns);
        row.show_rule();
        row.connect_choices();
        row
    }

    /// The rule the row edits.
    pub(super) fn rule(&self) -> Option<FilterRuleObject> {
        self.imp().rule.get().cloned()
    }

    /// The user asked to drop the row's rule.
    pub(super) fn connect_remove<F: Fn(&Self) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure("remove", false, glib::closure_local!(move |row: &Self| f(row)))
    }

    fn columns(&self) -> &[ColumnInfo] {
        self.imp().columns.get().map(|columns| &columns[..]).unwrap_or_default()
    }

    fn rule_column_name(&self) -> String {
        self.rule().map(|rule| rule.rule().column).unwrap_or_default()
    }

    /// Where the rule's column is among the choices. A rule whose column
    /// is not in the table shows the first one.
    fn shown_index(&self) -> usize {
        let name = self.rule_column_name();
        self.columns()
            .iter()
            .position(|column| column.name == name)
            .unwrap_or(0)
    }

    /// The column the dropdown shows for the rule, or, with no columns
    /// loaded yet, one under the rule's own name.
    fn shown_column(&self) -> ColumnInfo {
        self.columns()
            .get(self.shown_index())
            .cloned()
            .unwrap_or_else(|| placeholder_column(&self.rule_column_name()))
    }

    fn show_rule(&self) {
        let imp = self.imp();
        let names: Vec<&str> = self.columns().iter().map(|column| column.name.as_str()).collect();
        imp.syncing.set(true);
        imp.column_dropdown.set_model(Some(&gtk::StringList::new(&names)));
        imp.column_dropdown
            .set_selected(u32::try_from(self.shown_index()).unwrap_or_default());
        imp.syncing.set(false);
        self.show_operators();
    }

    fn show_operators(&self) {
        let imp = self.imp();
        let Some(rule) = self.rule() else {
            return;
        };
        let column = self.shown_column();
        let ops = operators_for(&column);
        let labels: Vec<&str> = ops.iter().map(|entry| entry.label).collect();
        let op = rule.rule().op;
        let picked = ops.iter().position(|entry| entry.op == op).unwrap_or(0);
        imp.syncing.set(true);
        imp.operator_dropdown.set_model(Some(&gtk::StringList::new(&labels)));
        imp.operator_dropdown
            .set_selected(u32::try_from(picked).unwrap_or_default());
        imp.syncing.set(false);
        let shape = ops
            .iter()
            .find(|entry| entry.op == op)
            .map_or(ValueShape::Single, |entry| entry.shape);
        self.show_value_editor(&rule, &column, shape);
    }

    fn show_value_editor(&self, rule: &FilterRuleObject, column: &ColumnInfo, shape: ValueShape) {
        let slot = self.imp().value_slot.get();
        let editor = value_editor(rule, column, shape);
        slot.set_visible(editor.is_some());
        slot.set_child(editor.as_ref());
    }

    fn connect_choices(&self) {
        let imp = self.imp();
        let row = self.downgrade();
        imp.column_dropdown.connect_selected_notify(move |dropdown| {
            if let Some(row) = row.upgrade() {
                row.on_column_picked(dropdown.selected());
            }
        });
        let row = self.downgrade();
        imp.operator_dropdown.connect_selected_notify(move |dropdown| {
            if let Some(row) = row.upgrade() {
                row.on_operator_picked(dropdown.selected());
            }
        });
    }

    fn on_column_picked(&self, index: u32) {
        let Some(rule) = self.rule().filter(|_| !self.imp().syncing.get()) else {
            return;
        };
        let Some(column) = usize::try_from(index).ok().and_then(|index| self.columns().get(index)) else {
            return;
        };
        let first = operators_for(column).into_iter().next();
        rule.update(|rule| {
            rule.column = column.name.clone();
            // An operator the new type lacks would build SQL the driver
            // rejects at fetch time.
            if let Some(first) = first {
                rule.op = first.op;
                rule.value = first.shape.empty_value();
            }
        });
        self.show_operators();
    }

    fn on_operator_picked(&self, index: u32) {
        let Some(rule) = self.rule().filter(|_| !self.imp().syncing.get()) else {
            return;
        };
        let column = self.shown_column();
        let ops = operators_for(&column);
        let Some(entry) = usize::try_from(index).ok().and_then(|index| ops.get(index)) else {
            return;
        };
        rule.update(|rule| {
            rule.op = entry.op;
            rule.value = entry.shape.empty_value();
        });
        self.show_value_editor(&rule, &column, entry.shape);
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::{FilterOp, FilterRule, FilterValue};

    use super::*;
    use crate::test_support::SignalLog;

    fn row_for(column: &str, columns: &[&str]) -> (FilterRuleRow, FilterRuleObject) {
        crate::register_test_resources();
        let rule = FilterRuleObject::new(FilterRule {
            column: column.to_owned(),
            op: FilterOp::Eq,
            value: Some(FilterValue::Single("1".to_owned())),
        });
        let columns: Rc<[ColumnInfo]> = columns.iter().map(|name| placeholder_column(name)).collect();
        (FilterRuleRow::new(&rule, columns), rule)
    }

    #[gtk4::test]
    fn a_rule_on_a_dropped_column_shows_the_first_one_and_keeps_its_name() {
        let (row, rule) = row_for("gone", &["a", "b"]);

        assert_eq!(row.imp().column_dropdown.selected(), 0);
        assert_eq!(rule.rule().column, "gone");
    }

    #[gtk4::test]
    fn without_columns_a_rule_still_offers_its_operators() {
        let (row, _) = row_for("name", &[]);
        let operators = row.imp().operator_dropdown.model().map_or(0, |model| model.n_items());

        assert_eq!(row.imp().column_dropdown.model().map(|model| model.n_items()), Some(0));
        assert!(operators > 0, "a rule with no columns loaded offers no operator");
    }

    #[gtk4::test]
    fn remove_asks_the_strip_to_drop_the_rule() {
        let (row, _) = row_for("a", &["a"]);
        let removals = SignalLog::connect(&row, "remove", |_| ());

        row.activate_action("rule.remove", None)
            .expect("the row's remove action");

        assert_eq!(removals.count(), 1);
        assert_eq!(row.imp().remove_button.action_name().as_deref(), Some("rule.remove"));
    }
}
