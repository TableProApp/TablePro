use std::cell::RefCell;
use std::sync::OnceLock;

use glib::subclass::Signal;
use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::subclass::prelude::*;

use super::Workspace;
use crate::ui::assistant::AssistantPane;
use crate::ui::export::ExportOperationsButton;

#[derive(Default, gtk::CompositeTemplate)]
#[template(resource = "/app/tablepro/TablePro/ui/workspace-shell.ui")]
pub struct WorkspaceShell {
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
    pub session_banners: TemplateChild<gtk::Stack>,
    #[template_child]
    pub tab_stack: TemplateChild<gtk::Stack>,
    #[template_child]
    pub empty_page: TemplateChild<adw::StatusPage>,
    #[template_child]
    pub empty_editor_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub tab_view: TemplateChild<adw::TabView>,

    /// The workspaces of the sessions the window holds, in the order
    /// they opened.
    pub(super) sessions: RefCell<Vec<Workspace>>,
    /// The one whose tab is in front, which the header bars, the banners
    /// and the window's actions speak for.
    pub(super) front: RefCell<Option<Workspace>>,
    /// Every session's running exports, which the one operations button
    /// lists together.
    pub(super) export_jobs: RefCell<Option<gio::ListStore>>,
    /// The saved connections, and the schemas and tables of each one open
    /// in the window.
    pub(super) tree: RefCell<Option<super::sidebar::ConnectionTree>>,
    /// The window the shell added its actions to.
    pub(super) window: glib::WeakRef<adw::ApplicationWindow>,
    /// The tab page whose menu is open: the view names it only then.
    pub(super) menu_target: RefCell<Option<adw::TabPage>>,
}

#[glib::object_subclass]
impl ObjectSubclass for WorkspaceShell {
    const NAME: &'static str = "TableProWorkspaceShell";
    type Type = super::WorkspaceShell;
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

impl ObjectImpl for WorkspaceShell {
    fn constructed(&self) {
        self.parent_constructed();
        super::workspace_shell::describe_buttons(&self.obj());
    }

    fn signals() -> &'static [Signal] {
        static SIGNALS: OnceLock<Vec<Signal>> = OnceLock::new();
        SIGNALS.get_or_init(|| vec![Signal::builder("front-changed").build()])
    }
}

impl WidgetImpl for WorkspaceShell {}
impl BinImpl for WorkspaceShell {}
