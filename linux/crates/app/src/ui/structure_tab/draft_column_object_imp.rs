use std::cell::RefCell;
use std::marker::PhantomData;

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_core::ddl::{DraftColumn, DraftType};

use super::draft_column_object::{UnparsedDefault, column_summary};

#[derive(glib::Properties)]
#[properties(wrapper_type = super::draft_column_object::DraftColumnObject)]
pub struct DraftColumnObject {
    pub(super) column: RefCell<DraftColumn>,
    pub(super) unparsed_default: RefCell<Option<UnparsedDefault>>,
    #[property(get = Self::name)]
    name: PhantomData<String>,
    /// What the collapsed row says under the name.
    #[property(get = Self::summary)]
    summary: PhantomData<String>,
    /// Why the engine's parser refused the default the user typed.
    #[property(get = Self::default_error)]
    default_error: PhantomData<Option<String>>,
}

/// What an object made by `glib::Object::new` rather than
/// `DraftColumnObject::new` holds: a column with no name or type.
impl Default for DraftColumnObject {
    fn default() -> Self {
        Self {
            column: RefCell::new(DraftColumn::new(String::new(), DraftType::Typed(String::new()))),
            unparsed_default: RefCell::default(),
            name: PhantomData,
            summary: PhantomData,
            default_error: PhantomData,
        }
    }
}

#[glib::object_subclass]
impl ObjectSubclass for DraftColumnObject {
    const NAME: &'static str = "TableProDraftColumnObject";
    type Type = super::draft_column_object::DraftColumnObject;
}

#[glib::derived_properties]
impl ObjectImpl for DraftColumnObject {}

impl DraftColumnObject {
    fn name(&self) -> String {
        self.column.borrow().name.clone()
    }

    fn summary(&self) -> String {
        column_summary(&self.column.borrow())
    }

    fn default_error(&self) -> Option<String> {
        self.unparsed_default
            .borrow()
            .as_ref()
            .map(|unparsed| unparsed.error.clone())
    }
}
