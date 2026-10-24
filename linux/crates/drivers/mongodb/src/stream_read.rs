use std::collections::BTreeSet;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use bson::Document;
use mongodb::{Client, ClientSession};
use tablepro_core::sql_syntax::StatementAccess;
use tablepro_core::sql_syntax::mongo::{ShellStatement, access_of, parse_statement, statement_ranges};
use tablepro_core::{
    DriverError, LossPhase, ReadOnlyRefusal, ReadStatement, ResultSink, SinkFlow, StopRequest, StreamSummary,
};

use crate::call::{SessionKill, generated, session};
use crate::endpoint::{ClientUse, MongoEndpoint};
use crate::errors::syntax_error;
use crate::execute::{Source, start};
use crate::rows::emit;
use crate::shell_command::{Plan, plan};

/// Every row of what `read` reads, for an export, on a client of its own
/// that closes with it. MongoDB has no read-only session, so a statement
/// that is not a read is refused before anything is sent. A generated
/// read shows `json_fields` as Extended JSON, as the grid does.
pub(crate) fn stream<'a>(
    endpoint: &'a MongoEndpoint,
    database: &'a str,
    read: &'a ReadStatement,
    json_fields: &'a BTreeSet<String>,
    sink: &'a mut dyn ResultSink,
    stop: &'a StopRequest,
    kill: &'a Arc<SessionKill>,
) -> Pin<Box<dyn Future<Output = Result<StreamSummary, DriverError>> + Send + 'a>> {
    Box::pin(async move {
        let plans = plans(read, database, json_fields)?;
        let client = endpoint.open(ClientUse::Own).await?;
        let streamed = stream_on(endpoint, &client, database, plans, sink, stop, kill).await;
        client.shutdown().immediate(streamed.is_err()).await;
        streamed
    })
}

async fn stream_on(
    endpoint: &MongoEndpoint,
    client: &Client,
    database: &str,
    plans: Vec<Planned>,
    sink: &mut dyn ResultSink,
    stop: &StopRequest,
    kill: &Arc<SessionKill>,
) -> Result<StreamSummary, DriverError> {
    let mut session = session(endpoint, client, kill).await?;
    let streamed = match stop.is_requested() {
        true => Err(DriverError::Cancelled),
        false => stream_in(endpoint, client, database, plans, sink, &mut session).await,
    };
    // The export's client closes with it, so no later call takes this
    // session from its pool, and a graceful close waits for it.
    drop(session);
    streamed
}

async fn stream_in(
    endpoint: &MongoEndpoint,
    client: &Client,
    database: &str,
    plans: Vec<Planned>,
    sink: &mut dyn ResultSink,
    session: &mut ClientSession,
) -> Result<StreamSummary, DriverError> {
    let mut rows = 0;
    let mut current = database.to_owned();
    for planned in plans {
        let mut planned = match planned {
            Planned::Ready(planned) => planned,
            Planned::Typed(statement) => plan(&statement, &current, &[])?,
        };
        if planned.discovers_columns() {
            let fields = census(endpoint, client, session, planned.clone()).await?;
            planned.name_columns(fields);
        }
        let source = match start(endpoint, client, session, planned).await? {
            Source::Used(next) => {
                current = next;
                continue;
            }
            source => source,
        };
        let (flow, emitted) = emit(endpoint, source, session, sink, None).await?;
        rows += emitted;
        if flow == SinkFlow::ConsumerGone {
            return Err(DriverError::Cancelled);
        }
    }
    Ok(StreamSummary::new(rows))
}

/// The fields a cursor's documents hold, in the order they first show,
/// from a read of its own. An export writes its columns before its first
/// row, so it has to know every field before it reads one to write.
async fn census(
    endpoint: &MongoEndpoint,
    client: &Client,
    session: &mut ClientSession,
    planned: Plan,
) -> Result<Vec<String>, DriverError> {
    let Source::Cursor { mut cursor, .. } = start(endpoint, client, session, planned).await? else {
        return Ok(Vec::new());
    };
    let mut fields: Vec<String> = Vec::new();
    let mut seen = BTreeSet::new();
    loop {
        match cursor.advance(session).await {
            Ok(true) => {
                let document: Document = cursor.deserialize_current().map_err(|error| DriverError::Decode {
                    column: String::new(),
                    detail: error.to_string(),
                })?;
                for key in document.keys() {
                    if seen.insert(key.clone()) {
                        fields.push(key.clone());
                    }
                }
            }
            Ok(false) => return Ok(fields),
            Err(error) => return Err(endpoint.explain(&error, LossPhase::Statement).await),
        }
    }
}

enum Planned {
    /// A generated read, its parameters bound.
    Ready(Plan),
    /// A typed statement, planned when it runs, after the `use` before it.
    Typed(ShellStatement),
}

/// Each statement of the read, every one of them a read.
fn plans(read: &ReadStatement, database: &str, json_fields: &BTreeSet<String>) -> Result<Vec<Planned>, DriverError> {
    let refuse = || DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard);
    match read {
        ReadStatement::Generated(statement) => {
            let (parsed, mut planned) = generated(statement, database)?;
            planned.show_as_json(json_fields);
            match access_of(&parsed) {
                StatementAccess::Read => Ok(vec![Planned::Ready(planned)]),
                _ => Err(refuse()),
            }
        }
        ReadStatement::User(text) => {
            let text = text.as_str();
            let mut statements = Vec::new();
            for range in statement_ranges(text) {
                let parsed =
                    parse_statement(&text[range.clone()]).map_err(|error| syntax_error(&error, text, range.start))?;
                if access_of(&parsed) != StatementAccess::Read {
                    return Err(refuse());
                }
                statements.push(Planned::Typed(parsed));
            }
            Ok(statements)
        }
    }
}
