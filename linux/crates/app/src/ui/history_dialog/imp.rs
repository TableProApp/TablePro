use std::cell::{Cell, OnceCell, RefCell};
use std::sync::OnceLock;

use glib::subclass::Signal;
use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::subclass::prelude::*;
use tablepro_storage::query_history::HistoryQuery;

use super::DialogParts;
use super::history_paging::HistoryPaging;

#[derive(Default, gtk::CompositeTemplate, glib::Properties)]
#[template(resource = "/app/tablepro/TablePro/ui/history-dialog.ui")]
#[properties(wrapper_type = super::HistoryDialog)]
pub struct HistoryDialog {
    #[template_child]
    pub toast_overlay: TemplateChild<adw::ToastOverlay>,
    #[template_child]
    pub filter_button: TemplateChild<gtk::MenuButton>,
    #[template_child]
    pub reset_filters_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub connection_row: TemplateChild<adw::ComboRow>,
    #[template_child]
    pub status_row: TemplateChild<adw::ComboRow>,
    #[template_child]
    pub window_row: TemplateChild<adw::ComboRow>,
    #[template_child]
    pub search_bar: TemplateChild<gtk::SearchBar>,
    #[template_child]
    pub search_entry: TemplateChild<gtk::SearchEntry>,
    #[template_child]
    pub stack: TemplateChild<gtk::Stack>,
    #[template_child]
    pub scroll: TemplateChild<gtk::ScrolledWindow>,
    #[template_child]
    pub list_view: TemplateChild<gtk::ListView>,
    #[template_child]
    pub status_page: TemplateChild<adw::StatusPage>,
    #[template_child]
    pub selection_bar: TemplateChild<gtk::Revealer>,
    #[template_child]
    pub selection_label: TemplateChild<gtk::Label>,

    /// Select mode: rows show a check and the list takes a multiple
    /// selection instead of opening what is clicked.
    #[property(get, set = Self::set_selecting)]
    pub selecting: Cell<bool>,

    pub(super) parts: OnceCell<DialogParts>,
    /// The search the rows on screen answer.
    pub(super) query: RefCell<HistoryQuery>,
    pub(super) paging: RefCell<HistoryPaging>,
}

impl HistoryDialog {
    fn set_selecting(&self, selecting: bool) {
        if self.selecting.replace(selecting) != selecting {
            self.obj().selection_mode_changed();
        }
    }
}

#[glib::object_subclass]
impl ObjectSubclass for HistoryDialog {
    const NAME: &'static str = "TableProHistoryDialog";
    type Type = super::HistoryDialog;
    type ParentType = adw::Dialog;

    fn class_init(klass: &mut Self::Class) {
        klass.bind_template();
        super::history_actions::install(klass);
    }

    fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
        object.init_template();
    }
}

#[glib::derived_properties]
impl ObjectImpl for HistoryDialog {
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

    /// The row menu is parented to the list view, which would otherwise
    /// be finalized with a child it does not know about.
    fn dispose(&self) {
        if let Some(parts) = self.parts.get() {
            parts.menu.unparent();
        }
    }
}

impl WidgetImpl for HistoryDialog {}
impl AdwDialogImpl for HistoryDialog {}
