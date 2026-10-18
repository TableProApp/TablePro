use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;

use super::notification_request::NotificationRequest;
use super::notification_sink::NotificationSink;

/// The application's own notifications, which the desktop shows under
/// its name and icon. Clicking one runs `app.focus-tab`.
pub(crate) struct ApplicationNotificationSink {
    /// The application owns its windows, and so this.
    app: glib::WeakRef<gtk::Application>,
}

impl ApplicationNotificationSink {
    pub(crate) fn new(app: &gtk::Application) -> Self {
        Self { app: app.downgrade() }
    }
}

impl NotificationSink for ApplicationNotificationSink {
    fn send(&self, request: &NotificationRequest) {
        let Some(app) = self.app.upgrade() else {
            return;
        };
        let notification = gio::Notification::new(&request.title);
        notification.set_body(Some(&request.body));
        notification.set_default_action_and_target_value(
            "app.focus-tab",
            Some(&(request.window_id, request.tab.to_string()).to_variant()),
        );
        app.send_notification(Some(&request.id), &notification);
    }

    fn withdraw(&self, id: &str) {
        if let Some(app) = self.app.upgrade() {
            app.withdraw_notification(id);
        }
    }
}
