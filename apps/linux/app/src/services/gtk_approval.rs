use std::{
    sync::{Arc, Mutex, OnceLock},
    time::Duration,
};

use async_trait::async_trait;
use tablepro_policy::{ApprovalOutcome, ApprovalRequest, ApprovalSink};

/// GTK approval sink. Posts a modal `adw::AlertDialog` on the glib main
/// context and parks the async caller until the user responds.
pub struct GtkApprovalSink;

const APPROVAL_TIMEOUT: Duration = Duration::from_secs(120);
const MAX_SQL_PREVIEW_CHARS: usize = 16_384;
static APPROVAL_DIALOG: OnceLock<Arc<tokio::sync::Semaphore>> = OnceLock::new();

const DENY_RESPONSE: &str = "deny";
const APPROVE_ONCE_RESPONSE: &str = "once";
const CLOSE_RESPONSE: &str = DENY_RESPONSE;

/// The window that actually owns the triggering connection wins over
/// whichever window last had focus, which wins over any other visible
/// window, which wins over anything still on screen at all.
fn preferred_approval_window<T>(
    registered_and_visible: Option<T>,
    active: Option<T>,
    any_visible: Option<T>,
    listed_toplevel: Option<T>,
) -> Option<T> {
    registered_and_visible.or(active).or(any_visible).or(listed_toplevel)
}

fn outcome_for_response(response: &str) -> ApprovalOutcome {
    if response == APPROVE_ONCE_RESPONSE {
        return ApprovalOutcome::AllowOnce;
    }
    ApprovalOutcome::Deny
}

fn truncate_sql(sql: &str) -> String {
    let mut chars = sql.chars();
    let preview: String = chars.by_ref().take(MAX_SQL_PREVIEW_CHARS).collect();
    if chars.next().is_some() {
        format!("{preview}\n\n… SQL truncated after {MAX_SQL_PREVIEW_CHARS} characters")
    } else {
        preview
    }
}

async fn acquire_dialog_permit(
    gate: Arc<tokio::sync::Semaphore>,
    deadline: tokio::time::Instant,
    cancellation: Option<tokio_util::sync::CancellationToken>,
) -> Option<tokio::sync::OwnedSemaphorePermit> {
    match cancellation {
        Some(cancellation) => tokio::select! {
            biased;
            _ = cancellation.cancelled() => None,
            permit = tokio::time::timeout_at(deadline, gate.acquire_owned()) => {
                permit.ok()?.ok()
            },
        },
        None => tokio::time::timeout_at(deadline, gate.acquire_owned()).await.ok()?.ok(),
    }
}

