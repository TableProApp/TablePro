use std::cell::RefCell;

use gtk4::glib;
use gtk4::subclass::prelude::*;
use tablepro_core::{FilterOp, FilterRule};

mod imp {
    use super::*;

    pub struct FilterRuleObject {
        pub(super) rule: RefCell<FilterRule>,
    }

    impl Default for FilterRuleObject {
        fn default() -> Self {
            Self {
                rule: RefCell::new(FilterRule {
                    column: String::new(),
                    op: FilterOp::Eq,
                    value: None,
                }),
            }
        }
    }

    #[glib::object_subclass]
    impl ObjectSubclass for FilterRuleObject {
        const NAME: &'static str = "TableProFilterRuleObject";
        type Type = super::FilterRuleObject;
    }

    impl ObjectImpl for FilterRuleObject {}
}

glib::wrapper! {
    /// One rule as the strip's list model holds it. Its row edits it in
    /// place, so Apply reads what the user typed from the model alone.
    pub struct FilterRuleObject(ObjectSubclass<imp::FilterRuleObject>);
}

impl FilterRuleObject {
    pub(super) fn new(rule: FilterRule) -> Self {
        let object: Self = glib::Object::new();
        object.imp().rule.replace(rule);
        object
    }

    pub(super) fn rule(&self) -> FilterRule {
        self.imp().rule.borrow().clone()
    }

    pub(super) fn update(&self, change: impl FnOnce(&mut FilterRule)) {
        change(&mut self.imp().rule.borrow_mut());
    }
}
