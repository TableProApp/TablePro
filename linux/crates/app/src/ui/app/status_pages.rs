use relm4::adw::prelude::*;
use relm4::{ComponentController, ComponentSender, adw, gtk};

use super::{App, AppMsg, UndoBatch, build_shortcuts_window};

impl App {
    pub(super) fn show_welcome_page(&self, _sender: ComponentSender<Self>) {
        // Welcome lives outside the ViewStack — it's the disconnected mode.
        // The ViewSwitcherBar is hidden via on_disconnect so the welcome
        // view occupies the full toolbar surface.
        self.content_holder.set_content(Some(self.welcome_view.widget()));
    }

    /// Used during connect to convey "Connecting…" — surfaces as a toast
    /// since the welcome view is still visible. Per-tab loading/error
    /// states live inside BrowseTab now (replace_status_child there).
    pub(super) fn set_loading_page(&self, title: &str, description: &str) {
        let _ = description;
        self.show_toast(title);
    }

    /// Convenience for `set_status_page(Error, ...)` and similar; in the
    /// connected state, browse-tab errors flow through BrowseTabInput::ShowError.
    /// Used here only for app-level (non-tab-scoped) failures — surfaces
    /// as an alert dialog so the user actually notices.
    pub(super) fn set_status_page(&self, _kind: super::StatusKind, title: &str, description: &str) {
        self.show_error_alert(title, description);
    }

    pub(super) fn show_toast(&self, msg: &str) {
        self.toast_overlay.add_toast(adw::Toast::new(msg));
    }

    pub(super) fn show_undoable_toast(&self, msg: &str, batch: UndoBatch, sender: ComponentSender<Self>) {
        let toast = adw::Toast::builder()
            .title(msg)
            .timeout(10)
            .button_label(crate::tr!("Undo"))
            .build();
        let s = sender;
        let batch_clone = batch;
        toast.connect_button_clicked(move |t| {
            s.input(AppMsg::ExecuteUndo(batch_clone.clone()));
            t.dismiss();
        });
        self.toast_overlay.add_toast(toast);
    }

    pub(super) fn show_error_alert(&self, title: &str, message: &str) {
        let dialog = adw::AlertDialog::new(Some(title), Some(message));
        dialog.add_response("ok", "OK");
        dialog.set_default_response(Some("ok"));
        dialog.set_close_response("ok");
        dialog.present(Some(&self.window));
    }

    /// Context-sensitive Ctrl+W: closes the active tab in whichever
    /// ViewStack page is visible (Browse or Editor). Falls back to
    /// closing the window when neither has tabs.
    pub(super) fn on_close_current(&mut self, sender: ComponentSender<Self>) {
        match self.view_stack.visible_child_name().as_deref() {
            Some("editor") => self.close_active_editor_tab(sender),
            Some("browse") if !self.browse_tabs.borrow().is_empty() => self.close_active_browse_tab(sender),
            _ => self.window.close(),
        }
    }

    pub(super) fn on_show_shortcuts(&self) {
        build_shortcuts_window(&self.window).present();
    }

    pub(super) fn on_show_about(&self) {
        let dialog = adw::AboutDialog::builder()
            .application_name(crate::tr!("TablePro"))
            .application_icon("com.tablepro.linux")
            .developer_name(crate::tr!("TablePro Authors"))
            .version(env!("CARGO_PKG_VERSION"))
            .website("https://github.com/TableProApp/TablePro")
            .issue_url("https://github.com/TableProApp/TablePro/issues")
            .support_url("https://github.com/TableProApp/TablePro/discussions")
            .copyright(crate::tr!("© 2025–2026 TablePro Authors"))
            .license_type(gtk::License::Agpl30)
            .comments(crate::tr!(
                "A native Linux database client built with GTK4 + libadwaita."
            ))
            .build();
        dialog.set_developers(&["TablePro Authors https://github.com/TableProApp/TablePro"]);
        dialog.set_translator_credits(&crate::tr!("translator-credits"));
        dialog.present(Some(&self.window));
    }
}
