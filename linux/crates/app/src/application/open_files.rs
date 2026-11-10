use gtk4::glib;
use gtk4::prelude::*;
use tablepro_session::SessionKey;

use super::{TableProApplication, WindowLaunch};
use crate::services::connection_link;
use crate::services::file_resolution::{FileTarget, ResolvedFile, resolve_file_blocking};
use crate::ui::{ScriptInput, SessionWindow, SessionWindowInput};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Placement {
    Reuse,
    // A database a window already has still comes forward there: one session has one window.
    NewWindow,
}

impl Placement {
    // The open hint a second launch with --new-window sends.
    pub const NEW_WINDOW_HINT: &'static str = "new-window";

    pub fn from_hint(hint: &str) -> Self {
        match hint {
            Self::NEW_WINDOW_HINT => Self::NewWindow,
            _ => Self::Reuse,
        }
    }

    pub fn hint(self) -> &'static str {
        match self {
            Self::Reuse => "",
            Self::NewWindow => Self::NEW_WINDOW_HINT,
        }
    }
}

impl TableProApplication {
    pub fn open_files(&self, files: &[gio::File], placement: Placement) {
        for file in files {
            // A link names no file, and file resolution would show its text, password and all.
            match connection_link::link_text(file) {
                Some(link) => self.open_link(&link, placement),
                None => self.open_file(file.clone(), placement),
            }
        }
    }

    // Matching the file to a window reads the disk, so it resolves on the blocking pool first.
    fn open_file(&self, file: gio::File, placement: Placement) {
        let Some(services) = self.services() else {
            tracing::warn!("no file opened: the application has no services");
            return;
        };
        let (path, uri) = (file.path(), file.uri().to_string());
        let connections = services.storage.connections().clone();
        let drivers = services.drivers.clone();
        let resolving = services
            .tasks
            .spawn_blocking_task(move || resolve_file_blocking(path, uri, &connections, &drivers));
        // An instance D-Bus started for this file would otherwise exit
        // before its window opens.
        let hold = self.hold();
        let app = self.downgrade();
        glib::spawn_future_local(async move {
            let resolved = resolving.await.ok();
            if let Some(app) = app.upgrade() {
                match resolved {
                    Some(ResolvedFile {
                        uri,
                        target: Ok(FileTarget::Script),
                    }) => app.place_script(gio::File::for_uri(&uri), placement),
                    resolved => app.place_file(file, resolved.as_ref().and_then(session_key), placement),
                }
            }
            drop(hold);
        });
    }

    fn place_file(&self, file: gio::File, key: Option<SessionKey>, placement: Placement) {
        // The owner may show another of its sessions in front.
        let owner = key.and_then(|key| Some((self.services()?.sessions.window_for(&key)?, key)));
        if owner.is_some_and(|(owner, key)| self.present_session(owner, &key)) {
            return;
        }
        match self.idle_window(placement) {
            Some(window) => {
                window.send(SessionWindowInput::OpenFile(file));
                window.present();
            }
            None => {
                self.open_window(WindowLaunch::OpenFile(file));
            }
        }
    }

    pub(super) fn idle_window(&self, placement: Placement) -> Option<SessionWindow> {
        if placement == Placement::NewWindow {
            return None;
        }
        self.active_window()
            .and_downcast::<SessionWindow>()
            .filter(SessionWindow::is_idle)
    }

    // A second tab on one file would have two editors saving over each
    // other, so a tab already bound to it comes forward instead.
    fn place_script(&self, file: gio::File, placement: Placement) {
        if SessionWindow::focus_tab_bound_to(self, &file) {
            return;
        }
        if placement == Placement::NewWindow {
            return self.route_script(Vec::new(), file);
        }
        // GTK lists the windows most recently focused first.
        let windows: Vec<SessionWindow> = self
            .windows()
            .into_iter()
            .filter_map(|window| window.downcast::<SessionWindow>().ok())
            .collect();
        // While any window settles, a tab bound to the file may still appear, so a picker asks rather
        // than opening a second one beside it.
        if windows.iter().any(SessionWindow::settling) {
            let idle = windows.into_iter().next().filter(SessionWindow::is_idle);
            return self.route_script(idle.into_iter().collect(), file);
        }
        self.route_script(windows, file);
    }

    fn route_script(&self, windows: Vec<SessionWindow>, file: gio::File) {
        let window = match windows.into_iter().next() {
            Some(window) => Some(window),
            None => self.open_window(WindowLaunch::Picker).and_downcast::<SessionWindow>(),
        };
        match window {
            Some(window) => {
                window.send(SessionWindowInput::Script(ScriptInput::Open(file)));
                window.present();
            }
            None => tracing::warn!("no window to open a SQL file in"),
        }
    }
}

/// The session a resolved file opens, so its window can be found.
fn session_key(resolved: &ResolvedFile) -> Option<SessionKey> {
    match &resolved.target {
        Ok(FileTarget::Saved(saved)) => Some(SessionKey::Saved(saved.id)),
        Ok(FileTarget::File(identity)) => Some(SessionKey::File(identity.uri.clone())),
        Ok(FileTarget::Script) | Err(_) => None,
    }
}