#[async_trait]
impl ApprovalSink for GtkApprovalSink {
    async fn request(&self, req: ApprovalRequest) -> ApprovalOutcome {
        // The deadline includes time spent waiting behind another dialog, so
        // a burst of agent writes cannot build an unbounded modal queue.
        let deadline = tokio::time::Instant::now() + APPROVAL_TIMEOUT;
        let gate = APPROVAL_DIALOG
            .get_or_init(|| Arc::new(tokio::sync::Semaphore::new(1)))
            .clone();
        let Some(permit) = acquire_dialog_permit(gate, deadline, req.cancellation.clone()).await else {
            return ApprovalOutcome::Deny;
        };
        let (tx, rx) = tokio::sync::oneshot::channel::<ApprovalOutcome>();
        let tx = Arc::new(Mutex::new(Some(tx)));
        let permit = Arc::new(Mutex::new(Some(permit)));

        let heading = format!("Approve write: {}", req.connection_name);
        let targets = if req.facts.tables.is_empty() {
            "(none detected)".to_string()
        } else {
            req.facts.tables.join(", ")
        };
        let mut body = format!(
            "Rule: {}\n{}\n\nPrincipal: {}\nEnvironment: {}\nClass: {:?}\nTargets: {}",
            req.rule,
            req.reason,
            req.principal.label(),
            req.environment.display_name(),
            req.facts.class,
            targets,
        );
        if let Some(preview) = &req.preview {
            body.push_str("\n\n");
            body.push_str(preview);
        }
        if let Some(rows) = req.estimated_rows {
            body.push_str(&format!("\n\nExact affected-row count: {rows}"));
        }

        let heading_c = heading.clone();
        let body_c = body.clone();
        let tx_c = tx.clone();
        let permit_c = permit.clone();
        let sql_c = truncate_sql(&req.sql);
        let cancellation = req.cancellation.clone();
        let connection_id = req.connection_id;
        glib::MainContext::default().invoke(move || {
            use relm4::adw::prelude::*;
            use relm4::{adw, gtk};

            if tokio::time::Instant::now() >= deadline {
                if let Ok(mut guard) = tx.lock()
                    && let Some(sender) = guard.take()
                {
                    let _ = sender.send(ApprovalOutcome::Deny);
                }
                if let Ok(mut permit) = permit_c.lock() {
                    permit.take();
                }
                return;
            }

            let sql_view = gtk::Label::builder()
                .label(&sql_c)
                .xalign(0.0)
                .yalign(0.0)
                .wrap(true)
                .wrap_mode(gtk::pango::WrapMode::WordChar)
                .selectable(true)
                .css_classes(["monospace"])
                .build();
            let sql_scroll = gtk::ScrolledWindow::builder()
                .min_content_height(180)
                .max_content_height(360)
                .child(&sql_view)
                .build();
            let dialog = adw::AlertDialog::builder()
                .heading(&heading_c)
                .body(&body_c)
                .extra_child(&sql_scroll)
                .build();
            dialog.add_response(DENY_RESPONSE, "Deny");
            dialog.add_response(APPROVE_ONCE_RESPONSE, "Approve once");
            dialog.set_response_appearance(DENY_RESPONSE, adw::ResponseAppearance::Destructive);
            dialog.set_response_appearance(APPROVE_ONCE_RESPONSE, adw::ResponseAppearance::Suggested);
            dialog.set_default_response(Some(DENY_RESPONSE));
            dialog.set_close_response(CLOSE_RESPONSE);

            let timer = Arc::new(Mutex::new(None::<glib::SourceId>));
            let timer_response = timer.clone();
            let permit_response = permit_c.clone();

            dialog.connect_response(None, move |_dlg, response| {
                if let Ok(mut timer) = timer_response.lock()
                    && let Some(source) = timer.take()
                {
                    source.remove();
                }
                let outcome = outcome_for_response(response);
                if let Ok(mut guard) = tx_c.lock()
                    && let Some(sender) = guard.take()
                {
                    let _ = sender.send(outcome);
                }
                if let Ok(mut permit) = permit_response.lock() {
                    permit.take();
                }
            });

            let dialog_timeout = dialog.clone();
            let tx_timeout = tx.clone();
            let permit_timeout = permit_c.clone();
            let timer_timeout = timer.clone();
            let source = glib::timeout_add_local(Duration::from_millis(50), move || {
                let cancelled = cancellation.as_ref().is_some_and(|token| token.is_cancelled());
                if !cancelled && tokio::time::Instant::now() < deadline {
                    return glib::ControlFlow::Continue;
                }
                // This source is firing; clear its ID so force_close cannot
                // try to remove the active source via the response callback.
                if let Ok(mut timer) = timer_timeout.lock() {
                    timer.take();
                }
                if let Ok(mut guard) = tx_timeout.lock()
                    && let Some(sender) = guard.take()
                {
                    let _ = sender.send(ApprovalOutcome::Deny);
                }
                dialog_timeout.force_close();
                if let Ok(mut permit) = permit_timeout.lock() {
                    permit.take();
                }
                glib::ControlFlow::Break
            });
            if let Ok(mut timer) = timer.lock() {
                *timer = Some(source);
            }

            // Prefer the window that actually owns the connection this
            // statement runs on -- active_window() answers with whatever
            // window last had focus, which in a multi-window session can
            // be a different connection than the one being approved.
            let application = gtk::Application::default();
            let window = preferred_approval_window(
                crate::services::window_registry::window_for(connection_id).filter(|window| window.is_visible()),
                application.active_window(),
                application.windows().into_iter().find(|window| window.is_visible()),
                gtk::Window::list_toplevels()
                    .into_iter()
                    .filter_map(|widget| widget.downcast::<gtk::Window>().ok())
                    .find(|window| window.is_visible()),
            );
            if let Some(window) = window {
                dialog.present(Some(&window));
                return;
            }
            if let Ok(mut timer) = timer.lock()
                && let Some(source) = timer.take()
            {
                source.remove();
            }
            if let Ok(mut guard) = tx.lock()
                && let Some(sender) = guard.take()
            {
                let _ = sender.send(ApprovalOutcome::Deny);
            }
            if let Ok(mut permit) = permit_c.lock() {
                permit.take();
            }
        });

        rx.await.unwrap_or(ApprovalOutcome::Deny)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dismissed_approval_denies() {
        assert_eq!(outcome_for_response(CLOSE_RESPONSE), ApprovalOutcome::Deny);
    }

    #[test]
    fn unexpected_approval_response_denies() {
        assert_eq!(outcome_for_response("unexpected"), ApprovalOutcome::Deny);
    }

    #[test]
    fn approve_once_response_allows_one_operation() {
        assert_eq!(outcome_for_response(APPROVE_ONCE_RESPONSE), ApprovalOutcome::AllowOnce);
    }

    #[test]
    fn approval_sql_preview_is_bounded_and_marks_truncation() {
        let sql = "x".repeat(MAX_SQL_PREVIEW_CHARS + 5);
        let preview = truncate_sql(&sql);
        assert!(preview.starts_with(&"x".repeat(MAX_SQL_PREVIEW_CHARS)));
        assert!(preview.contains("SQL truncated after 16384 characters"));
        assert_eq!(truncate_sql("short query"), "short query");
    }

    #[tokio::test(start_paused = true)]
    async fn waiting_behind_another_approval_denies_at_the_end_to_end_deadline() {
        let gate = Arc::new(tokio::sync::Semaphore::new(1));
        let active_dialog = gate.clone().acquire_owned().await.expect("active dialog permit");
        let deadline = tokio::time::Instant::now() + Duration::from_secs(120);
        let waiting = tokio::spawn(acquire_dialog_permit(gate, deadline, None));

        tokio::task::yield_now().await;
        tokio::time::advance(Duration::from_secs(120)).await;

        assert!(waiting.await.expect("approval queue waiter").is_none());
        drop(active_dialog);
    }

    #[tokio::test(start_paused = true)]
    async fn cancellation_while_waiting_for_an_approval_dialog_denies_immediately() {
        let gate = Arc::new(tokio::sync::Semaphore::new(1));
        let active_dialog = gate.clone().acquire_owned().await.expect("active dialog permit");
        let cancellation = tokio_util::sync::CancellationToken::new();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(120);
        let waiting = tokio::spawn(acquire_dialog_permit(gate, deadline, Some(cancellation.clone())));

        tokio::task::yield_now().await;
        cancellation.cancel();

        assert!(waiting.await.expect("approval queue waiter").is_none());
        drop(active_dialog);
    }

    #[test]
    fn the_connections_own_visible_window_wins_over_a_different_active_window() {
        assert_eq!(
            preferred_approval_window(Some("owner"), Some("last-focused"), Some("other"), Some("toplevel")),
            Some("owner")
        );
    }

    #[test]
    fn an_unregistered_or_hidden_connection_falls_back_to_the_active_window() {
        assert_eq!(
            preferred_approval_window(None, Some("last-focused"), Some("other"), Some("toplevel")),
            Some("last-focused")
        );
    }

    #[test]
    fn no_active_window_falls_back_to_any_other_visible_window() {
        assert_eq!(
            preferred_approval_window(None, None, Some("other"), Some("toplevel")),
            Some("other")
        );
    }

    #[test]
    fn nothing_visible_falls_back_to_a_listed_toplevel() {
        assert_eq!(
            preferred_approval_window(None, None, None, Some("toplevel")),
            Some("toplevel")
        );
    }

    #[test]
    fn no_window_anywhere_denies_by_finding_none() {
        assert_eq!(preferred_approval_window::<&str>(None, None, None, None), None);
    }
}
