use std::cell::OnceCell;
use std::marker::PhantomData;

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_storage::SavedConnection;

#[derive(Default, glib::Properties)]
#[properties(wrapper_type = super::saved_connection_object::SavedConnectionObject)]
pub struct SavedConnectionObject {
    pub(super) saved: OnceCell<SavedConnection>,
    #[property(get = Self::id)]
    id: PhantomData<String>,
    #[property(get = Self::name)]
    name: PhantomData<String>,
    /// The driver and where it connects, as the row shows it.
    #[property(get = Self::subtitle)]
    subtitle: PhantomData<String>,
    #[property(get = Self::group)]
    group: PhantomData<Option<String>>,
    /// Milliseconds since the epoch, or 0 for never.
    #[property(get = Self::last_opened)]
    last_opened: PhantomData<i64>,
}

#[glib::object_subclass]
impl ObjectSubclass for SavedConnectionObject {
    const NAME: &'static str = "TableProSavedConnectionObject";
    type Type = super::saved_connection_object::SavedConnectionObject;
}

#[glib::derived_properties]
impl ObjectImpl for SavedConnectionObject {}

impl SavedConnectionObject {
    fn id(&self) -> String {
        self.saved.get().map(|saved| saved.id.to_string()).unwrap_or_default()
    }

    fn name(&self) -> String {
        self.saved.get().map(|saved| saved.name.clone()).unwrap_or_default()
    }

    fn subtitle(&self) -> String {
        self.saved
            .get()
            .map(|saved| super::saved_connection_object::subtitle_for(saved, None))
            .unwrap_or_default()
    }

    fn group(&self) -> Option<String> {
        self.saved
            .get()
            .and_then(|saved| super::saved_connection_order::group_of(saved).map(str::to_owned))
    }

    fn last_opened(&self) -> i64 {
        self.saved
            .get()
            .and_then(|saved| saved.last_opened_at)
            .map_or(0, |at| at.timestamp_millis())
    }
}
