use std::cell::{Cell, OnceCell};

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct ReversedList {
        pub(super) model: OnceCell<gio::ListModel>,
        pub(super) reversed: Cell<bool>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for ReversedList {
        const NAME: &'static str = "TableProReversedList";
        type Type = super::ReversedList;
        type Interfaces = (gio::ListModel,);
    }

    impl ObjectImpl for ReversedList {}

    impl ListModelImpl for ReversedList {
        fn item_type(&self) -> glib::Type {
            self.model
                .get()
                .map_or_else(glib::Object::static_type, |model| model.item_type())
        }

        fn n_items(&self) -> u32 {
            self.model.get().map_or(0, |model| model.n_items())
        }

        fn item(&self, position: u32) -> Option<glib::Object> {
            let model = self.model.get()?;
            let n_items = model.n_items();
            if position >= n_items {
                return None;
            }
            model.item(if self.reversed.get() {
                n_items - 1 - position
            } else {
                position
            })
        }
    }
}

glib::wrapper! {
    /// The rows of the model under it, last first while reversed, so a
    /// sort model keyed for ascending order serves a descending header
    /// too. GtkColumnViewSorter offers no keys, and a sort through it
    /// collates both rows again on every comparison.
    pub struct ReversedList(ObjectSubclass<imp::ReversedList>)
        @implements gio::ListModel;
}

impl ReversedList {
    pub fn new(model: &impl IsA<gio::ListModel>) -> Self {
        let list: Self = glib::Object::new();
        let model = model.upcast_ref::<gio::ListModel>();
        let _ = list.imp().model.set(model.clone());
        let weak = list.downgrade();
        model.connect_items_changed(move |model, position, removed, added| {
            if let Some(list) = weak.upgrade() {
                list.model_changed(model.n_items(), position, removed, added);
            }
        });
        list
    }

    /// Show the rows last first, or in the model's order.
    pub fn set_reversed(&self, reversed: bool) {
        if self.imp().reversed.replace(reversed) == reversed {
            return;
        }
        let n_items = self.n_items();
        if n_items > 0 {
            self.items_changed(0, n_items, n_items);
        }
    }

    fn model_changed(&self, n_items: u32, position: u32, removed: u32, added: u32) {
        if !self.imp().reversed.get() {
            self.items_changed(position, removed, added);
            return;
        }
        let before = n_items - added + removed;
        self.items_changed(before - position - removed, removed, added);
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;

    use gtk4 as gtk;

    use super::*;

    fn shown(list: &ReversedList) -> Vec<String> {
        (0..list.n_items())
            .filter_map(|at| list.item(at).and_downcast::<gtk::StringObject>())
            .map(|object| object.string().to_string())
            .collect()
    }

    fn changes(list: &ReversedList) -> Rc<RefCell<Vec<(u32, u32, u32)>>> {
        let seen = Rc::new(RefCell::new(Vec::new()));
        let log = seen.clone();
        list.connect_items_changed(move |_, position, removed, added| {
            log.borrow_mut().push((position, removed, added));
        });
        seen
    }

    #[gtk4::test]
    fn a_change_under_a_reversed_list_lands_where_the_list_shows_it() {
        let rows = gtk::StringList::new(&["a", "b", "c", "d"]);
        let list = ReversedList::new(&rows);
        list.set_reversed(true);
        let seen = changes(&list);

        rows.splice(1, 2, &["x"]);
        rows.append("e");

        assert_eq!(shown(&list), ["e", "d", "x", "a"]);
        assert_eq!(*seen.borrow(), [(1, 2, 1), (0, 0, 1)]);
    }

    #[gtk4::test]
    fn reversing_replaces_the_rows_once_and_again_changes_nothing() {
        let rows = gtk::StringList::new(&["a", "b", "c"]);
        let list = ReversedList::new(&rows);
        let seen = changes(&list);

        list.set_reversed(true);
        list.set_reversed(true);

        assert_eq!(shown(&list), ["c", "b", "a"]);
        assert_eq!(*seen.borrow(), [(0, 3, 3)]);
        assert_eq!(list.item(3), None, "past the end");
    }
}
