use std::time::Duration;

use crate::{
    bson::{doc, oid::ObjectId, RawDocumentBuf},
    bson_compat::RawError,
    event::command::{CommandEvent, CommandFailedEvent, CommandSucceededEvent},
};

pub use crate::cmap::ConnectionInfo;

use super::CommandStartedEvent;

#[derive(Debug, Clone)]
pub(crate) enum RawCommandEvent {
    Started(RawCommandStartedEvent),
    Succeeded(RawCommandSucceededEvent),
    Failed(CommandFailedEvent),
}

#[derive(Debug, Clone)]
pub(crate) struct RawCommandStartedEvent {
    pub(crate) command: RawDocumentBuf,
    pub(crate) db: String,
    pub(crate) command_name: String,
    pub(crate) request_id: i32,
    pub(crate) connection: ConnectionInfo,
    pub(crate) service_id: Option<ObjectId>,
}

#[derive(Clone, Debug)]
pub(crate) struct RawCommandSucceededEvent {
    pub(crate) duration: Duration,
    pub(crate) reply: RawDocumentBuf,
    pub(crate) command_name: String,
    pub(crate) request_id: i32,
    pub(crate) connection: ConnectionInfo,
    pub(crate) service_id: Option<ObjectId>,
}

impl Into<CommandEvent> for RawCommandEvent {
    fn into(self) -> CommandEvent {
        match self {
            RawCommandEvent::Started(ev) => CommandEvent::Started(CommandStartedEvent {
                command: ev.command.try_into().unwrap_or_else(
                    |e: RawError| doc! { "invalid command document": e.to_string() },
                ),
                db: ev.db,
                command_name: ev.command_name,
                request_id: ev.request_id,
                connection: ev.connection,
                service_id: ev.service_id,
            }),
            RawCommandEvent::Succeeded(ev) => CommandEvent::Succeeded(CommandSucceededEvent {
                duration: ev.duration,
                reply: ev
                    .reply
                    .try_into()
                    .unwrap_or_else(|e: RawError| doc! { "invalid reply document": e.to_string() }),
                command_name: ev.command_name,
                request_id: ev.request_id,
                connection: ev.connection,
                service_id: ev.service_id,
            }),
            RawCommandEvent::Failed(ev) => CommandEvent::Failed(ev),
        }
    }
}
