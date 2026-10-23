use bson::{Bson, Document, doc};
use mongodb::{Client, ClientSession, SessionCursor};
use tablepro_core::{DriverError, LossPhase};

use crate::endpoint::MongoEndpoint;
use crate::errors::{reply_write_concern_error, reply_write_error};
use crate::shell_command::{Columns, NamedColumn, Plan, Reply, WriteKind};

/// Reply fields that say how the server ran a command, not what it
/// answered.
const BOOKKEEPING: [&str; 6] = [
    "ok",
    "$clusterTime",
    "operationTime",
    "$gleStats",
    "lastCommittedOpTime",
    "electionId",
];

/// What a statement produced, ready to be read.
pub(crate) enum Source {
    /// `use`: the database from here on.
    Used(String),
    /// Documents still on the server, read a batch at a time.
    Cursor {
        cursor: Box<SessionCursor<Document>>,
        columns: Columns,
    },
    /// Documents the reply held whole.
    Documents {
        documents: Vec<Document>,
        columns: Columns,
    },
    Count(u64),
    /// What a write did: how many documents it matched, and the summary
    /// mongosh shows for it. `unconfirmed` is a write concern the server
    /// could not meet, which leaves the write applied but its fate open.
    Write {
        affected: u64,
        summary: Document,
        unconfirmed: Option<DriverError>,
    },
}

/// Send a planned statement in `session`.
pub(crate) async fn start(
    endpoint: &MongoEndpoint,
    client: &Client,
    session: &mut ClientSession,
    plan: Plan,
) -> Result<Source, DriverError> {
    match plan {
        Plan::Use(database) => Ok(Source::Used(database)),
        Plan::Cursor {
            database,
            command,
            columns,
            counted,
        } => {
            let opened = client
                .database(&database)
                .run_cursor_command(command)
                .session(&mut *session)
                .await;
            let mut cursor = match opened {
                Ok(cursor) => cursor,
                Err(error) => return Err(endpoint.explain(&error, LossPhase::Statement).await),
            };
            if !counted {
                return Ok(Source::Cursor {
                    cursor: Box::new(cursor),
                    columns,
                });
            }
            let first = match cursor.advance(session).await {
                Ok(true) => cursor.deserialize_current().ok(),
                Ok(false) => None,
                Err(error) => return Err(endpoint.explain(&error, LossPhase::Statement).await),
            };
            Ok(Source::Count(
                first.as_ref().map_or(0, |document| count_of(document.get("n"))),
            ))
        }
        Plan::Command {
            database,
            command,
            reply,
        } => {
            let answered = client
                .database(&database)
                .run_command(command)
                .session(&mut *session)
                .await;
            let answer = match answered {
                Ok(answer) => answer,
                Err(error) => return Err(endpoint.explain(&error, LossPhase::Statement).await),
            };
            if let Some(error) = reply_write_error(&answer) {
                return Err(error);
            }
            let unconfirmed = reply_write_concern_error(&answer);
            match (shaped(answer, reply), unconfirmed) {
                (Source::Write { affected, summary, .. }, unconfirmed) => Ok(Source::Write {
                    affected,
                    summary,
                    unconfirmed,
                }),
                (_, Some(error)) => Err(error),
                (source, None) => Ok(source),
            }
        }
    }
}

fn count_of(value: Option<&Bson>) -> u64 {
    match value {
        Some(Bson::Int32(number)) => u64::try_from(*number).unwrap_or(0),
        Some(Bson::Int64(number)) => u64::try_from(*number).unwrap_or(0),
        Some(Bson::Double(number)) if *number >= 0.0 => *number as u64,
        _ => 0,
    }
}

