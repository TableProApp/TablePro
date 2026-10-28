use std::cell::RefCell;
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
    /// The rows made so far, by position: the same position gives the
    /// same object until the list shows other entries. GtkTreeListModel
    /// asks for every row of a schema it opens, so a lookup by hash
    /// would cost as much again as making the rows.
    pub(super) objects: RefCell<Vec<Option<SidebarObject>>>,
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
        let entries = self.entries.borrow();
        let entry = entries.get(position)?;
        let at = position as usize;
        if let Some(Some(object)) = self.objects.borrow().get(at) {
            return Some(object.clone().upcast());
        }
        let index = self.index.borrow();
        index.entry(entry)?;
        let object = SidebarObject::new(&index, entry);
        let mut objects = self.objects.borrow_mut();
        if objects.len() <= at {
            objects.resize(entries.len() as usize, None);
        }
        objects[at] = Some(object.clone());
        Some(object.upcast())
    }
}
