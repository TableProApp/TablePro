use std::cell::{Cell, OnceCell, RefCell};
use std::sync::OnceLock;

use glib::subclass::Signal;
use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::subclass::prelude::*;

use super::DialogParts;
use super::saved_query_listing::SearchSnapshot;

#[derive(Default, gtk::CompositeTemplate)]
#[template(resource = "/app/tablepro/TablePro/ui/saved-queries-dialog.ui")]
pub struct SavedQueriesDialog {
    #[template_child]
    pub toast_overlay: TemplateChild<adw::ToastOverlay>,
    #[template_child]
    pub search_entry: TemplateChild<gtk::SearchEntry>,
    #[template_child]
    pub stack: TemplateChild<gtk::Stack>,
    #[template_child]
    pub list_view: TemplateChild<gtk::ListView>,
    #[template_child]
    pub status_page: TemplateChild<adw::StatusPage>,
    #[template_child]
    pub error_page: TemplateChild<adw::StatusPage>,
    #[template_child]
    pub retry_button: TemplateChild<gtk::Button>,

    pub(super) parts: OnceCell<DialogParts>,
    pub(super) snapshot: RefCell<SearchSnapshot>,
    pub(super) search_generation: Cell<u64>,
    pub(super) load_generation: Cell<u64>,
    // Once a read has landed, a failed one keeps the list on screen.
    pub(super) listed: Cell<bool>,
}

#[glib::object_subclass]
impl ObjectSubclass for SavedQueriesDialog {
    const NAME: &'static str = "TableProSavedQueriesDialog";
    type Type = super::SavedQueriesDialog;
    type ParentType = adw::Dialog;

    fn class_init(klass: &mut Self::Class) {
        klass.bind_template();
    }

    fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
        object.init_template();
    }
}

impl ObjectImpl for SavedQueriesDialog {
    fn signals() -> &'static [Signal] {
        static SIGNALS: OnceLock<Vec<Signal>> = OnceLock::new();
        SIGNALS.get_or_init(|| {
            vec![
                Signal::builder("open-in-new-tab")
                    .param_types([String::static_type()])
                    .build(),
                Signal::builder("replace-current-tab")
                    .param_types([String::static_type()])
                    .build(),
            ]
        })
    }
}

impl WidgetImpl for SavedQueriesDialog {}
impl AdwDialogImpl for SavedQueriesDialog {}
