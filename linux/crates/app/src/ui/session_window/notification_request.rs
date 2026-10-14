use uuid::Uuid;

use crate::workspace::{CompletedWork, WorkKind, WorkOutcome};

/// A desktop notification about one tab's finished work.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct NotificationRequest {
    pub id: String,
    pub title: String,
    pub body: String,
    pub window_id: u32,
    pub tab: Uuid,
}

/// The notification for `work`, or `None` for work the user stopped.
///
/// A notification can show on the lock screen, so it names the tab and
/// the connection and nothing else: no SQL, no rows, no error text.
pub(crate) fn notification_request(
    window_id: u32,
    work: &CompletedWork,
    tab_label: &str,
    connection_name: &str,
) -> Option<NotificationRequest> {
    let title = match (work.kind, work.outcome) {
        (_, WorkOutcome::Cancelled) => return None,
        (WorkKind::Query, WorkOutcome::Succeeded) => crate::i18n::gettext("Query Finished"),
        (WorkKind::Query, WorkOutcome::Failed) => crate::i18n::gettext("Query Failed"),
        (WorkKind::Save, WorkOutcome::Succeeded) => crate::i18n::gettext("Changes Saved"),
        (WorkKind::Save, WorkOutcome::Failed) => crate::i18n::gettext("Changes Not Saved"),
        (WorkKind::Export, WorkOutcome::Succeeded) => crate::i18n::gettext("Export Finished"),
        (WorkKind::Export, WorkOutcome::Failed) => crate::i18n::gettext("Export Failed"),
    };
    let body = match connection_name.is_empty() {
        true => tab_label.to_owned(),
        false => crate::i18n::gettext_f(
            "{tab} · {connection}",
            &[("tab", tab_label), ("connection", connection_name)],
        ),
    };
    Some(NotificationRequest {
        id: notification_id(window_id, work.tab),
        title,
        body,
        window_id,
        tab: work.tab,
    })
}

/// One per tab, so a newer notification replaces the tab's last one.
fn notification_id(window_id: u32, tab: Uuid) -> String {
    format!("work-finished-{window_id}-{tab}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn work(kind: WorkKind, outcome: WorkOutcome) -> CompletedWork {
        CompletedWork {
            tab: Uuid::from_u128(7),
            kind,
            outcome,
        }
    }

    #[test]
    fn notification_id_is_stable_per_window_and_tab() {
        let (tab, other) = (Uuid::new_v4(), Uuid::new_v4());
        let id = |window_id, tab| {
            let work = CompletedWork {
                tab,
                kind: WorkKind::Query,
                outcome: WorkOutcome::Succeeded,
            };
            notification_request(window_id, &work, "orders", "Prod")
                .expect("a request")
                .id
        };

        assert_eq!(id(3, tab), id(3, tab));
        assert_eq!(id(3, tab), format!("work-finished-3-{tab}"));
        assert_ne!(id(3, tab), id(4, tab));
        assert_ne!(id(3, tab), id(3, other));
        let request =
            notification_request(3, &work(WorkKind::Export, WorkOutcome::Failed), "orders", "Prod").expect("a request");
        assert_eq!((request.window_id, request.tab), (3, Uuid::from_u128(7)));
    }

    #[test]
    fn cancelled_work_produces_no_request() {
        for kind in [WorkKind::Query, WorkKind::Save, WorkKind::Export] {
            assert_eq!(
                notification_request(1, &work(kind, WorkOutcome::Cancelled), "orders", "Prod"),
                None,
                "{kind:?}"
            );
        }
    }

    #[test]
    fn request_body_contains_no_sql_or_error_text() {
        let request =
            notification_request(1, &work(WorkKind::Query, WorkOutcome::Failed), "Query 2", "Prod").expect("a request");

        assert_eq!(request.body, "Query 2 · Prod");
        assert_eq!(request.title, "Query Failed");
        assert_eq!(
            notification_request(1, &work(WorkKind::Save, WorkOutcome::Succeeded), "orders", "")
                .expect("a request")
                .body,
            "orders",
            "a missing connection name left a dangling separator"
        );
    }

    #[test]
    fn titles_per_kind_and_outcome() {
        let title = |kind, outcome| {
            notification_request(1, &work(kind, outcome), "orders", "Prod")
                .expect("a request")
                .title
        };

        assert_eq!(title(WorkKind::Query, WorkOutcome::Succeeded), "Query Finished");
        assert_eq!(title(WorkKind::Query, WorkOutcome::Failed), "Query Failed");
        assert_eq!(title(WorkKind::Save, WorkOutcome::Succeeded), "Changes Saved");
        assert_eq!(title(WorkKind::Save, WorkOutcome::Failed), "Changes Not Saved");
        assert_eq!(title(WorkKind::Export, WorkOutcome::Succeeded), "Export Finished");
        assert_eq!(title(WorkKind::Export, WorkOutcome::Failed), "Export Failed");
    }
}
