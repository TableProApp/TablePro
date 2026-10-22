use super::*;

impl SqlEditor {
    pub(in crate::ui::editor) fn toolbar_transaction_id(&self) -> Option<Uuid> {
        let session = self.session.as_ref()?;
        (session.transaction_open
            && session.connection_id == self.connection_id?
            && session
                .connection_identity
                .as_ref()
                .is_some_and(|identity| self.database.identity(session.connection_id).as_ref() == Some(identity)))
        .then_some(session.id)
    }

    pub(in crate::ui::editor) fn on_session_toolbar_action(
        &mut self,
        id: Uuid,
        commit: bool,
        sender: &ComponentSender<Self>,
    ) {
        if self.toolbar_transaction_id() != Some(id) || !self.session_action_idle() {
            return;
        }
        if commit {
            self.commit_and_end(id, sender);
        } else {
            self.rollback_and_end(id, sender);
        }
    }
}
