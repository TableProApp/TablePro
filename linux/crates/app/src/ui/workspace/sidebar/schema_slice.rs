use std::cell::{Cell, RefCell};

use gtk4::gio;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;

use super::sidebar_list::SidebarList;
use super::sidebar_object::SidebarObject;

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct SchemaSlice {
        pub(super) list: RefCell<Option<SidebarList>>,
        pub(super) start: Cell<u32>,
        pub(super) end: Cell<u32>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for SchemaSlice {
        const NAME: &'static str = "TableProSchemaSlice";
        type Type = super::SchemaSlice;
        type Interfaces = (gio::ListModel,);
    }

    impl ObjectImpl for SchemaSlice {}

    impl ListModelImpl for SchemaSlice {
        fn item_type(&self) -> glib::Type {
            SidebarObject::static_type()
        }

        fn n_items(&self) -> u32 {
            self.end.get().saturating_sub(self.start.get())
        }

        fn item(&self, position: u32) -> Option<glib::Object> {
            if position >= self.n_items() {
                return None;
            }
            self.list.borrow().as_ref()?.item(self.start.get() + position)
        }
    }
}

glib::wrapper! {
    /// One schema's rows of a session's sidebar list: the run of one
    /// section, as the search keeps it. The list makes each row's object
    /// once, so a tree row and the list share it.
    pub struct SchemaSlice(ObjectSubclass<imp::SchemaSlice>)
        @implements gio::ListModel;
}

impl SchemaSlice {
    pub(crate) fn new(list: &SidebarList) -> Self {
        let slice: Self = glib::Object::new();
        slice.imp().list.replace(Some(list.clone()));
        slice
    }

    /// Show the list's rows from `start` to before `end`. The list's
    /// rows changed under every slice of it, so the slice says all of its
    /// rows changed even when its range is the same.
    pub(crate) fn set_range(&self, start: u32, end: u32) {
        let imp = self.imp();
        let removed = self.n_items();
        imp.start.set(start);
        imp.end.set(end.max(start));
        let added = self.n_items();
        if removed > 0 || added > 0 {
            self.items_changed(0, removed, added);
        }
    }

    /// Where the list's row at `position` is in the slice, when the slice
    /// holds it.
    pub(crate) fn offset_of(&self, position: u32) -> Option<u32> {
        let imp = self.imp();
        position
            .checked_sub(imp.start.get())
            .filter(|_| position < imp.end.get())
    }
}
