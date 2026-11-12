use std::collections::BTreeSet;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use bson::Document;
use mongodb::{Client, ClientSession};
use tablepro_core::column::ColumnKind;
use tablepro_core::document::NUMBER_TYPE;
use tablepro_core::sql_syntax::StatementAccess;
use tablepro_core::sql_syntax::mongo::{ShellStatement, access_of, parse_statement, statement_ranges};
use tablepro_core::{
    ColumnInfo, DriverError, ReadOnlyRefusal, ReadStatement, ResultSink, SinkFlow, StopRequest, StreamSummary,
};

use crate::call::{ReadStop, SessionKill, generated, session};
use crate::catalog::{KnownFields, Reader, census_stages, columns_from};
use crate::cursor_rows::Read;
use crate::endpoint::{ClientUse, MongoEndpoint};
use crate::errors::syntax_error;
use crate::execute::{Source, start};
use crate::rows::emit;
use crate::shell_command::{NamedColumn, Plan, plan};

/// Where an export reads: the connection's database, and the
/// collections' columns as it last read them, with the server's time
/// limit for a census of them.
pub(crate) struct ExportScope<'a> {
    pub(crate) database: &'a str,
    pub(crate) known_fields: &'a KnownFields,
    pub(crate) max_time: Option<i64>,
}

/// Every row of what `read` reads, for an export, on a client of its own
/// that closes with it. MongoDB has no read-only session, so a statement
/// that is not a read is refused before anything is sent. A generated
/// read shows the collection's JSON fields as Extended JSON, as the grid
/// does.
pub(crate) fn stream<'a>(
    endpoint: &'a MongoEndpoint,
    scope: &'a ExportScope<'a>,
    read: &'a ReadStatement,
    sink: &'a mut dyn ResultSink,
    stop: &'a StopRequest,
    kill: &'a Arc<SessionKill>,
) -> Pin<Box<dyn Future<Output = Result<StreamSummary, DriverError>> + Send + 'a>> {
    Box::pin(async move {
        let plans = plans(read, scope.database)?;
        let client = endpoint.open(ClientUse::Own).await?;
        let streamed = stream_on(endpoint, &client, scope, plans, sink, stop, kill).await;
        client.shutdown().immediate(streamed.is_err()).await;
        streamed
    })
}

async fn stream_on(
    endpoint: &MongoEndpoint,
    client: &Client,
    scope: &ExportScope<'_>,
    plans: Vec<Planned>,
    sink: &mut dyn ResultSink,
    stop: &StopRequest,
    kill: &Arc<SessionKill>,
) -> Result<StreamSummary, DriverError> {
    let mut session = session(endpoint, client, kill).await?;
    let streamed = match stop.is_requested() {
        true => Err(DriverError::Cancelled),
        false => stream_in(endpoint, client, scope, plans, sink, &mut session, &kill.follow(stop)).await,
    };
    // The export's client closes with it, so no later call takes this
    // session from its pool, and a graceful close waits for it.
    drop(session);
    streamed
}

async fn stream_in(
    endpoint: &MongoEndpoint,
    client: &Client,
    scope: &ExportScope<'_>,
    plans: Vec<Planned>,
    sink: &mut dyn ResultSink,
    session: &mut ClientSession,
    stop: &ReadStop,
) -> Result<StreamSummary, DriverError> {
    let mut rows = 0;
    let mut sets = 0;
    let mut current = scope.database.to_owned();
    for planned in plans {
        let (mut planned, known) = match planned {
            Planned::Ready(planned) => {
                let mut reader = Reader {
                    endpoint,
                    client,
                    session: &mut *session,
                    max_time: scope.max_time,
                    stop,
                };
                let known = scope.known_fields.of(&planned, &mut reader).await?;
                (planned, Some(known))
            }
            Planned::Typed(statement) => (plan(&statement, &current, &[])?, None),
        };
        if planned.discovers_columns() {
            let (mut columns, tallied) = census(endpoint, client, session, &planned, stop).await?;
            if let Some(known) = &known {
                columns = match columns.is_empty() {
                    // No document matched: the collection's columns still head the export.
                    true => known.order.iter().map(NamedColumn::field).collect(),
                    false => in_tab_order(columns, &known.order),
                };
            }
            match tallied {
                true => planned.project_columns(columns),
                false => planned.name_columns(columns),
            }
        }
        // A column the tab shows as JSON stays JSON where the documents
        // the export matches hold one type.
        if let Some(known) = &known {
            planned.show_as_json(known);
        }
        stop.before_command().await?;
        let source = match start(endpoint, client, session, planned).await? {
            Source::Used(next) => {
                current = next;
                continue;
            }
            source => source,
        };
        let (flow, emitted) = emit(endpoint, source, session, sink, None, &mut sets, stop).await?;
        rows += emitted;
        if flow == SinkFlow::ConsumerGone {
            return Err(DriverError::Cancelled);
        }
    }
    Ok(StreamSummary::new(rows))
}

