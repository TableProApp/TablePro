use gtk4::glib;
use gtk4::prelude::*;
use tablepro_session::SessionKey;

use super::{TableProApplication, WindowLaunch};
use crate::services::file_resolution::{FileTarget, ResolvedFile, resolve_file_blocking};
use crate::ui::{SessionWindow, SessionWindowInput};

impl TableProApplication {
    /// Open each file the file manager or the command line hands over:
    /// in the window that has it open already, in the active window
    /// while it only shows the picker, or in a new window.
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
        let resolving = services
            .tasks
            .spawn_blocking_task(move || resolve_file_blocking(path, uri, &connections));
        // An instance D-Bus started for this file would otherwise exit
        // before its window opens.
        let hold = self.hold();
        let app = self.downgrade();
        glib::spawn_future_local(async move {
            let key = resolving.await.ok().and_then(|resolved| session_key(&resolved));
            if let Some(app) = app.upgrade() {
                app.place_file(file, key);
            }
            drop(hold);
        });
    }

    fn place_file(&self, file: gio::File, key: Option<SessionKey>) {
        let owner = key.and_then(|key| self.services()?.sessions.window_for(&key));
        if owner.is_some_and(|owner| self.present_window(owner)) {
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
}

/// The session a resolved file opens, so its window can be found.
fn session_key(resolved: &ResolvedFile) -> Option<SessionKey> {
    match &resolved.target {
        Ok(FileTarget::Saved(saved)) => Some(SessionKey::Saved(saved.id)),
        Ok(FileTarget::File(identity)) => Some(SessionKey::File(identity.uri.clone())),
        Err(_) => None,
    }
}
