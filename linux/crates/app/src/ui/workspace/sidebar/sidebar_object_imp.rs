use std::cell::{Cell, OnceCell};
use std::marker::PhantomData;
use std::sync::Arc;

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;

use super::sidebar_index::SidebarIndex;

#[derive(Default, glib::Properties)]
#[properties(wrapper_type = super::sidebar_object::SidebarObject)]
pub struct SidebarObject {
    /// The index the object reads its table from, shared by every row
    /// of the list.
    pub(super) index: OnceCell<Arc<SidebarIndex>>,
    pub(super) entry: Cell<u32>,
    /// Read from the index when asked, so it costs the object nothing.
    #[property(get = Self::name)]
    name: PhantomData<String>,
}

#[glib::object_subclass]
impl ObjectSubclass for SidebarObject {
    const NAME: &'static str = "TableProSidebarObject";
    type Type = super::sidebar_object::SidebarObject;
}

#[glib::derived_properties]
impl ObjectImpl for SidebarObject {}

impl SidebarObject {
    fn name(&self) -> String {
        self.index
            .get()
            .and_then(|index| index.entry(self.entry.get()))
            .map(|row| row.table.name.clone())
            .unwrap_or_default()
    }
}
