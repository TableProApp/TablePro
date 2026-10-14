use std::cell::{Cell, OnceCell, RefCell};
use std::ops::ControlFlow;
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::subclass::prelude::*;

use super::session_signals::SessionSignals;
use super::{AppServices, WindowLaunch, WindowRegistry, install_app_actions};
use crate::workspace::CloseDecision;

pub(super) const NEW_WINDOW_OPTION: &str = "new-window";

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
    /// Files handed over while the record is read, opened after the
    /// windows it restores.
    pub(super) pending_files: RefCell<Vec<gio::File>>,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub(super) enum RestoreState {
    #[default]
    NotAttempted,
    /// The record is being read, and the windows open once it is.
    Loading,
    Done,
    /// An approved quit is writing the record. A launch meanwhile asks
    /// for it to be restored once written: read earlier, it would race
    /// the write, and the quit then empties the list it restored into.
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
    }
}

impl ApplicationImpl for TableProApplication {
    fn startup(&self) {
        self.parent_startup();
        let app = self.obj();
        install_app_actions(&app);
        if let Some(services) = self.services.get() {
            services.start();
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
        match self.restore.get() {
            RestoreState::NotAttempted => app.restore_session(),
            RestoreState::Loading => {}
            RestoreState::Quitting { .. } => self.restore.set(RestoreState::Quitting { relaunched: true }),
            RestoreState::Done => {
                app.open_window(WindowLaunch::Picker);
            }
        }
    }

    /// The files from Open With in the file manager, or from the command
    /// line. GApplication opens them instead of activating, so no picker
    /// window comes with them.
    fn open(&self, files: &[gio::File], _hint: &str) {
        match self.restore.get() {
            RestoreState::Done => self.obj().open_files(files),
            // The record is read before a file's window adds to it, or
            // that write would replace the sessions still to restore.
            RestoreState::NotAttempted => {
                self.pending_files.borrow_mut().extend_from_slice(files);
                self.obj().restore_session();
            }
            RestoreState::Loading => self.pending_files.borrow_mut().extend_from_slice(files),
            RestoreState::Quitting { .. } => {
                self.pending_files.borrow_mut().extend_from_slice(files);
                self.restore.set(RestoreState::Quitting { relaunched: true });
            }
        }
    }

    /// `--new-window` on a second launch opens the window in the running
    /// instance and exits. On the first launch it falls through to
    /// activate, which opens the one window either way.
    fn handle_local_options(&self, options: &glib::VariantDict) -> ControlFlow<glib::ExitCode> {
        if !options.contains(NEW_WINDOW_OPTION) {
            return ControlFlow::Continue(());
        }
        let app = self.obj();
        if let Err(error) = app.register(gio::Cancellable::NONE) {
            tracing::error!(%error, "could not register with the session bus");
            return ControlFlow::Break(glib::ExitCode::FAILURE);
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
        }
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
