use std::sync::Arc;

use tablepro_session::Session;
use tablepro_session::runtime::WatchForwarder;

use super::{WorkspaceInput, WorkspaceSender, sidebar};
use crate::runtime::DeliverInput;

/// Feed the reconnect banner and the sidebar, and stop with the
/// workspace, so nothing reads for a session it let go of.
pub(super) struct SessionWatches {
    _health: WatchForwarder,
    _catalog: WatchForwarder,
    _reconnect: WatchForwarder,
    _link: WatchForwarder,
}

impl SessionWatches {
    pub(super) fn new(session: &Arc<Session>, input: &WorkspaceSender) -> Self {
        let health_input = input.clone();
        let health = WatchForwarder::new(
            session.health(),
            move |health| health_input.deliver(WorkspaceInput::HealthChanged(health)),
            sidebar::spawn_local,
        );
        let (listed, failed) = (input.clone(), input.clone());
        let catalog = sidebar::catalog_watch(
            session,
            move |snapshot| listed.deliver(WorkspaceInput::CatalogChanged(snapshot)),
            move |error| {
                failed.deliver(WorkspaceInput::CatalogReadFailed(
                    crate::ui::error_text::operation_error_message(&error),
                ));
            },
        );
        let committed = input.clone();
        let reconnect = sidebar::reconnect_watch(session, move |snapshot| {
            committed.deliver(WorkspaceInput::DefaultListCommitted(snapshot));
        });
        let relinked = input.clone();
        let link = WatchForwarder::new(
            session.link_changes(),
            move |_| relinked.deliver(WorkspaceInput::LinkChanged),
            sidebar::spawn_local,
        );
        Self {
            _health: health,
            _catalog: catalog,
            _reconnect: reconnect,
            _link: link,
        }
    }
}
