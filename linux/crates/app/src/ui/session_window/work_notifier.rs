use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use uuid::Uuid;

use super::notification_request::notification_request;
use super::notification_sink::NotificationSink;
use crate::workspace::CompletedWork;

/// A window's notifications about work that ended in a tab the user was
/// not looking at, as GNOME Console sends them: no time threshold, one
/// per tab, withdrawn once the user looks at the tab.
pub(crate) struct WorkNotifier {
    window_id: u32,
    sink: Rc<dyn NotificationSink>,
    /// The id of each tab's notification on screen.
    sent: RefCell<HashMap<Uuid, String>>,
}

impl WorkNotifier {
    pub(crate) fn new(window_id: u32, sink: Rc<dyn NotificationSink>) -> Self {
        Self {
            window_id,
            sink,
            sent: RefCell::default(),
        }
    }

    /// `tab_active` when the window is the active one and the tab is in
    /// front: the user saw it end.
    pub(crate) fn work_completed(
        &self,
        work: &CompletedWork,
        tab_active: bool,
        tab_label: &str,
        connection_name: &str,
    ) {
        if tab_active {
            return;
        }
        let Some(request) = notification_request(self.window_id, work, tab_label, connection_name) else {
            return;
        };
        self.sink.send(&request);
        self.sent.borrow_mut().insert(request.tab, request.id);
    }

    pub(crate) fn has_sent(&self) -> bool {
        !self.sent.borrow().is_empty()
    }

    pub(crate) fn tab_became_active(&self, tab: Uuid) {
        let sent = self.sent.borrow_mut().remove(&tab);
        if let Some(id) = sent {
            self.sink.withdraw(&id);
        }
    }

    /// Withdraw the notifications of tabs that closed: there is nothing
    /// left for them to bring forward.
    pub(crate) fn withdraw_closed(&self, is_open: impl Fn(Uuid) -> bool) {
        let closed: Vec<String> = {
            let mut sent = self.sent.borrow_mut();
            let tabs: Vec<Uuid> = sent.keys().copied().filter(|tab| !is_open(*tab)).collect();
            tabs.iter().filter_map(|tab| sent.remove(tab)).collect()
        };
        for id in closed {
            self.sink.withdraw(&id);
        }
    }

    pub(crate) fn withdraw_all(&self) {
        let sent = std::mem::take(&mut *self.sent.borrow_mut());
        for id in sent.into_values() {
            self.sink.withdraw(&id);
        }
    }
}

impl std::fmt::Debug for WorkNotifier {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WorkNotifier")
            .field("window_id", &self.window_id)
            .field("sent", &self.sent.borrow().len())
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::ui::session_window::notification_request::NotificationRequest;
    use crate::workspace::{WorkKind, WorkOutcome};

    #[derive(Debug, Clone, PartialEq, Eq)]
    pub(crate) enum Notice {
        Sent(NotificationRequest),
        Withdrawn(String),
    }

    /// Keeps what a window sent and withdrew, in order.
    #[derive(Debug, Default)]
    pub(crate) struct RecordingNotificationSink {
        notices: RefCell<Vec<Notice>>,
    }

    impl RecordingNotificationSink {
        pub(crate) fn notices(&self) -> Vec<Notice> {
            self.notices.borrow().clone()
        }

        pub(crate) fn sent(&self) -> Vec<NotificationRequest> {
            self.notices
                .borrow()
                .iter()
                .filter_map(|notice| match notice {
                    Notice::Sent(request) => Some(request.clone()),
                    Notice::Withdrawn(_) => None,
                })
                .collect()
        }

        pub(crate) fn withdrawn(&self) -> Vec<String> {
            self.notices
                .borrow()
                .iter()
                .filter_map(|notice| match notice {
                    Notice::Withdrawn(id) => Some(id.clone()),
                    Notice::Sent(_) => None,
                })
                .collect()
        }
    }

    impl NotificationSink for RecordingNotificationSink {
        fn send(&self, request: &NotificationRequest) {
            self.notices.borrow_mut().push(Notice::Sent(request.clone()));
        }

        fn withdraw(&self, id: &str) {
            self.notices.borrow_mut().push(Notice::Withdrawn(id.to_owned()));
        }
    }

    fn finished(tab: Uuid) -> CompletedWork {
        CompletedWork {
            tab,
            kind: WorkKind::Export,
            outcome: WorkOutcome::Succeeded,
        }
    }

    fn notifier() -> (WorkNotifier, Rc<RecordingNotificationSink>) {
        let sink = Rc::new(RecordingNotificationSink::default());
        (WorkNotifier::new(9, sink.clone()), sink)
    }

    #[test]
    fn a_tab_withdrawn_once_is_not_withdrawn_again() {
        let (notifier, sink) = notifier();
        let tab = Uuid::new_v4();

        notifier.tab_became_active(tab);
        notifier.work_completed(&finished(tab), false, "orders", "Prod");
        notifier.tab_became_active(tab);
        notifier.tab_became_active(tab);
        notifier.withdraw_all();

        assert_eq!(sink.sent().len(), 1);
        assert_eq!(sink.withdrawn(), [format!("work-finished-9-{tab}")]);
    }

    #[test]
    fn only_closed_tabs_lose_their_notification() {
        let (notifier, sink) = notifier();
        let (open, closed) = (Uuid::new_v4(), Uuid::new_v4());
        notifier.work_completed(&finished(open), false, "orders", "Prod");
        notifier.work_completed(&finished(closed), false, "users", "Prod");

        notifier.withdraw_closed(|tab| tab == open);

        assert_eq!(sink.withdrawn(), [format!("work-finished-9-{closed}")]);
        notifier.withdraw_all();
        assert_eq!(sink.withdrawn().last(), Some(&format!("work-finished-9-{open}")));
    }
}
