//! The GApplication: one process per profile, the actions every window
//! shares, and the windows themselves.

mod about_dialog;
mod accelerator;
mod accelerator_scope;
mod accelerators;
mod app_actions;
mod app_services;
mod app_window_host;
mod crash_notice;
mod debug_info;
mod imp;
mod legal_section;
#[cfg(test)]
mod metainfo_release;
mod open_files;
mod quit_sequence;
mod runtime_versions;
mod session_signals;
mod shortcut_listing;
mod shortcut_owner;
mod shortcut_section;
mod third_party_licenses;
mod window_host;
mod window_launch;
mod window_registry;

use std::rc::Rc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use tablepro_session::SessionKey;

pub use accelerator::Accelerator;
pub use accelerator_scope::AcceleratorScope;
#[cfg(test)]
pub(crate) use accelerators::keypad_twins;
pub use accelerators::{
    ACCELERATORS, component_matches, component_trigger, controller_name, editor_kept_keys,
    install_application_accelerators, local_shortcut_controller, menu_item, triggers_for,
};
pub use app_actions::install_app_actions;
pub use app_services::{AppServices, AppServicesParts};
pub use app_window_host::AppWindowHost;
pub use quit_sequence::QuitSequence;
pub use shortcut_listing::ShortcutListing;
pub use shortcut_owner::ShortcutOwner;
pub use shortcut_section::ShortcutSection;
pub use window_host::WindowHost;
pub use window_launch::WindowLaunch;
pub(crate) use window_registry::WindowRegistry;

use crate::config;
use crate::ui::{SessionWindow, SessionWindowInit};
use crate::workspace::OpenSessionsLoad;

glib::wrapper! {
    pub struct TableProApplication(ObjectSubclass<imp::TableProApplication>)
        @extends adw::Application, gtk::Application, gio::Application,
        @implements gio::ActionGroup, gio::ActionMap;
}

impl TableProApplication {
    pub fn new(services: AppServices) -> Self {
        // GApplication answers --version from this, before it registers
        // on the bus, so the running instance never sees the call.
        let app: Self = glib::Object::builder()
            .property("application-id", config::APP_ID)
            .property("resource-base-path", config::RESOURCE_BASE_PATH)
            .property("flags", gio::ApplicationFlags::HANDLES_OPEN)
            .property("version", config::VERSION)
            .build();
        services.bind_application(&app);
        // Only `new` sets it, and it has just built the object.
        let _ = app.imp().services.set(Rc::new(services));
        app
    }

    /// `None` only for an application built without `new`.
    pub fn services(&self) -> Option<Rc<AppServices>> {
        self.imp().services.get().cloned()
    }

    /// Open a window on `launch` and show it. `None` when the
    /// application has not started yet, since GTK takes windows only
    /// after startup.
    pub fn open_window(&self, launch: WindowLaunch) -> Option<adw::ApplicationWindow> {
        let Some(services) = self.services() else {
            tracing::warn!("no window opened: the application has no services");
            return None;
        };
        let window = SessionWindow::new();
        // The window gets its id when it is added, and it claims its
        // session under that id from start on.
        self.add_window(&window);
        if window.application().is_none() {
            tracing::warn!("no window opened: the application has not started");
            window.destroy();
            return None;
        }
        let host: Rc<dyn WindowHost> = Rc::new(AppWindowHost::new(self));
        self.imp().windows.insert(window.id(), window.clone());
        window.start(SessionWindowInit { services, host, launch });
        self.hand_over_crash_report(&window);
        window.present();
        Some(window.upcast())
    }

    /// False when no window has that id.
    pub fn present_window(&self, window_id: u32) -> bool {
        let Some(window) = self.window_by_id(window_id) else {
            return false;
        };
        window.present();
        true
    }

    /// What activate and the new-window action open: the sessions open
    /// at the last quit the first time, a picker after. A picker opened
    /// first would write its session over the ones still to reopen.
    fn open_launch_windows(&self) {
        let imp = self.imp();
        match imp.restore.get() {
            imp::RestoreState::NotAttempted => self.restore_session(),
            imp::RestoreState::Loading => {}
            imp::RestoreState::Quitting { .. } => imp.restore.set(imp::RestoreState::Quitting { relaunched: true }),
            imp::RestoreState::Done => {
                self.open_window(WindowLaunch::Picker);
            }
        }
    }

    /// Open the windows whose sessions were open when the application
    /// last quit, then any files handed over meanwhile, or the picker
    /// when that opens nothing.
    fn restore_session(&self) {
        let imp = self.imp();
        let services = match self.services() {
            Some(services) if services.settings.restore_session() => services,
            _ => {
                imp.restore.set(imp::RestoreState::Done);
                self.finish_restore(Vec::new());
                return;
            }
        };
        imp.restore.set(imp::RestoreState::Loading);
        // No window holds the application while the record is read.
        let hold = services.hold().acquire();
        let loading = services.open_sessions().load();
        let app = self.clone();
        let restoring = glib::spawn_future_local(async move {
            let loaded = loading.await;
            // A quit approved during the read leaves the record for the
            // next launch and opens nothing.
            if app.imp().restore.get() == imp::RestoreState::Loading {
                let keys = match loaded {
                    OpenSessionsLoad::Restored(record) => services.open_sessions().restore(record),
                    OpenSessionsLoad::Empty => Vec::new(),
                };
                app.imp().restore.set(imp::RestoreState::Done);
                app.finish_restore(keys);
            }
            drop(hold);
        });
        imp.restoring.replace(Some(restoring));
    }

    fn finish_restore(&self, keys: Vec<SessionKey>) {
        let files = self.imp().pending_files.take();
        if keys.is_empty() && files.is_empty() {
            self.open_window(WindowLaunch::Picker);
        }
        for key in keys {
            self.open_window(WindowLaunch::Restore(key));
        }
        self.open_files(&files);
    }

    /// Ask every window to close, in turn. While one is asking, another
    /// request brings that window forward instead of starting over.
    pub fn request_quit(&self) {
        let imp = self.imp();
        if imp.quit.borrow().is_some() {
            if let Some(asking) = imp.quit_asking.get() {
                self.present_window(asking);
            }
            return;
        }
        let app = self.clone();
        let running = glib::spawn_future_local(async move {
            let decision = QuitSequence::run(app.clone()).await;
            app.imp().quit.take();
            decision
        });
        imp.quit.replace(Some(running));
    }

    /// Bring forward the first window that holds the session back, so
    /// the user sees what a logout would lose. Returns its id.
    pub(crate) fn present_inhibiting_window(&self) -> Option<u32> {
        let imp = self.imp();
        let window = self
            .windows()
            .into_iter()
            .filter_map(|window| window.downcast::<gtk::ApplicationWindow>().ok())
            .find(|window| imp.windows.holds_inhibit(window.id()))?;
        window.present();
        Some(window.id())
    }
}

#[cfg(test)]
mod tests;
