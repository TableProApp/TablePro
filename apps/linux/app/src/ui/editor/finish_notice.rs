use std::time::Duration;

use relm4::gtk;
use relm4::gtk::gio;
use relm4::gtk::prelude::*;

const NOTICE_AFTER: Duration = Duration::from_secs(10);

pub(super) fn should_notify(elapsed: Duration, window_active: bool) -> bool {
    !window_active && elapsed >= NOTICE_AFTER
}

pub(super) fn notify_if_unattended(widget: &impl IsA<gtk::Widget>, elapsed: Duration) {
    let Some(window) = widget.root().and_downcast::<gtk::Window>() else {
        return;
    };
    if !should_notify(elapsed, window.is_active()) {
        return;
    }
    let Some(application) = window.application() else {
        return;
    };
    let notification = gio::Notification::new(&crate::tr!("Query finished"));
    notification.set_body(Some(
        &crate::tr!("The query ran for {seconds} seconds.").replace("{seconds}", &elapsed.as_secs().to_string()),
    ));
    application.send_notification(Some("query-finished"), &notification);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_long_run_in_an_inactive_window_raises_a_notice() {
        assert!(should_notify(Duration::from_secs(12), false));
        assert!(!should_notify(Duration::from_secs(12), true));
        assert!(!should_notify(Duration::from_secs(3), false));
    }
}
