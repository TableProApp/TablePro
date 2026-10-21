use std::cell::OnceCell;
use std::marker::PhantomData;

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_core::meta::{ObjectKind, TableRef};

#[derive(Default, glib::Properties)]
#[properties(wrapper_type = super::sidebar_object::SidebarObject)]
pub struct SidebarObject {
    pub(super) table: OnceCell<TableRef>,
    pub(super) kind: OnceCell<ObjectKind>,
    pub(super) title: OnceCell<String>,
    #[property(get = Self::schema)]
    schema: PhantomData<Option<String>>,
    #[property(get = Self::name)]
    name: PhantomData<String>,
    #[property(get = Self::icon_name)]
    icon_name: PhantomData<String>,
    /// The schema's heading, which groups the rows into sections.
    #[property(get = Self::section_title)]
    section_title: PhantomData<String>,
}

#[glib::object_subclass]
impl ObjectSubclass for SidebarObject {
    const NAME: &'static str = "TableProSidebarObject";
    type Type = super::sidebar_object::SidebarObject;
}

#[glib::derived_properties]
impl ObjectImpl for SidebarObject {}

impl SidebarObject {
    fn schema(&self) -> Option<String> {
        self.table.get().and_then(|table| table.schema.clone())
    }

    fn name(&self) -> String {
        self.table.get().map(|table| table.name.clone()).unwrap_or_default()
    }

    fn icon_name(&self) -> String {
        let icon = match self.kind.get() {
            Some(ObjectKind::View) => crate::ui::icons::VIEW_LIST,
            Some(ObjectKind::MaterializedView) => crate::ui::icons::VIEW_PAGED,
            _ => crate::ui::icons::VIEW_GRID,
        };
        icon.to_owned()
    }

    fn section_title(&self) -> String {
        self.title.get().cloned().unwrap_or_default()
    }
}
