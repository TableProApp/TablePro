use std::time::Duration;

use relm4::adw;
use relm4::adw::prelude::*;
use relm4::{ComponentController, ComponentSender};
use uuid::Uuid;

use crate::ui::editor::SqlEditorInput;

use super::{App, AppMsg, SessionTeardownAction, WorkspaceTab};

const SESSION_CLOSE_TIMEOUT: Duration = Duration::from_secs(20);
const WINDOW_CLOSE_TIMEOUT: Duration = Duration::from_secs(5);

async fn await_editor_sessions(
    action: SessionTeardownAction,
    replies: Vec<(Uuid, tokio::sync::oneshot::Receiver<Result<(), String>>)>,
) -> Result<(), String> {
    let cleanup = async {
        let mut pending = tokio::task::JoinSet::new();
        for (id, reply) in replies {
            pending.spawn(async move { (id, reply.await) });
        }
        let mut failures = Vec::new();
        while let Some(result) = pending.join_next().await {
            match result {
                Ok((_, Ok(Ok(())))) => {}
                Ok((id, Ok(Err(message)))) => failures.push(format!("Editor {id}: {message}")),
                Ok((id, Err(_))) => failures.push(format!("Editor {id} closed before cleanup completed.")),
                Err(error) => failures.push(format!("Editor cleanup task failed: {error}")),
            }
        }
        if failures.is_empty() {
            Ok(())
        } else {
            Err(failures.join("\n"))
        }
    };
    let timeout = match action {
        SessionTeardownAction::WindowClose => WINDOW_CLOSE_TIMEOUT,
        _ => SESSION_CLOSE_TIMEOUT,
    };
    match tokio::time::timeout(timeout, cleanup).await {
        Err(_) => Err("Timed out waiting for editor sessions to finish cleanup.".to_string()),
        Ok(result) => result,
    }
}

fn close_anyway_dialog(message: &str, on_close_anyway: impl Fn() + 'static) -> adw::AlertDialog {
    let body = crate::tr!(
        "{message}\n\nIf you close anyway, the database rolls back any transaction that was not committed when its connection drops."
    )
    .replace("{message}", message);
    let dialog = adw::AlertDialog::new(Some(&crate::tr!("Could not close database sessions")), Some(&body));
    dialog.add_response("keep", &crate::tr!("Keep Open"));
    dialog.add_response("close-anyway", &crate::tr!("Close Anyway"));
    dialog.set_response_appearance("close-anyway", adw::ResponseAppearance::Destructive);
    dialog.set_default_response(Some("keep"));
    dialog.set_close_response("keep");
    dialog.connect_response(None, move |_, response| {
        if response == "close-anyway" {
            on_close_anyway();
        }
    });
    dialog
}

