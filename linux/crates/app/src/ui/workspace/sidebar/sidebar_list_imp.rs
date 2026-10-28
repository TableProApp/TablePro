use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::Arc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};

use super::sidebar_index::SidebarIndex;
use super::sidebar_list::Entries;
use super::sidebar_object::SidebarObject;

#[derive(Default)]
pub struct SidebarList {
    pub(super) index: RefCell<Arc<SidebarIndex>>,
    /// The index's entries the list shows, in list order.
    pub(super) entries: RefCell<Entries>,
    /// The rows made so far, by entry: the same entry gives the same
    /// object until a new index replaces it.
    pub(super) objects: RefCell<HashMap<u32, SidebarObject>>,
}

#[glib::object_subclass]
impl ObjectSubclass for SidebarList {
    const NAME: &'static str = "TableProSidebarList";
    type Type = super::sidebar_list::SidebarList;
    type Interfaces = (gio::ListModel,);
}

impl ObjectImpl for SidebarList {}

impl ListModelImpl for SidebarList {
    fn item_type(&self) -> glib::Type {
        SidebarObject::static_type()
    }

    fn n_items(&self) -> u32 {
        self.entries.borrow().len()
    }

    fn item(&self, position: u32) -> Option<glib::Object> {
        let entry = self.entries.borrow().get(position)?;
        if let Some(object) = self.objects.borrow().get(&entry) {
            return Some(object.clone().upcast());
        }
        let index = self.index.borrow();
        let row = index.entry(entry)?;
        let section = index.section(row.section)?;
        let object = SidebarObject::new(&row.table, row.kind, &section.title);
        self.objects.borrow_mut().insert(entry, object.clone());
        Some(object.upcast())
    }
}
