use std::cell::OnceCell;

use gtk4::glib;
use gtk4::subclass::prelude::*;
use tablepro_storage::query_history::Entry;

#[derive(Default)]
pub struct HistoryEntryObject {
    pub(super) entry: OnceCell<Entry>,
}

#[glib::object_subclass]
impl ObjectSubclass for HistoryEntryObject {
    const NAME: &'static str = "TableProHistoryEntryObject";
    type Type = super::HistoryEntryObject;
}

impl ObjectImpl for HistoryEntryObject {}
