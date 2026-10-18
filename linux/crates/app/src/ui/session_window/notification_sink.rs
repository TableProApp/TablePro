use super::notification_request::NotificationRequest;

/// Where a window's notifications go: the desktop, or a test's record.
pub(crate) trait NotificationSink {
    /// Show `request`, replacing the one with its id.
    fn send(&self, request: &NotificationRequest);
    fn withdraw(&self, id: &str);
}
