use std::cell::{Cell, OnceCell, RefCell};
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::subclass::prelude::*;
use tablepro_session::{ConnectAttempts, SessionKey};

use super::locate_file::LocateChooser;
use super::picker_page::PickerPage;
use super::session_page::SessionPage;
use super::work_notifier::WorkNotifier;
use super::{SessionWindowInput, WindowState};
use crate::runtime::InputSender;
use crate::services::file_location::LocationClassifier;
use crate::services::saved_connection_list::StateObserverId;
use crate::ui::connect_dialog::ConnectDialog;
use crate::ui::welcome_view::WelcomeView;
use crate::workspace::{CloseGuards, WindowInhibitor};

#[derive(Default, gtk::CompositeTemplate)]
#[template(resource = "/app/tablepro/TablePro/ui/session-window.ui")]
pub struct SessionWindow {
    /// The toasts of the page on screen. Each page has its own, under
    /// its header bar, so a workspace's sit inside the tab overview.
    pub(super) page_toasts: RefCell<Option<adw::ToastOverlay>>,
    /// What the application handed the window, set once it is added.
    pub(super) state: OnceCell<WindowState>,
    pub(super) input: OnceCell<InputSender<SessionWindowInput>>,
    /// Handles the queued input. Aborted at shutdown, which closes a
    /// connect still queued and drops every other reply.
    pub(super) pump: RefCell<Option<glib::JoinHandle<()>>>,
    /// Ends the credential prompt loop with the window.
    pub(super) prompt_presenter: RefCell<Option<glib::JoinHandle<()>>>,
    pub(super) page: RefCell<SessionPage>,
    /// Which connect attempt is current, so a late result is discarded.
    pub(super) attempts: ConnectAttempts,
    /// The recorded session the window was opened to restore, until the
    /// saved connection is looked up or the file resolved.
    pub(super) restoring: RefCell<Option<SessionKey>>,
    /// One close prompt at a time, for a tab, the window or a
    /// disconnect.
    pub(super) close_guards: OnceCell<Rc<CloseGuards>>,
    /// Holds logout back while the workspace has something to lose.
    pub(super) inhibitor: RefCell<Option<WindowInhibitor>>,
    pub(super) dirty: Cell<bool>,
    pub(super) saving: Cell<bool>,
    pub(super) welcome: RefCell<Option<WelcomeView>>,
    /// Shows the banner while the shared connection list cannot be read.
    pub(super) list_observer: Cell<Option<StateObserverId>>,
    pub(super) picker: OnceCell<PickerPage>,
    pub(super) dialog: RefCell<Option<ConnectDialog>>,
    /// The connect dialog was asked for and opens once the SSH keys are
    /// looked for.
    pub(super) dialog_opening: Cell<bool>,
    pub(super) shut_down: Cell<bool>,
    /// Every toast shown, which the overlay does not list.
    #[cfg(test)]
    pub(super) toasts: RefCell<Vec<adw::Toast>>,
    /// A file handed to the window is being resolved, so the window is
    /// not free for another one.
    pub(super) opening_file: Cell<bool>,
    /// The window opened for a file and has shown nothing else yet, so
    /// it closes again when another window already has that file.
    pub(super) opened_for_file: Cell<bool>,
    /// Reads which filesystem a database file is on. `None` reads the
    /// real one; a test stands in for a network share.
    pub(super) classify_location: Cell<Option<LocationClassifier>>,
    /// Asks where a lost database file is now. `None` opens the file
    /// chooser; a test answers for the user.
    pub(super) locate_chooser: RefCell<Option<Rc<dyn LocateChooser>>>,
    /// Tells the desktop when work ends in a tab the user is not
    /// looking at.
    pub(super) notifier: RefCell<Option<WorkNotifier>>,
    /// Whether the window counts as the active one, which a test session
    /// with no window manager cannot decide.
    #[cfg(test)]
    pub(super) active_for_test: Cell<Option<bool>>,
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
