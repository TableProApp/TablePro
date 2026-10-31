use std::cell::{OnceCell, RefCell};
use std::collections::VecDeque;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;
use libadwaita::subclass::prelude::*;

use super::{ClosedTabDescriptor, Workspace};
use crate::runtime::InputSender;
use crate::ui::SessionWindowInput;
use crate::ui::export::ExportOperationsButton;

/// A session the shell holds, with what it hears from it.
pub(super) struct HeldSession {
    pub(super) workspace: Workspace,
    pub(super) handlers: Vec<glib::SignalHandlerId>,
    /// Its exports, which leave the operations button with it.
    pub(super) jobs: Option<gio::ListStore>,
}

/// A tab closed in one of the window's sessions, which Ctrl+Shift+T
/// opens again in that session.
pub(super) struct ClosedTab {
    pub(super) session: glib::WeakRef<Workspace>,
    pub(super) tab: ClosedTabDescriptor,
}

#[derive(Default, gtk::CompositeTemplate, glib::Properties)]
#[properties(wrapper_type = super::WorkspaceShell)]
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
    pub table_search_toggle: TemplateChild<gtk::ToggleButton>,
    #[template_child]
    pub refresh_tables_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub table_search_bar: TemplateChild<gtk::SearchBar>,
    #[template_child]
    pub table_search: TemplateChild<gtk::SearchEntry>,
    #[template_child]
    pub list_banners: TemplateChild<gtk::Stack>,
    #[template_child]
    pub sidebar_slot: TemplateChild<adw::Bin>,
    #[template_child]
    pub assistant_split: TemplateChild<adw::OverlaySplitView>,
    #[template_child]
    pub assistant_stack: TemplateChild<gtk::Stack>,
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

    /// The session the header bars, the banners and the window's actions
    /// speak for: the one whose tab is selected, or with no tab, the one
    /// that joined or was shown last.
    #[property(get)]
    pub(super) front: RefCell<Option<Workspace>>,
    /// The sessions the window holds, in the order they joined.
    pub(super) sessions: RefCell<Vec<HeldSession>>,
    /// Every session's running exports, which the one operations button
    /// lists together.
    pub(super) export_jobs: OnceCell<gio::ListStore>,
    /// The saved connections, and the schemas and tables of each one open
    /// in the window.
    pub(super) tree: OnceCell<super::sidebar::ConnectionTree>,
    /// The window the shell added its actions to.
    pub(super) window: glib::WeakRef<adw::ApplicationWindow>,
    pub(super) sender: OnceCell<InputSender<SessionWindowInput>>,
    /// The tab page whose menu is open: the view names it only then.
    pub(super) menu_target: RefCell<Option<adw::TabPage>>,
    /// The tab menu's actions, which dim for the page the menu opens on.
    pub(super) tab_actions: OnceCell<gio::SimpleActionGroup>,
    /// The tabs closed last, the newest at the back.
    pub(super) closed_tabs: RefCell<VecDeque<ClosedTab>>,
    /// The tabs the window showed, the latest first.
    pub(super) recent_tabs: RefCell<Vec<glib::WeakRef<adw::TabPage>>>,
    pub(super) recent_walk: RefCell<Option<super::recent_tabs::RecentWalk>>,
    pub(super) walk_hooks: RefCell<Option<super::recent_tabs::WalkHooks>>,
    /// Flips the window's history actions as the query database opens.
    pub(super) history_gate: RefCell<Option<glib::JoinHandle<()>>>,
    /// What follows the session in front, let go of at shutdown.
    pub(super) watches: RefCell<Vec<gtk::ExpressionWatch>>,
    /// The overview's new tab, connected to the front's tab factory.
    pub(super) create_tab: RefCell<Option<glib::SignalHandlerId>>,
}

#[glib::object_subclass]
impl ObjectSubclass for WorkspaceShell {
    const NAME: &'static str = "TableProWorkspaceShell";
    type Type = super::WorkspaceShell;
    type ParentType = adw::Bin;

    fn class_init(klass: &mut Self::Class) {
        ExportOperationsButton::ensure_type();
        klass.bind_template();
    }

    fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
        object.init_template();
    }
}

#[glib::derived_properties]
impl ObjectImpl for WorkspaceShell {
    fn constructed(&self) {
        self.parent_constructed();
        super::workspace_shell::describe_buttons(&self.obj());
    }
}

impl WidgetImpl for WorkspaceShell {}
impl BinImpl for WorkspaceShell {}
