use tablepro_core::sql_syntax::StatementAccess;
use tablepro_core::sql_syntax::redis::{EditorUse, command_access, editor_use, split_commands};
use tablepro_core::{
    DriverError, ReadOnlyRefusal, ReadStatement, ResultSink, SinkFlow, StopRequest, StreamSummary, UnsupportedFeature,
};

use crate::endpoint::RedisEndpoint;
use crate::errors::invalid_arguments;
use crate::link::{command, stoppable};
use crate::reply_rows::{ReplyShape, emit, reply_shape};

/// Every row of what the commands of `read` reply, for an export, on a
/// link of its own that closes with it. Redis has no read-only session,
/// so a command that is not a read is refused before anything is sent.
pub(crate) async fn stream(
    endpoint: &RedisEndpoint,
    read: &ReadStatement,
    sink: &mut dyn ResultSink,
    stop: &StopRequest,
) -> Result<StreamSummary, DriverError> {
    let ReadStatement::User(text) = read else {
        return Err(DriverError::Unsupported {
            feature: UnsupportedFeature::Tables,
        });
    };
    let mut commands = Vec::new();
    for lexed in split_commands(text.as_str()) {
        let arguments = lexed.values.map_err(invalid_arguments)?;
        if let EditorUse::Refused(command) = editor_use(&arguments) {
            return Err(DriverError::Unsupported {
                feature: UnsupportedFeature::EditorCommand { command },
            });
        }
        if command_access(&arguments) != StatementAccess::Read {
            return Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard));
        }
        commands.push(arguments);
    }
    let link = stoppable(stop, endpoint.open()).await?;
    let mut rows = 0;
    for arguments in commands {
        let reply = stoppable(stop, link.send(&command(&arguments))).await?;
        let shape = reply_shape(reply)?;
        if let ReplyShape::Table { rows: shape_rows, .. } = &shape {
            rows += shape_rows.len() as u64;
        }
        if emit(sink, shape, None).await == SinkFlow::ConsumerGone {
            return Err(DriverError::Cancelled);
        }
    }
    Ok(StreamSummary::new(rows))
}
