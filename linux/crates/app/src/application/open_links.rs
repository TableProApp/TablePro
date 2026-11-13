use gtk4::glib;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::connection_url::{self, ConnectionUrl};
use tablepro_session::SessionKey;
use tablepro_storage::SavedConnection;

use super::open_files::Placement;
use super::{TableProApplication, WindowLaunch};
use crate::services::connection_link::{LinkTarget, saved_for_link_blocking};
use crate::ui::{SessionWindow, SessionWindowInput};

pub(super) const CANCEL: &str = "cancel";
pub(super) const OPEN: &str = "open";

impl TableProApplication {
    // A link never connects on its own, and its text, which may hold a password, is never logged or shown.
    pub(super) fn open_link(&self, text: &str, placement: Placement) {
        let Some(services) = self.services() else {
            tracing::warn!("no link opened: the application has no services");
            return;
        };
        let url = match connection_url::parse(text) {
            Ok(url) => url,
            Err(error) => {
                tracing::warn!(code = error.code(), "could not read a connection link");
                if let Some(window) = self.link_window(placement) {
                    let message = crate::ui::error_text::connection_url_message(&error);
                    window.send(SessionWindowInput::ShowToast(message));
                    window.present();
                }
                return;
            }
        };
        let Some(driver) = services.drivers.get(url.driver_id) else {
            // The connect dialog says no driver here opens it.
            return self.connect_from_link(url, placement);
        };
        let target = LinkTarget::new(&url, driver.capabilities(), &glib::user_name().to_string_lossy());
        let connections = services.storage.connections().clone();
        let finding = services
            .tasks
            .spawn_blocking_task(move || saved_for_link_blocking(&target, &connections));
        // An instance D-Bus started for this link would otherwise exit
        // before its window opens.
        let hold = self.hold();
        let app = self.downgrade();
        glib::spawn_future_local(async move {
            let saved = finding.await.ok().flatten();
            if let Some(app) = app.upgrade() {
                match saved {
                    Some(saved) => app.confirm_saved_link(saved, placement).await,
                    None => app.connect_from_link(url, placement),
                }
            }
            drop(hold);
        });
    }

    fn connect_from_link(&self, url: ConnectionUrl, placement: Placement) {
        let Some(window) = self.link_window(placement) else {
            tracing::warn!("no window to open a connection link in");
            return;
        };
        window.send(SessionWindowInput::ConnectFromLink(Box::new(url)));
        window.present();
    }

    async fn confirm_saved_link(&self, saved: SavedConnection, placement: Placement) {
        // A launch for the link has no window yet, and the question needs one under it.
        let (parent, opened_for_link) = match self.active_window().and_downcast::<SessionWindow>() {
            Some(window) => (window, false),
            None => match self.open_window(WindowLaunch::Picker).and_downcast::<SessionWindow>() {
                Some(window) => (window, true),
                None => return,
            },
        };
        let dialog = saved_link_dialog(&saved.name);
        let answer = crate::workspace::respond(&dialog, parent.upcast_ref()).await;
        if answer != OPEN {
            return;
        }
        let key = SessionKey::Saved(saved.id);
        if let Some(owner) = self.services().and_then(|services| services.sessions.window_for(&key))
            && self.present_session(owner, &key)
        {
            return;
        }
        let window = match opened_for_link && parent.is_idle() {
            true => Some(parent),
            false => self.idle_window(placement),
        };
        match window {
            Some(window) => {
                window.send(SessionWindowInput::OpenSaved(Box::new(saved)));
                window.present();
            }
            None => {
                self.open_window(WindowLaunch::Connect(Box::new(saved)));
            }
        }
    }

    pub(super) fn link_window(&self, placement: Placement) -> Option<SessionWindow> {
        self.idle_window(placement)
            .or_else(|| self.open_window(WindowLaunch::Picker).and_downcast::<SessionWindow>())
    }
}

// Cancel is the default and the close response: a link can come from any web page.
pub(super) fn saved_link_dialog(name: &str) -> adw::AlertDialog {
    let dialog = adw::AlertDialog::new(
        Some(&crate::i18n::gettext_f("Open “{connection}”?", &[("connection", name)])),
        Some(&crate::i18n::gettext(
            "A link asks TablePro to open this saved connection. Open it only if you trust where the link came from.",
        )),
    );
    // A connection name is never markup.
    dialog.set_heading_use_markup(false);
    dialog.set_body_use_markup(false);
    dialog.add_response(CANCEL, &crate::i18n::gettext("_Cancel"));
    dialog.add_response(OPEN, &crate::i18n::gettext("_Open"));
    dialog.set_response_appearance(OPEN, adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some(CANCEL));
    dialog.set_close_response(CANCEL);
    dialog
}
