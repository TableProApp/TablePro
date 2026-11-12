use std::cell::{Cell, OnceCell, RefCell};
use std::ops::ControlFlow;
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::subclass::prelude::*;

use super::app_activity::Activity;
use super::open_files::Placement;
use super::session_signals::SessionSignals;
use super::{AppServices, WindowRegistry, install_app_actions, install_application_accelerators};
use crate::workspace::CloseDecision;

pub(super) const NEW_WINDOW_OPTION: &str = "new-window";
// GOption's G_OPTION_REMAINING: the files and links after the options.
pub(super) const FILES_OPTION: &str = "";

#[derive(Default)]
pub struct TableProApplication {
    pub(super) services: OnceCell<Rc<AppServices>>,
    pub(super) windows: WindowRegistry,
    /// The quit in progress, if any.
    pub(super) quit: RefCell<Option<glib::JoinHandle<CloseDecision>>>,
    /// The window the quit is waiting on.
    pub(super) quit_asking: Cell<Option<u32>>,
    /// Only the primary instance has sessions to tell.
    pub(super) session_signals: RefCell<Option<SessionSignals>>,
    /// Only the first activate restores the last session.
    pub(super) restore: Cell<RestoreState>,
    /// The restore waiting on the record, which a quit approved
    /// meanwhile waits for too.
    pub(super) restoring: RefCell<Option<glib::JoinHandle<()>>>,
    /// Files and links handed over while the record is read, opened
    /// after the windows it restores.
    pub(super) pending_files: RefCell<Vec<(Vec<gio::File>, Placement)>>,
    /// What to say at launch, found before any window opened.
    pub(super) launch_notices: RefCell<Vec<crate::ui::LaunchNotice>>,
    /// Answers the MCP server's questions about windows and sessions.
    pub(super) mcp_requests: RefCell<Option<glib::JoinHandle<()>>>,
    pub(super) activity: Cell<Activity>,
    // Set at the primary instance's startup; the license ask counts its quiet period from it.
    pub(super) launched_at: Cell<Option<std::time::Instant>>,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub(super) enum RestoreState {
    #[default]
    NotAttempted,
    /// The record is being read, and the windows open once it is.
    Loading,
    Done,
    /// An approved quit is writing the record, or waiting out a read of
    /// it whose windows it keeps from opening. A launch meanwhile asks
    /// for it to be restored after: read earlier, it would race the
    /// write, and the quit then empties the list it restored into.
    Quitting {
        relaunched: bool,
    },
}

#[glib::object_subclass]
impl ObjectSubclass for TableProApplication {
    const NAME: &'static str = "TpApplication";
    type Type = super::TableProApplication;
    type ParentType = adw::Application;
}

impl ObjectImpl for TableProApplication {
    fn constructed(&self) {
        self.parent_constructed();
        // GApplication parses the command line before it emits
        // handle-local-options, so an option added there is unknown.
        self.obj().add_main_option(
            NEW_WINDOW_OPTION,
            glib::Char::from(b'n'),
            glib::OptionFlags::NONE,
            glib::OptionArg::None,
            &crate::i18n::gettext("Open a new window"),
            None,
        );
        // GOption collects the files, so handle-local-options can send them with --new-window's hint.
        self.obj().add_main_option(
            FILES_OPTION,
            glib::Char::from(b'\0'),
            glib::OptionFlags::NONE,
            glib::OptionArg::FilenameArray,
            "",
            Some(&crate::i18n::gettext("[FILE or URL…]")),
        );
    }
}

impl ApplicationImpl for TableProApplication {
    fn startup(&self) {
        self.parent_startup();
        // GtkSourceView's stylesheet, icon path and translations need the
        // display, which GTK opens in the startup above.
        sourceview5::init();
        let app = self.obj();
        install_app_actions(&app);
        install_application_accelerators(&*app);
        app.follow_activity();
        if let Some(services) = self.services.get() {
            services.start();
            app.start_license_ask();
            app.start_mcp();
            app.look_for_crash_report();
            app.note_launch_version();
            self.session_signals
                .replace(Some(SessionSignals::start(&services.sessions)));
        }
        app.connect_query_end(|app| {
            app.present_inhibiting_window();
        });
    }

    fn activate(&self) {
        self.parent_activate();
        let app = self.obj();
        if let Some(window) = app.active_window() {
            window.present();
            return;
        }
        app.open_launch_windows();
    }

    // GApplication opens them instead of activating, so no picker window comes with them.
    fn open(&self, files: &[gio::File], hint: &str) {
        let placement = Placement::from_hint(hint);
        match self.restore.get() {
            RestoreState::Done => self.obj().open_files(files, placement),
            // The record is read before a file's window adds to it, or
            // that write would replace the sessions still to restore.
            RestoreState::NotAttempted => {
                self.pending_files.borrow_mut().push((files.to_vec(), placement));
                self.obj().restore_session();
            }
            RestoreState::Loading => self.pending_files.borrow_mut().push((files.to_vec(), placement)),
            RestoreState::Quitting { .. } => {
                self.pending_files.borrow_mut().push((files.to_vec(), placement));
                self.restore.set(RestoreState::Quitting { relaunched: true });
            }
        }
    }

    // Opened here as GApplication would open them: a second launch then exits, and a first one runs
    // while their windows hold it. On a first launch, --new-window alone falls through to activate.
    fn handle_local_options(&self, options: &glib::VariantDict) -> ControlFlow<glib::ExitCode> {
        let new_window = options.contains(NEW_WINDOW_OPTION);
        let files = launch_files(options);
        if !new_window && files.is_empty() {
            return ControlFlow::Continue(());
        }
        let app = self.obj();
        if let Err(error) = app.register(gio::Cancellable::NONE) {
            tracing::error!(%error, "could not register with the session bus");
            return ControlFlow::Break(glib::ExitCode::FAILURE);
        }
        if !files.is_empty() {
            let placement = match new_window {
                true => Placement::NewWindow,
                false => Placement::Reuse,
            };
            app.open(&files, placement.hint());
            return ControlFlow::Break(glib::ExitCode::SUCCESS);
        }
        if app.is_remote() {
            app.activate_action("new-window", None);
            return ControlFlow::Break(glib::ExitCode::SUCCESS);
        }
        ControlFlow::Continue(())
    }

    fn shutdown(&self) {
        // The windows go with the process, which is not the user closing
        // them, so the next launch still reopens their sessions.
        if let Some(services) = self.services.get() {
            services.open_sessions().freeze_for_quit();
            // Bounded by the request timeout; without a PostHog key there is nothing to flush.
            services.telemetry().flush();
        }
        self.obj().stop_mcp();
        self.windows.clear();
        drop(self.session_signals.take());
        drop(self.quit.take());
        self.parent_shutdown();
    }
}

impl GtkApplicationImpl for TableProApplication {
    fn window_removed(&self, window: &gtk::Window) {
        let id = window
            .downcast_ref::<gtk::ApplicationWindow>()
            .map(|window| window.id());
        self.parent_window_removed(window);
        if let Some(id) = id {
            self.windows.remove(id);
        }
    }
}

impl AdwApplicationImpl for TableProApplication {}

fn launch_files(options: &glib::VariantDict) -> Vec<gio::File> {
    match options.lookup::<Vec<std::ffi::OsString>>(FILES_OPTION) {
        Ok(arguments) => arguments
            .unwrap_or_default()
            .iter()
            .map(gio::File::for_commandline_arg)
            .collect(),
        Err(error) => {
            tracing::warn!(%error, "the command line's files came in an unexpected form");
            Vec::new()
        }
    }
}
