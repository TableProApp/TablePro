use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};

use super::sidebar_index::SidebarIndex;
use super::sidebar_object::SidebarObject;

#[derive(Default)]
pub struct SidebarList {
    pub(super) index: RefCell<Rc<SidebarIndex>>,
    /// The entries the search keeps, in list order.
    pub(super) shown: RefCell<Vec<u32>>,
    /// Each section's rows in `shown`, from the first to past the last.
    pub(super) runs: RefCell<Vec<(u32, u32)>>,
    /// The rows made so far, by entry: the same entry gives the same
    /// object until a new index replaces it.
    pub(super) objects: RefCell<HashMap<u32, SidebarObject>>,
}

#[glib::object_subclass]
impl ObjectSubclass for SidebarList {
    const NAME: &'static str = "TableProSidebarList";
    type Type = super::sidebar_list::SidebarList;
    type Interfaces = (gio::ListModel, gtk::SectionModel);
}

impl ObjectImpl for SidebarList {}

impl ListModelImpl for SidebarList {
    fn item_type(&self) -> glib::Type {
        SidebarObject::static_type()
    }

    fn n_items(&self) -> u32 {
        u32::try_from(self.shown.borrow().len()).unwrap_or(u32::MAX)
    }

    fn item(&self, position: u32) -> Option<glib::Object> {
        let entry = *self.shown.borrow().get(position as usize)?;
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

impl SectionModelImpl for SidebarList {
    /// Past the last row, GTK expects one range from the end onwards.
    fn section(&self, position: u32) -> (u32, u32) {
        let runs = self.runs.borrow();
        let at = runs.partition_point(|&(_, end)| end <= position);
        match runs.get(at) {
            Some(&(start, end)) if start <= position => (start, end),
            _ => (self.n_items(), u32::MAX),
        }
    }
}
