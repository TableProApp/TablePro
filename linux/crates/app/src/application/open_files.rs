use gtk4::glib;
use gtk4::prelude::*;
use tablepro_session::SessionKey;

use super::{TableProApplication, WindowLaunch};
use crate::services::file_resolution::{FileTarget, ResolvedFile, resolve_file_blocking};
use crate::ui::{SessionWindow, SessionWindowInput};
use crate::workspace::saved_editor_files_blocking;

impl TableProApplication {
    /// Open each file the file manager or the command line hands over.
    /// A database opens in the window that has it open already, in the
    /// active window while it only shows the picker, or in a new window.
    /// A SQL script opens in the last window used, or in a new one.
    pub fn open_files(&self, files: &[gio::File]) {
        for file in files {
            self.open_file(file.clone());
        }
    }

    /// Finding the window that has the file open means canonicalizing
    /// its path and matching it against the saved connections, which
    /// read the disk, so the file is resolved on the spawner first.
    fn open_file(&self, file: gio::File) {
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
                    }) => app.place_script(gio::File::for_uri(&uri)),
                    resolved => app.place_file(file, resolved.as_ref().and_then(session_key)),
                }
            }
            drop(hold);
        });
    }

    fn place_file(&self, file: gio::File, key: Option<SessionKey>) {
        // The owner may show another of its sessions in front.
        let owner = key.and_then(|key| Some((self.services()?.sessions.window_for(&key)?, key)));
        if owner.is_some_and(|(owner, key)| self.present_session(owner, &key)) {
            return;
        }
        let idle = self
            .active_window()
            .and_downcast::<SessionWindow>()
            .filter(SessionWindow::is_idle);
        match idle {
            Some(window) => {
                window.send(SessionWindowInput::OpenFile(file));
                window.present();
            }
            None => {
                self.open_window(WindowLaunch::OpenFile(file));
            }
        }
    }

    // A second tab on one file would have two editors saving over each
    // other, so a tab already bound to it comes forward instead.
    fn place_script(&self, file: gio::File) {
        // GTK lists the windows most recently focused first.
        let windows: Vec<SessionWindow> = self
            .windows()
            .into_iter()
            .filter_map(|window| window.downcast::<SessionWindow>().ok())
            .collect();
        if let Some((window, tab)) = windows
            .iter()
            .find_map(|window| Some((window, window.script_tab(&file)?)))
        {
            window.send(SessionWindowInput::FocusTab(tab));
            window.present();
            return;
        }
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
                window.send(SessionWindowInput::OpenScript(file));
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
