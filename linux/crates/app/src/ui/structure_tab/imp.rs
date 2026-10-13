use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::rc::Rc;
use std::sync::OnceLock;

use glib::subclass::Signal;
use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::subclass::prelude::*;
use tablepro_session::runtime::WatchForwarder;

use super::{StructureModel, StructureTabInput};

#[derive(Default, gtk::CompositeTemplate)]
#[template(resource = "/app/tablepro/TablePro/ui/structure-tab.ui")]
pub struct StructureTab {
    #[template_child]
    pub inner_stack: TemplateChild<gtk::Stack>,
    #[template_child]
    pub name_row: TemplateChild<adw::PreferencesGroup>,
    #[template_child]
    pub name_entry: TemplateChild<adw::EntryRow>,
    #[template_child]
    pub columns_box: TemplateChild<gtk::Box>,
    #[template_child]
    pub indexes_box: TemplateChild<gtk::Box>,
    #[template_child]
    pub fks_box: TemplateChild<gtk::Box>,
    #[template_child]
    pub copy_sql_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub sql_view: TemplateChild<sourceview5::View>,
    #[template_child]
    pub error_status: TemplateChild<adw::StatusPage>,
    #[template_child]
    pub retry_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub pending_label: TemplateChild<gtk::Label>,
    #[template_child]
    pub drop_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub discard_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub save_button: TemplateChild<gtk::Button>,

    pub(super) model: RefCell<Option<StructureModel>>,
    pub(super) queue: RefCell<VecDeque<StructureTabInput>>,
    pub(super) dispatching: Cell<bool>,
    pub(super) suppress_emit: Rc<Cell<bool>>,
    /// Delivers each reconnect, for as long as the tab is open.
    pub(super) link_watch: RefCell<Option<WatchForwarder>>,
}

#[glib::object_subclass]
impl ObjectSubclass for StructureTab {
    const NAME: &'static str = "TableProStructureTab";
    type Type = super::StructureTab;
    type ParentType = adw::Bin;

    fn class_init(klass: &mut Self::Class) {
        sourceview5::View::ensure_type();
        klass.bind_template();
    }

    fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
        object.init_template();
    }
}

impl ObjectImpl for StructureTab {
    fn signals() -> &'static [Signal] {
        static SIGNALS: OnceLock<Vec<Signal>> = OnceLock::new();
        SIGNALS.get_or_init(|| {
            vec![
                Signal::builder("dirty-changed")
                    .param_types([bool::static_type()])
                    .build(),
                Signal::builder("execute")
                    .param_types([glib::BoxedAnyObject::static_type()])
                    .build(),
                Signal::builder("drop-table-requested")
                    .param_types([String::static_type(), String::static_type()])
                    .build(),
                Signal::builder("toast").param_types([String::static_type()]).build(),
                Signal::builder("alert")
                    .param_types([String::static_type(), String::static_type()])
                    .build(),
            ]
        })
    }

    /// Closing the tab stops its read and lets go of the theme handler
    /// on the app-wide style manager.
    fn dispose(&self) {
        self.link_watch.take();
        if let Ok(mut model) = self.model.try_borrow_mut()
            && let Some(mut model) = model.take()
        {
            model.sequencer.cancel_all();
        }
    }
}

impl WidgetImpl for StructureTab {}
impl BinImpl for StructureTab {}
