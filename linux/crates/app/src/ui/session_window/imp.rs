use std::cell::{Cell, OnceCell, RefCell};
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::subclass::prelude::*;
use tablepro_session::{ConnectSource, SessionKey};
use uuid::Uuid;

use super::connections::LevelSave;
use super::launch_notice::Said;
use super::locate_file::LocateChooser;
use super::picker_page::PickerPage;
use super::session_page::{FailedConnect, OpenSession, PendingConnect, SessionPage};
use super::session_window_command::ConnectFailure;
use super::work_notifier::WorkNotifier;
use super::{SessionWindowInput, WindowState};
use crate::runtime::InputSender;
use crate::services::file_location::LocationClassifier;
use crate::services::saved_connection_list::StateObserverId;
use crate::ui::connect_dialog::ConnectDialog;
use crate::ui::welcome_view::WelcomeView;
use crate::ui::workspace::WorkspaceShell;
use crate::workspace::{CloseGuards, WindowInhibitor};

#[derive(Default, gtk::CompositeTemplate, glib::Properties)]
#[template(resource = "/app/tablepro/TablePro/ui/session-window.ui")]
#[properties(wrapper_type = super::SessionWindow)]
pub struct SessionWindow {
    /// The toasts of the page on screen. Each page has its own, under
    /// its header bar, so the shell's sit inside the tab overview.
    pub(super) page_toasts: RefCell<Option<adw::ToastOverlay>>,
    /// What the application handed the window, set once it is added.
    pub(super) state: OnceCell<WindowState>,
    pub(super) input: OnceCell<InputSender<SessionWindowInput>>,
    /// Handles the queued input. Aborted at shutdown, which closes a
    /// connect still queued and drops every other reply.
    pub(super) pump: RefCell<Option<glib::JoinHandle<()>>>,
    /// Ends the credential prompt loop with the window.
    pub(super) prompt_presenter: RefCell<Option<glib::JoinHandle<()>>>,
    /// The sessions the window holds, in the order it adopted them.
    pub(super) sessions: RefCell<Vec<OpenSession>>,
    /// Every connect the window runs, in the order they started.
    pub(super) connects: RefCell<Vec<PendingConnect>>,
    /// The id the next connect takes.
    pub(super) next_connect: Cell<u64>,
    /// A connect that failed with nothing else to show, for the failed
    /// page. Only while the window holds no session and runs no connect.
    pub(super) failed: RefCell<Option<FailedConnect>>,
    /// The last failure of each connect that failed beside something
    /// else, until the key connects again, for its Details.
    pub(super) failures: RefCell<HashMap<SessionKey, (ConnectSource, ConnectFailure)>>,
    /// The shell, from the first session the window adopts to the last
    /// one it tears down.
    pub(super) shell: RefCell<Option<WorkspaceShell>>,
    /// The page on screen, so a change that leaves it the same does not
    /// build it again.
    pub(super) shown: Cell<Option<SessionPage>>,
    /// The recorded sessions the window was opened to restore, until
    /// each saved connection is looked up or each file resolved.
    pub(super) restoring: RefCell<Vec<SessionKey>>,
    /// Another database opening beside its connection, and what waits for
    /// its session: each tab moved there while it opened.
    pub(super) opening_databases: RefCell<HashMap<SessionKey, super::sibling_sessions::Opening>>,
    /// One close prompt at a time, for a tab, the window or a
    /// disconnect.
    pub(super) close_guards: OnceCell<Rc<CloseGuards>>,
    /// Holds logout back while a session has something to lose.
    pub(super) inhibitor: RefCell<Option<WindowInhibitor>>,
    pub(super) dirty: Cell<bool>,
    /// Whether a save of any session is being written.
    #[property(get)]
    pub(super) saving: Cell<bool>,
    /// The saved connections whose Safe Mode level is being written.
    pub(super) level_saving: RefCell<HashSet<Uuid>>,
    /// The newest level chosen for a connection while one was being
    /// written, which goes next so the last choice is the one that stays.
    pub(super) level_next: RefCell<HashMap<Uuid, LevelSave>>,
    pub(super) welcome: RefCell<Option<WelcomeView>>,
    /// Shows the banner while the shared connection list cannot be read.
    pub(super) list_observer: Cell<Option<StateObserverId>>,
    pub(super) picker: OnceCell<PickerPage>,
    pub(super) dialog: RefCell<Option<ConnectDialog>>,
    /// Manage Tags while it is open, which its rows' callbacks need.
    pub(super) manage_tags: RefCell<Option<Rc<crate::ui::tags::ManageTagsDialog>>>,
    /// The connect dialog was asked for and opens once the SSH keys are
    /// looked for.
    pub(super) dialog_opening: Cell<bool>,
    pub(super) shut_down: Cell<bool>,
    pub(super) launch_notices: RefCell<Vec<Said>>,
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

#[glib::derived_properties]
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