fn shaped(mut answer: Document, reply: Reply) -> Source {
    for key in BOOKKEEPING {
        answer.remove(key);
    }
    let whole = |document: Document| Source::Documents {
        documents: vec![document],
        columns: Columns::Discovered,
    };
    match reply {
        Reply::Whole => whole(answer),
        Reply::Rows(field) => Source::Documents {
            documents: documents_in(answer.get(field)),
            columns: Columns::Discovered,
        },
        Reply::Values { field, column } => Source::Documents {
            documents: match answer.get(field) {
                Some(Bson::Array(values)) => values
                    .iter()
                    .map(|value| doc! { column.clone(): value.clone() })
                    .collect(),
                _ => Vec::new(),
            },
            columns: Columns::Values(column),
        },
        Reply::Field(field) => match answer.get(field).cloned() {
            Some(Bson::Document(document)) => whole(document),
            Some(Bson::Array(items)) => Source::Documents {
                documents: documents_in(Some(&Bson::Array(items))),
                columns: Columns::Discovered,
            },
            Some(value) => Source::Documents {
                documents: vec![doc! { field: value }],
                columns: Columns::Named(vec![NamedColumn::field(field)]),
            },
            None => whole(Document::new()),
        },
        Reply::Count(field) => Source::Count(count_of(answer.get(field))),
        Reply::Write(kind) => write_summary(&answer, kind),
    }
}

fn documents_in(value: Option<&Bson>) -> Vec<Document> {
    match value {
        Some(Bson::Array(items)) => items
            .iter()
            .map(|item| match item {
                Bson::Document(document) => document.clone(),
                other => doc! { "value": other.clone() },
            })
            .collect(),
        _ => Vec::new(),
    }
}

/// What a write did, as mongosh sums it up. `affected` is how many
/// documents it matched, so an update that writes the value a field
/// already holds still counts the document it found.
fn write_summary(answer: &Document, kind: WriteKind) -> Source {
    let n = count_of(answer.get("n"));
    let (affected, summary) = match kind {
        WriteKind::Insert(ids) => {
            let summary = match ids.as_slice() {
                [id] => doc! { "acknowledged": true, "insertedId": id.clone() },
                _ => doc! { "acknowledged": true, "insertedIds": ids },
            };
            (n, summary)
        }
        WriteKind::Update => {
            let upserted = match answer.get("upserted") {
                Some(Bson::Array(items)) => items.clone(),
                _ => Vec::new(),
            };
            let mut summary = doc! {
                "acknowledged": true,
                "matchedCount": Bson::Int64(i64::try_from(n.saturating_sub(upserted.len() as u64)).unwrap_or(i64::MAX)),
                "modifiedCount": answer.get("nModified").cloned().unwrap_or(Bson::Int32(0)),
                "upsertedCount": Bson::Int64(upserted.len() as i64),
            };
            if let Some(Bson::Document(first)) = upserted.first() {
                summary.insert("upsertedId", first.get("_id").cloned().unwrap_or(Bson::Null));
            }
            (n, summary)
        }
        WriteKind::Delete => (
            n,
            doc! { "acknowledged": true, "deletedCount": Bson::Int64(i64::try_from(n).unwrap_or(i64::MAX)) },
        ),
    };
    Source::Write {
        affected,
        summary,
        unconfirmed: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_reply_drops_its_bookkeeping_and_a_write_is_summed_up() {
        let Source::Documents { documents, .. } = shaped(
            doc! { "version": "8.0.4", "ok": 1.0_f64, "$clusterTime": {}, "operationTime": 1_i32 },
            Reply::Whole,
        ) else {
            panic!("not documents");
        };
        assert_eq!(documents, [doc! { "version": "8.0.4" }]);

        let Source::Write { affected, summary, .. } = shaped(
            doc! { "n": 1_i32, "nModified": 0_i32, "ok": 1.0_f64 },
            Reply::Write(WriteKind::Update),
        ) else {
            panic!("not a write");
        };
        assert_eq!(affected, 1, "an update that changed nothing still matched");
        assert_eq!(summary.get_i64("matchedCount").ok(), Some(1));

        let Source::Count(count) = shaped(doc! { "n": 42_i32, "ok": 1.0_f64 }, Reply::Count("n")) else {
            panic!("not a count");
        };
        assert_eq!(count, 42);
    }
}