impl App {
    pub(super) fn prepare_editor_sessions(&mut self, action: SessionTeardownAction, sender: ComponentSender<Self>) {
        if !matches!(action, SessionTeardownAction::CloseTab(_)) {
            self.window.set_sensitive(false);
        }
        let mut replies = Vec::new();
        for (id, tab) in self.workspace_tabs.borrow().iter() {
            if matches!(action, SessionTeardownAction::CloseTab(target) if target != *id) {
                continue;
            }
            let WorkspaceTab::Editor(slot) = tab else {
                continue;
            };
            let (reply, receiver) = tokio::sync::oneshot::channel();
            let _ = slot.controller.sender().send(SqlEditorInput::PrepareForTeardown(reply));
            replies.push((*id, receiver));
        }

        if replies.is_empty() {
            self.on_session_teardown_completed(action, Ok(()), sender);
            return;
        }

        let sender_clone = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    let result = await_editor_sessions(action, replies).await;
                    sender_clone.input(AppMsg::SessionTeardownCompleted { action, result });
                })
                .drop_on_shutdown()
        });
    }

    pub(super) fn on_session_teardown_completed(
        &mut self,
        action: SessionTeardownAction,
        result: Result<(), String>,
        sender: ComponentSender<Self>,
    ) {
        self.window.set_sensitive(true);
        if let Err(message) = result {
            match action {
                SessionTeardownAction::CloseTab(id) => {
                    if let Some(tab_view) = self.workspace_tab_view.clone()
                        && let Some(page) = self.workspace_tabs.borrow().get(&id).map(|tab| match tab {
                            WorkspaceTab::Editor(slot) => slot.page.clone(),
                            WorkspaceTab::Structure(slot) => slot.page.clone(),
                            WorkspaceTab::Table(slot) => slot.page.clone(),
                        })
                    {
                        tab_view.close_page_finish(&page, false);
                    }
                }
                SessionTeardownAction::Disconnect => {}
                SessionTeardownAction::ConnectionSwitch => {
                    self.connection_transition = super::ConnectionTransition::Idle;
                    self.prepared_connection = None;
                    self.switch_saves_pending.clear();
                    self.switch_cancel_audit_was_disabled = None;
                }
                SessionTeardownAction::WindowClose => {
                    self.session_teardown_pending.set(false);
                    let ready = self.session_teardown_ready.clone();
                    let window = self.window.clone();
                    close_anyway_dialog(&message, move || {
                        ready.set(true);
                        window.close();
                    })
                    .present(Some(&self.window));
                    return;
                }
            }
            self.show_error_alert(&crate::tr!("Could not close database sessions"), &message);
            return;
        }

        match action {
            SessionTeardownAction::CloseTab(id) => {
                if let Some(tab_view) = self.workspace_tab_view.clone() {
                    self.finish_close_workspace_tab_now(id, &tab_view);
                }
            }
            SessionTeardownAction::Disconnect => self.finish_disconnect(sender),
            SessionTeardownAction::ConnectionSwitch => self.finish_activate_prepared_connection(sender),
            SessionTeardownAction::WindowClose => {
                self.session_teardown_pending.set(false);
                self.session_teardown_ready.set(true);
                self.window.close();
            }
        }
    }

    pub(super) fn close_tab_after_session_cleanup(&mut self, id: Uuid, sender: ComponentSender<Self>) {
        let is_editor = matches!(self.workspace_tabs.borrow().get(&id), Some(WorkspaceTab::Editor(_)));
        if is_editor {
            self.prepare_editor_sessions(SessionTeardownAction::CloseTab(id), sender);
        } else if let Some(tab_view) = self.workspace_tab_view.clone() {
            self.finish_close_workspace_tab_now(id, &tab_view);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn a_window_close_whose_sessions_cannot_close_offers_to_close_anyway() {
        relm4::gtk::init().unwrap();
        relm4::adw::init().unwrap();
        let closed = std::rc::Rc::new(std::cell::Cell::new(0));
        let counter = closed.clone();
        let dialog = close_anyway_dialog("Timed out waiting for editor sessions to finish cleanup.", move || {
            counter.set(counter.get() + 1)
        });

        assert!(dialog.has_response("keep"));
        assert!(dialog.has_response("close-anyway"));
        assert_eq!(dialog.default_response().as_deref(), Some("keep"));
        assert_eq!(dialog.close_response(), "keep");
        assert!(dialog.body().contains("Timed out waiting"));
        dialog.emit_by_name::<()>("response", &[&"keep"]);
        assert_eq!(closed.get(), 0);
        dialog.emit_by_name::<()>("response", &[&"close-anyway"]);
        assert_eq!(closed.get(), 1);
    }

    #[tokio::test]
    async fn teardown_waits_for_every_editor_session() {
        let first_id = Uuid::new_v4();
        let second_id = Uuid::new_v4();
        let (first_reply, first) = tokio::sync::oneshot::channel();
        let (second_reply, second) = tokio::sync::oneshot::channel();
        let cleanup = tokio::spawn(await_editor_sessions(
            SessionTeardownAction::Disconnect,
            vec![(first_id, first), (second_id, second)],
        ));

        first_reply.send(Ok(())).expect("first cleanup");
        tokio::task::yield_now().await;
        assert!(!cleanup.is_finished());
        second_reply.send(Ok(())).expect("second cleanup");
        cleanup.await.expect("teardown task").expect("all sessions closed");
    }

    #[tokio::test]
    async fn teardown_reports_each_editor_cleanup_failure() {
        let first_id = Uuid::new_v4();
        let second_id = Uuid::new_v4();
        let (first_reply, first) = tokio::sync::oneshot::channel();
        let (second_reply, second) = tokio::sync::oneshot::channel();
        first_reply
            .send(Err("rollback timed out".into()))
            .expect("first cleanup");
        drop(second_reply);

        let error = await_editor_sessions(
            SessionTeardownAction::Disconnect,
            vec![(first_id, first), (second_id, second)],
        )
        .await
        .expect_err("any failed close prevents teardown");
        assert!(error.contains(&first_id.to_string()));
        assert!(error.contains("rollback timed out"));
        assert!(error.contains(&second_id.to_string()));
        assert!(error.contains("closed before cleanup completed"));
    }

    #[tokio::test(start_paused = true)]
    async fn stalled_editor_session_cleanup_times_out_after_five_seconds() {
        let (_reply, receiver) = tokio::sync::oneshot::channel();
        let cleanup = tokio::spawn(await_editor_sessions(
            SessionTeardownAction::WindowClose,
            vec![(Uuid::new_v4(), receiver)],
        ));
        tokio::task::yield_now().await;
        tokio::time::advance(Duration::from_secs(4)).await;
        tokio::task::yield_now().await;
        assert!(!cleanup.is_finished());
        tokio::time::advance(Duration::from_secs(1)).await;
        tokio::task::yield_now().await;
        assert!(cleanup.is_finished());

        let error = cleanup
            .await
            .expect("teardown task")
            .expect_err("a stalled session must require the close-anyway choice");
        assert_eq!(error, "Timed out waiting for editor sessions to finish cleanup.");
    }

    #[tokio::test(start_paused = true)]
    async fn other_teardown_actions_keep_their_twenty_second_timeout() {
        let (_reply, receiver) = tokio::sync::oneshot::channel();
        let cleanup = tokio::spawn(await_editor_sessions(
            SessionTeardownAction::Disconnect,
            vec![(Uuid::new_v4(), receiver)],
        ));
        tokio::task::yield_now().await;
        tokio::time::advance(Duration::from_secs(19)).await;
        tokio::task::yield_now().await;
        assert!(!cleanup.is_finished());
        tokio::time::advance(Duration::from_secs(1)).await;
        tokio::task::yield_now().await;
        assert!(cleanup.is_finished());
        assert!(cleanup.await.expect("teardown task").is_err());
    }
}
