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
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use tablepro_core::dialect::SqlDialect;
use tablepro_core::{ColumnInfo, Combinator, FilterRule, FilterSet, FilterValue};

use self::filter_rule_object::FilterRuleObject;
use self::rule_operators::{FilterVocabulary, operators_for};
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

    /// Take the typed filter as a document, as an engine of documents
    /// filters, rather than as a WHERE clause.
    pub fn take_documents(&self) {
        let imp = self.imp();
        imp.raw_label.set_label(&crate::i18n::gettext("Filter"));
        imp.raw_entry
            .set_placeholder_text(Some(&crate::i18n::gettext("e.g. { qty: { $gt: 1 }, status: 'A' }")));
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
    /// operator choices come from them. A column the engine filters with
    /// no operator, such as a CQL collection, is not offered.
    pub fn set_columns(&self, columns: Vec<ColumnInfo>) {
        let imp = self.imp();
        imp.all_columns.replace(columns);
        let vocabulary = imp.vocabulary.borrow().clone();
        let filterable: Vec<ColumnInfo> = imp
            .all_columns
            .borrow()
            .iter()
            .filter(|column| !vocabulary.operators(column).is_empty())
            .cloned()
            .collect();
        imp.columns.replace(Rc::from(filterable));
        let rules = self.rules();
        let items: Vec<FilterRuleObject> = rules.iter::<FilterRuleObject>().filter_map(Result::ok).collect();
        rules.splice(0, rules.n_items(), &items);
        self.reflect_clauses();
    }

    /// Offer what the connection's engine evaluates: its operators, and
    /// a choice between all and any only where it can match any.
    pub fn set_dialect(&self, dialect: Option<Arc<dyn SqlDialect>>) {
        let imp = self.imp();
        imp.vocabulary.replace(FilterVocabulary::of(dialect));
        let columns = imp.all_columns.borrow().clone();
        self.set_columns(columns);
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
        let any = imp.vocabulary.borrow().matches_any();
        FilterSet {
            combinator: match imp.combinator_dropdown.selected() {
                1 if any => Combinator::Or,
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

    /// A rule on the first column, by its first operator.
    fn add_rule(&self) {
        let imp = self.imp();
        let first = imp.columns.borrow().first().cloned();
        let entry = first
            .as_ref()
            .and_then(|column| operators_for(column, &imp.vocabulary.borrow()).into_iter().next());
        self.rules().append(&FilterRuleObject::new(FilterRule {
            column: first.map(|column| column.name).unwrap_or_default(),
            op: entry.as_ref().map_or(tablepro_core::FilterOp::Eq, |entry| entry.op),
            value: entry.map_or_else(
                || Some(FilterValue::Single(String::new())),
                |entry| entry.shape.empty_value(),
            ),
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
        let imp = self.imp();
        let row = FilterRuleRow::new(rule, imp.columns.borrow().clone(), imp.vocabulary.borrow().clone());
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
        let any = imp.vocabulary.borrow().matches_any();
        imp.match_revealer
            .set_reveal_child(any && (rules >= 2 || (rules >= 1 && sql)));
        imp.rule_list.set_visible(rules > 0);
    }
}