/// The columns of what `planned` reads, found before its first row, as
/// an export writes its columns first, and whether the server tallied
/// them. The server tallies an aggregate's documents with the census a
/// collection's columns come from, over every document, so a field a late
/// document brings is a column and a field of mixed values is JSON. A
/// `find` has no pipeline to tally in, so its documents are read here, for
/// the fields in the order they first show.
async fn census(
    endpoint: &MongoEndpoint,
    client: &Client,
    session: &mut ClientSession,
    planned: &Plan,
    stop: &ReadStop,
) -> Result<(Vec<NamedColumn>, bool), DriverError> {
    if let Some(tally) = planned.tallied_by(census_stages()) {
        let mut tallies = Vec::new();
        each(endpoint, client, session, tally, stop, |tally| tallies.push(tally)).await?;
        return Ok((columns_from(&tallies).iter().map(named).collect(), true));
    }
    let mut fields = Vec::new();
    let mut seen = BTreeSet::new();
    each(endpoint, client, session, planned.clone(), stop, |document| {
        for key in document.keys() {
            if seen.insert(key.clone()) {
                fields.push(NamedColumn::field(key.clone()));
            }
        }
    })
    .await?;
    Ok((fields, false))
}

/// The census's columns in the order the connection last read the
/// collection's, then the ones it did not read in the census's order, so
/// another client's documents do not move a column the tab shows.
fn in_tab_order(mut columns: Vec<NamedColumn>, order: &[String]) -> Vec<NamedColumn> {
    columns.sort_by_key(|column| {
        order
            .iter()
            .position(|name| *name == column.name)
            .unwrap_or(order.len())
    });
    columns
}

/// Hand each document a plan's cursor returns to `take`.
async fn each(
    endpoint: &MongoEndpoint,
    client: &Client,
    session: &mut ClientSession,
    planned: Plan,
    stop: &ReadStop,
    mut take: impl FnMut(Document) + Send,
) -> Result<(), DriverError> {
    stop.before_command().await?;
    let Source::Cursor { cursor, .. } = start(endpoint, client, session, planned).await? else {
        return Ok(());
    };
    let mut read = Read::new(endpoint, *cursor, session, stop);
    while let Some(document) = read.next().await? {
        take(document);
    }
    Ok(())
}

/// A census column as an export writes it: Extended JSON for a JSON one.
fn named(column: &ColumnInfo) -> NamedColumn {
    NamedColumn {
        json: matches!(column.column_type.kind, ColumnKind::Json { .. }),
        numbers: column.column_type.name == NUMBER_TYPE,
        ..NamedColumn::field(column.name.clone())
    }
}

enum Planned {
    /// A generated read, its parameters bound.
    Ready(Plan),
    /// A typed statement, planned when it runs, after the `use` before it.
    Typed(ShellStatement),
}

/// Each statement of the read, every one of them a read.
fn plans(read: &ReadStatement, database: &str) -> Result<Vec<Planned>, DriverError> {
    let refuse = || DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard);
    match read {
        ReadStatement::Generated(statement) => {
            let (parsed, planned) = generated(statement, database)?;
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_export_keeps_the_tabs_column_order_with_other_fields_after_it() {
        let census = ["_id", "x", "a", "late", "z", "b"].map(NamedColumn::field).to_vec();
        let tab = ["_id", "z", "a", "gone", "b"].map(str::to_owned);

        let names: Vec<String> = in_tab_order(census, &tab)
            .into_iter()
            .map(|column| column.name)
            .collect();

        assert_eq!(names, ["_id", "z", "a", "b", "x", "late"]);
    }
}
