//! The inline filter strip: a WHERE clause editor that slides in above
//! the browse tab's grid, from the Filter button or Ctrl+F.
//!
//! Inline rather than a dialog: the user is filtering rows they can
//! see, so the strip stays open while they tune a rule, applies on
//! demand, and closes with Escape or Close, as GtkSearchBar does.

mod filter_rule_object;
mod imp;
mod rule_operators;
mod rule_row;
mod rule_value_editor;
#[cfg(test)]
mod tests;

use std::rc::Rc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use tablepro_core::{ColumnInfo, Combinator, FilterOp, FilterRule, FilterSet, FilterValue};

use self::filter_rule_object::FilterRuleObject;
pub(super) use self::rule_row::FilterRuleRow;

glib::wrapper! {
    /// The browse tab's filter editor. The rules live in a list model
    /// the rows are built from, and Apply reports the filter through
    /// `applied`.
    pub struct FilterStrip(ObjectSubclass<imp::FilterStrip>)
        @extends adw::Bin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl FilterStrip {
    /// A strip showing `initial`, with its rule editor open when the
    /// saved filter has rules in it.
    pub fn new(columns: Vec<ColumnInfo>, initial: &FilterSet) -> Self {
        let strip: Self = glib::Object::new();
        strip.set_columns(columns);
        strip.set_filter(initial);
        strip.imp().rules_expander.set_expanded(!initial.rules.is_empty());
        strip
    }

    /// Slide in, or out, as the Filter button does.
    pub fn toggle(&self) {
        match self.revealed() {
            true => self.close(),
            false => self.open(),
        }
    }

    /// Slide in with the cursor in the SQL field, the strip's main input,
    /// or, already in, take the focus there, as Ctrl+F does in a search
    /// bar that shows.
    pub fn open(&self) {
        if crate::ui::a11y::holds_focus(self) {
            return;
        }
        let focus = self.root().and_then(|root| root.focus());
        self.imp().focus_before.set(focus.as_ref());
        self.set_revealed(true);
        self.imp().raw_entry.grab_focus();
    }

    /// Slide out. The focus inside goes back where it came from, before
    /// GTK moves it to the window's first control.
    fn close(&self) {
        if crate::ui::a11y::holds_focus(self)
            && let Some(before) = self.imp().focus_before.upgrade()
            && before.root() == self.root()
        {
            before.grab_focus();
        }
        self.set_revealed(false);
    }

    /// Rebuild the rows against new columns: each row's column and
    /// operator choices come from them.
    pub fn set_columns(&self, columns: Vec<ColumnInfo>) {
        self.imp().columns.replace(Rc::from(columns));
        let rules = self.rules();
        let items: Vec<FilterRuleObject> = rules.iter::<FilterRuleObject>().filter_map(Result::ok).collect();
        rules.splice(0, rules.n_items(), &items);
    }

    /// Show the filter in effect, which may have been applied from
    /// elsewhere, such as a saved filter restored when the tab opens.
    pub fn set_filter(&self, set: &FilterSet) {
        let imp = self.imp();
        imp.combinator_dropdown.set_selected(match set.combinator {
            Combinator::And => 0,
            Combinator::Or => 1,
        });
        imp.raw_entry.set_text(set.extra_sql.as_deref().unwrap_or_default());
        let items: Vec<FilterRuleObject> = set.rules.iter().cloned().map(FilterRuleObject::new).collect();
        let rules = self.rules();
        rules.splice(0, rules.n_items(), &items);
    }

    /// The filter as the strip shows it now.
    pub fn filter(&self) -> FilterSet {
        let imp = self.imp();
        let text = imp.raw_entry.text();
        FilterSet {
            combinator: match imp.combinator_dropdown.selected() {
                1 => Combinator::Or,
                _ => Combinator::And,
            },
            rules: self
                .rules()
                .iter::<FilterRuleObject>()
                .filter_map(Result::ok)
                .map(|rule| rule.rule())
                .collect(),
            extra_sql: (!text.trim().is_empty()).then(|| text.to_string()),
        }
    }

    /// The user applied a filter, or cleared it.
    pub fn connect_applied<F: Fn(&Self, FilterSet) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "applied",
            false,
            glib::closure_local!(move |strip: &Self, payload: glib::BoxedAnyObject| {
                f(strip, payload.borrow::<FilterSet>().clone());
            }),
        )
    }

    fn rules(&self) -> gio::ListStore {
        self.imp()
            .rules
            .get_or_init(gio::ListStore::new::<FilterRuleObject>)
            .clone()
    }

    fn apply(&self) {
        self.emit_applied(self.filter());
    }

    /// Clear reports an empty filter and closes. The strip itself
    /// empties only when the browse tab applies it, through `set_filter`.
    fn clear(&self) {
        self.emit_applied(FilterSet::default());
    }

    fn emit_applied(&self, set: FilterSet) {
        self.emit_by_name::<()>("applied", &[&glib::BoxedAnyObject::new(set)]);
        self.close();
    }

    fn add_rule(&self) {
        let column = self
            .imp()
            .columns
            .borrow()
            .first()
            .map(|column| column.name.clone())
            .unwrap_or_default();
        self.rules().append(&FilterRuleObject::new(FilterRule {
            column,
            op: FilterOp::Eq,
            value: Some(FilterValue::Single(String::new())),
        }));
    }

    fn remove_rule(&self, rule: &FilterRuleObject) {
        let rules = self.rules();
        if let Some(position) = rules.find(rule) {
            rules.remove(position);
        }
    }

    fn connect_parts(&self) {
        let imp = self.imp();
        let rules = self.rules();
        let strip = self.downgrade();
        imp.rule_list.bind_model(Some(&rules), move |item| {
            let row = strip
                .upgrade()
                .zip(item.downcast_ref::<FilterRuleObject>())
                .map(|(strip, rule)| strip.row_for(rule));
            row.map_or_else(|| gtk::ListBoxRow::new().upcast(), Cast::upcast)
        });
        let strip = self.downgrade();
        rules.connect_items_changed(move |_, _, _, _| {
            if let Some(strip) = strip.upgrade() {
                strip.reflect_clauses();
            }
        });

        let strip = self.downgrade();
        imp.raw_entry.connect_changed(move |_| {
            if let Some(strip) = strip.upgrade() {
                strip.reflect_clauses();
            }
        });
        let strip = self.downgrade();
        imp.raw_entry.connect_activate(move |_| {
            if let Some(strip) = strip.upgrade() {
                strip.apply();
            }
        });
        self.reflect_clauses();
    }

    fn row_for(&self, rule: &FilterRuleObject) -> FilterRuleRow {
        let row = FilterRuleRow::new(rule, self.imp().columns.borrow().clone());
        let strip = self.downgrade();
        row.connect_remove(move |row| {
            if let (Some(strip), Some(rule)) = (strip.upgrade(), row.rule()) {
                strip.remove_rule(&rule);
            }
        });
        row
    }

    /// All or any means something only once two clauses meet: two rules,
    /// or a rule and the SQL. An empty rule list is hidden, so the strip
    /// reads as ready for input rather than already filled.
    fn reflect_clauses(&self) {
        let imp = self.imp();
        let rules = self.rules().n_items();
        let sql = !imp.raw_entry.text().trim().is_empty();
        imp.match_revealer.set_reveal_child(rules >= 2 || (rules >= 1 && sql));
        imp.rule_list.set_visible(rules > 0);
    }
}
