use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::sync::OnceLock;

use glib::subclass::Signal;
use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::subclass::prelude::*;
use tablepro_session::runtime::WatchForwarder;

use super::pager_bar::PagerBar;
use super::pending_changes_bar::PendingChangesBar;
use super::{BrowseModel, BrowseTabInput};

#[derive(Default, gtk::CompositeTemplate)]
#[template(resource = "/app/tablepro/TablePro/ui/browse-tab.ui")]
pub struct BrowseTab {
    #[template_child]
    pub toolbar: TemplateChild<adw::ToolbarView>,
    #[template_child]
    pub stale_banner: TemplateChild<adw::Banner>,
    #[template_child]
    pub read_only_banner: TemplateChild<adw::Banner>,
    #[template_child]
    pub no_pk_banner: TemplateChild<adw::Banner>,
    #[template_child]
    pub inner_stack: TemplateChild<gtk::Stack>,
    #[template_child]
    pub loading_page: TemplateChild<adw::StatusPage>,
    #[template_child]
    pub grid_holder: TemplateChild<gtk::Box>,
    #[template_child]
    pub error_page: TemplateChild<adw::StatusPage>,
    #[template_child]
    pub retry_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub insert_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub delete_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub pager_bar: TemplateChild<PagerBar>,
    #[template_child]
    pub selection_label: TemplateChild<gtk::Label>,
    #[template_child]
    pub more_button: TemplateChild<gtk::MenuButton>,
    #[template_child]
    pub export_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub filter_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub filter_badge: TemplateChild<gtk::Label>,
    #[template_child]
    pub page_size_dropdown: TemplateChild<gtk::DropDown>,
    #[template_child]
    pub pending_bar: TemplateChild<PendingChangesBar>,

    pub(super) model: RefCell<Option<BrowseModel>>,
    pub(super) queue: RefCell<VecDeque<BrowseTabInput>>,
    pub(super) dispatching: Cell<bool>,
    /// Delivers each reconnect, for as long as the tab is open.
    pub(super) link_watch: RefCell<Option<WatchForwarder>>,
}

#[glib::object_subclass]
impl ObjectSubclass for BrowseTab {
    const NAME: &'static str = "TableProBrowseTab";
    type Type = super::BrowseTab;
    type ParentType = adw::BreakpointBin;

    fn class_init(klass: &mut Self::Class) {
        PagerBar::ensure_type();
        PendingChangesBar::ensure_type();
        klass.bind_template();
    }

    fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
        object.init_template();
    }
}

impl ObjectImpl for BrowseTab {
    fn constructed(&self) {
        self.parent_constructed();
        super::browse_actions::describe_buttons(&self.obj());
    }

    fn signals() -> &'static [Signal] {
        static SIGNALS: OnceLock<Vec<Signal>> = OnceLock::new();
        SIGNALS.get_or_init(|| {
            vec![
                Signal::builder("state-changed").build(),
                Signal::builder("export-results")
                    .param_types([glib::BoxedAnyObject::static_type()])
                    .build(),
                Signal::builder("alert")
                    .param_types([String::static_type(), String::static_type()])
                    .build(),
                Signal::builder("toast").param_types([String::static_type()]).build(),
                Signal::builder("dirty-changed")
                    .param_types([bool::static_type()])
                    .build(),
                Signal::builder("save-requested").build(),
                Signal::builder("loading-changed")
                    .param_types([bool::static_type()])
                    .build(),
                Signal::builder("stop-save-requested").build(),
                Signal::builder("refresh-requested").build(),
            ]
        })
    }

    /// A cancelled read lets the server drop its statement rather than
    /// finish it for nobody.
    fn dispose(&self) {
        self.link_watch.take();
        if let Ok(mut model) = self.model.try_borrow_mut()
            && let Some(mut model) = model.take()
        {
            model.sequencer.cancel_all();
        }
    }
}

impl WidgetImpl for BrowseTab {}
impl BreakpointBinImpl for BrowseTab {}
