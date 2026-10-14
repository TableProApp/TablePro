use std::cell::{Cell, OnceCell, RefCell};
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::subclass::prelude::*;
use relm4::Controller;
use tablepro_session::ConnectAttempts;
use tablepro_storage::SavedConnection;

use super::picker_page::PickerPage;
use super::session_page::SessionPage;
use super::{SessionWindowInput, WindowState};
use crate::runtime::InputSender;
use crate::ui::connect_dialog::ConnectDialog;
use crate::ui::welcome_view::WelcomeView;
use crate::workspace::{CloseGuards, WindowInhibitor};

#[derive(Default, gtk::CompositeTemplate)]
#[template(resource = "/app/tablepro/TablePro/ui/session-window.ui")]
pub struct SessionWindow {
    #[template_child]
    pub toast_overlay: TemplateChild<adw::ToastOverlay>,

    /// What the application handed the window, set once it is added.
    pub(super) state: OnceCell<WindowState>,
    pub(super) input: OnceCell<InputSender<SessionWindowInput>>,
    /// Handles the queued input. Aborted at shutdown, which drops every
    /// reply still on its way.
    pub(super) pump: RefCell<Option<glib::JoinHandle<()>>>,
    /// Ends the credential prompt loop with the window.
    pub(super) prompt_presenter: RefCell<Option<glib::JoinHandle<()>>>,
    pub(super) page: RefCell<SessionPage>,
    /// Which connect attempt is current, so a late result is discarded.
    pub(super) attempts: ConnectAttempts,
    /// One close prompt at a time, for a tab, the window or a
    /// disconnect.
    pub(super) close_guards: OnceCell<Rc<CloseGuards>>,
    /// Holds logout back while the workspace has something to lose.
    pub(super) inhibitor: RefCell<Option<WindowInhibitor>>,
    pub(super) dirty: Cell<bool>,
    pub(super) saving: Cell<bool>,
    pub(super) saved_connections: RefCell<Vec<SavedConnection>>,
    pub(super) welcome: RefCell<Option<Controller<WelcomeView>>>,
    pub(super) picker: OnceCell<PickerPage>,
    pub(super) dialog: RefCell<Option<ConnectDialog>>,
    pub(super) shut_down: Cell<bool>,
}

#[glib::object_subclass]
impl ObjectSubclass for SessionWindow {
    const NAME: &'static str = "TableProSessionWindow";
    type Type = super::SessionWindow;
    type ParentType = adw::ApplicationWindow;

    fn class_init(klass: &mut Self::Class) {
        klass.bind_template();
    }

    fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
        object.init_template();
    }
}

impl ObjectImpl for SessionWindow {
    /// A window dropped without its close request still closes what it
    /// holds.
    fn dispose(&self) {
        self.obj().shutdown();
    }
}

impl WidgetImpl for SessionWindow {}
impl WindowImpl for SessionWindow {}
impl ApplicationWindowImpl for SessionWindow {}
impl AdwApplicationWindowImpl for SessionWindow {}
