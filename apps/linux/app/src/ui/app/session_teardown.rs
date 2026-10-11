use std::time::Duration;

use relm4::adw::prelude::*;
use relm4::{ComponentController, ComponentSender};
use uuid::Uuid;

use crate::ui::editor::SqlEditorInput;

use super::{App, AppMsg, SessionTeardownAction, WorkspaceTab};

async fn await_editor_sessions(
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
    match tokio::time::timeout(Duration::from_secs(20), cleanup).await {
        Err(_) => Err("Timed out waiting for editor sessions to finish cleanup.".to_string()),
        Ok(result) => result,
    }
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
                    let result = await_editor_sessions(replies).await;
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

    #[tokio::test]
    async fn teardown_waits_for_every_editor_session() {
        let first_id = Uuid::new_v4();
        let second_id = Uuid::new_v4();
        let (first_reply, first) = tokio::sync::oneshot::channel();
        let (second_reply, second) = tokio::sync::oneshot::channel();
        let cleanup = tokio::spawn(await_editor_sessions(vec![(first_id, first), (second_id, second)]));

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

        let error = await_editor_sessions(vec![(first_id, first), (second_id, second)])
            .await
            .expect_err("any failed close prevents teardown");
        assert!(error.contains(&first_id.to_string()));
        assert!(error.contains("rollback timed out"));
        assert!(error.contains(&second_id.to_string()));
        assert!(error.contains("closed before cleanup completed"));
    }
}
