//! The GApplication: one process per profile, the actions every window
//! shares, and the windows themselves.

mod app_actions;
mod app_services;
mod app_window_host;
mod imp;
mod quit_sequence;
mod session_signals;
mod window_host;
mod window_launch;
mod window_registry;

use std::rc::Rc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;

pub use app_actions::{APP_ACCELS, install_app_actions};
pub use app_services::{AppServices, AppServicesParts};
pub use app_window_host::AppWindowHost;
pub use quit_sequence::QuitSequence;
pub use window_host::WindowHost;
pub use window_launch::WindowLaunch;
pub(crate) use window_registry::WindowRegistry;

use crate::config;
use crate::ui::{SessionWindow, SessionWindowInit};

glib::wrapper! {
    pub struct TableProApplication(ObjectSubclass<imp::TableProApplication>)
        @extends adw::Application, gtk::Application, gio::Application,
        @implements gio::ActionGroup, gio::ActionMap;
}

impl TableProApplication {
    pub fn new(services: AppServices) -> Self {
        let app: Self = glib::Object::builder()
            .property("application-id", config::APP_ID)
            .property("resource-base-path", config::RESOURCE_BASE_PATH)
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
