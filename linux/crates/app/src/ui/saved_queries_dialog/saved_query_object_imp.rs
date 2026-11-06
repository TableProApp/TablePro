use std::cell::{Cell, OnceCell};

use gtk4::glib;
use gtk4::subclass::prelude::*;
use tablepro_storage::saved_queries::SavedQuery;

#[derive(Default)]
pub struct SavedQueryObject {
    pub(super) saved: OnceCell<SavedQuery>,
    pub(super) group: Cell<u32>,
}

#[glib::object_subclass]
impl ObjectSubclass for SavedQueryObject {
    const NAME: &'static str = "TableProSavedQueryObject";
    type Type = super::SavedQueryObject;
}

impl ObjectImpl for SavedQueryObject {}
