use std::cell::RefCell;
use std::sync::OnceLock;

use glib::subclass::Signal;
use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::subclass::prelude::*;

use super::WorkspaceModel;
use crate::ui::assistant::AssistantPane;
use crate::ui::export::ExportOperationsButton;

#[derive(Default, gtk::CompositeTemplate)]
#[template(resource = "/app/tablepro/TablePro/ui/workspace.ui")]
pub struct Workspace {
    #[template_child]
    pub tab_overview: TemplateChild<adw::TabOverview>,
    #[template_child]
    pub breakpoint_bin: TemplateChild<adw::BreakpointBin>,
    #[template_child]
    pub narrow_breakpoint: TemplateChild<adw::Breakpoint>,
    #[template_child]
    pub toast_overlay: TemplateChild<adw::ToastOverlay>,
    #[template_child]
    pub split_view: TemplateChild<adw::OverlaySplitView>,
    #[template_child]
    pub sidebar_root: TemplateChild<adw::ToolbarView>,
    #[template_child]
    pub sidebar_header: TemplateChild<adw::HeaderBar>,
    #[template_child]
    pub sidebar_title: TemplateChild<adw::WindowTitle>,
    #[template_child]
    pub table_search_toggle: TemplateChild<gtk::ToggleButton>,
    #[template_child]
    pub refresh_tables_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub table_search_bar: TemplateChild<gtk::SearchBar>,
    #[template_child]
    pub table_search: TemplateChild<gtk::SearchEntry>,
    #[template_child]
    pub catalog_banner: TemplateChild<adw::Banner>,
    #[template_child]
    pub key_limit_banner: TemplateChild<adw::Banner>,
    #[template_child]
    pub sidebar_slot: TemplateChild<adw::Bin>,
    #[template_child]
    pub assistant_split: TemplateChild<adw::OverlaySplitView>,
    #[template_child]
    pub assistant_pane: TemplateChild<AssistantPane>,
    #[template_child]
    pub content_root: TemplateChild<adw::ToolbarView>,
    #[template_child]
    pub content_header: TemplateChild<adw::HeaderBar>,
    #[template_child]
    pub sidebar_toggle: TemplateChild<gtk::ToggleButton>,
    #[template_child]
    pub new_tab_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub window_title: TemplateChild<adw::WindowTitle>,
    #[template_child]
    pub connection_icon: TemplateChild<gtk::Image>,
    #[template_child]
    pub assistant_toggle: TemplateChild<gtk::ToggleButton>,
    #[template_child]
    pub tab_button: TemplateChild<adw::TabButton>,
    #[template_child]
    pub export_operations_button: TemplateChild<ExportOperationsButton>,
    #[template_child]
    pub row_op_spinner: TemplateChild<adw::Spinner>,
    #[template_child]
    pub tab_bar: TemplateChild<adw::TabBar>,
    #[template_child]
    pub reconnect_banner: TemplateChild<adw::Banner>,
    #[template_child]
    pub transaction_banner: TemplateChild<adw::Banner>,
    #[template_child]
    pub layout_banner: TemplateChild<adw::Banner>,
    #[template_child]
    pub tab_stack: TemplateChild<gtk::Stack>,
    #[template_child]
    pub empty_page: TemplateChild<adw::StatusPage>,
    #[template_child]
    pub empty_editor_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub tab_view: TemplateChild<adw::TabView>,

    pub(super) model: RefCell<Option<WorkspaceModel>>,
    /// Handles the queued input, and with it every reply the workspace
    /// is still waiting on. Aborted at shutdown, which drops them.
    pub(super) pump: RefCell<Option<glib::JoinHandle<()>>>,
}

#[glib::object_subclass]
impl ObjectSubclass for Workspace {
    const NAME: &'static str = "TableProWorkspace";
    type Type = super::Workspace;
    type ParentType = adw::Bin;

    fn class_init(klass: &mut Self::Class) {
        ExportOperationsButton::ensure_type();
        AssistantPane::ensure_type();
        klass.bind_template();
    }

    fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
        object.init_template();
    }
}

impl ObjectImpl for Workspace {
    fn constructed(&self) {
        self.parent_constructed();
        super::shell::describe_buttons(&self.obj());
    }

    fn signals() -> &'static [Signal] {
        static SIGNALS: OnceLock<Vec<Signal>> = OnceLock::new();
        SIGNALS.get_or_init(|| {
            vec![
                Signal::builder("dirty-changed")
                    .param_types([bool::static_type()])
                    .build(),
                Signal::builder("saves-in-flight-changed")
                    .param_types([u32::static_type()])
                    .build(),
                Signal::builder("title-changed")
                    .param_types([String::static_type()])
                    .build(),
                Signal::builder("work-completed")
                    .param_types([glib::BoxedAnyObject::static_type()])
                    .build(),
                Signal::builder("tabs-changed").build(),
            ]
        })
    }

    /// A workspace dropped without a teardown still stops its reads and
    /// lets go of its tabs.
    fn dispose(&self) {
        self.obj().shutdown();
    }
}

impl WidgetImpl for Workspace {}
impl BinImpl for Workspace {}
