use std::collections::BTreeSet;
use std::sync::Arc;

use bson::{Bson, Document};
use mongodb::ClientSession;
use tablepro_core::column::{ColumnType, ResultColumn};
use tablepro_core::value::Value;
use tablepro_core::{
    DriverError, LossPhase, QueryResult, ResultEvent, ResultSink, RowLimit, ServerNotice, SinkFlow, Truncation,
};

use crate::cells::cell;
use crate::endpoint::MongoEndpoint;
use crate::execute::Source;
use crate::field_types::{column_type, shared_type, type_alias};
use crate::shell_command::{Columns, NamedColumn};

/// Rows per `ResultEvent::Rows`. The sink is awaited per batch, so a slow
/// grid slows the read instead of growing a queue.
pub(crate) const BATCH_ROWS: usize = 256;

/// The columns documents are laid out in, which a layout whose fields
/// are found from the documents adds to.
#[derive(Debug, Clone)]
pub(crate) struct Layout {
    /// The field each column reads.
    keys: Vec<String>,
    /// The name each column shows.
    names: Vec<String>,
    /// Each column shown as Extended JSON whatever its value's type.
    json: Vec<bool>,
    /// Each column's types so far, for the type the column shows.
    types: Vec<BTreeSet<&'static str>>,
    discovered: bool,
}

impl Layout {
    pub(crate) fn new(columns: &Columns) -> Self {
        let named = match columns {
            Columns::Named(named) => named.clone(),
            Columns::Values(name) => vec![NamedColumn::field(name.clone())],
            Columns::Discovered => Vec::new(),
        };
        Self {
            types: vec![BTreeSet::new(); named.len()],
            json: named.iter().map(|column| column.json).collect(),
            names: named.iter().map(|column| column.name.clone()).collect(),
            keys: named.into_iter().map(|column| column.key).collect(),
            discovered: matches!(columns, Columns::Discovered),
        }
    }

    /// Take in a document's fields, and say whether it holds one outside
    /// the columns there were: a found layout adds it, a named one leaves
    /// it out.
    pub(crate) fn learn(&mut self, document: &Document) -> bool {
        let mut outside = false;
        for (key, value) in document {
            let index = match self.keys.iter().position(|known| known == key) {
                Some(index) => index,
                None if self.discovered => {
                    self.keys.push(key.clone());
                    self.names.push(key.clone());
                    self.json.push(false);
                    self.types.push(BTreeSet::new());
                    outside = true;
                    self.keys.len() - 1
                }
                None => {
                    outside = true;
                    continue;
                }
            };
            self.types[index].insert(type_alias(value));
        }
        outside
    }

    /// A document as a row: each column's field, null where it has none.
    pub(crate) fn row(&self, document: &Document) -> Vec<Value> {
        self.keys
            .iter()
            .zip(&self.json)
            .map(|(key, json)| match (document.get(key), json) {
                (None, _) => Value::Null,
                (Some(value), true) => crate::cells::json(value),
                (Some(value), false) => cell(value),
            })
            .collect()
    }

    pub(crate) fn columns(&self) -> Arc<[ResultColumn]> {
        self.names
            .iter()
            .zip(&self.types)
            .zip(&self.json)
            .map(|((name, types), json)| match json {
                true => ResultColumn::new(name.clone(), column_type("object")),
                false => ResultColumn::new(name.clone(), column_kind(types)),
            })
            .collect()
    }
}

fn column_kind(types: &BTreeSet<&'static str>) -> ColumnType {
    match types.is_empty() {
        true => ColumnType::unknown(),
        false => column_type(shared_type(types)),
    }
}

/// Every document of a source as rows, keeping at most `limit` and
/// reading one more to say whether there were more.
pub(crate) async fn collect(
    endpoint: &MongoEndpoint,
    source: Source,
    session: &mut ClientSession,
    limit: RowLimit,
) -> Result<QueryResult, DriverError> {
    let (documents, columns, truncated) = match source {
        Source::Cursor { mut cursor, columns } => {
            let mut documents = Vec::new();
            let mut truncated = false;
            loop {
                match cursor.advance(session).await {
                    Ok(true) if (documents.len() as u64) < limit.get() => {
                        documents.push(crate::nested_document::current_document(&cursor)?);
                    }
                    Ok(true) => {
                        truncated = true;
                        break;
                    }
                    Ok(false) => break,
                    Err(error) => return Err(endpoint.explain(&error, LossPhase::Statement).await),
                }
            }
            (documents, columns, truncated)
        }
        Source::Documents { mut documents, columns } => {
            let keep = usize::try_from(limit.get()).unwrap_or(usize::MAX);
            let truncated = documents.len() > keep;
            documents.truncate(keep);
            (documents, columns, truncated)
        }
        Source::Count(count) => (
            vec![bson::doc! { "count": Bson::Int64(i64::try_from(count).unwrap_or(i64::MAX)) }],
            Columns::Discovered,
            false,
        ),
        Source::Write { summary, .. } => (vec![summary], Columns::Discovered, false),
        Source::Used(_) => (Vec::new(), Columns::Discovered, false),
    };
    let mut layout = Layout::new(&columns);
    for document in &documents {
        layout.learn(document);
    }
    let rows = documents.iter().map(|document| layout.row(document)).collect();
    Ok(QueryResult::new(layout.columns(), rows).truncated(truncated))
}

/// Stream a source into `sink`, keeping at most `limit` rows when there
/// is one.
pub(crate) async fn emit(
    endpoint: &MongoEndpoint,
    source: Source,
    session: &mut ClientSession,
    sink: &mut dyn ResultSink,
    limit: Option<RowLimit>,
) -> Result<(SinkFlow, u64), DriverError> {
    match source {
        Source::Used(database) => {
            let notice = ServerNotice {
                severity: "INFO".to_owned(),
                message: format!("switched to db {database}"),
                code: None,
            };
            if sink.accept(ResultEvent::Notice(notice)).await == SinkFlow::ConsumerGone {
                return Ok((SinkFlow::ConsumerGone, 0));
            }
            Ok((
                sink.accept(ResultEvent::CommandCompleted { rows_affected: None }).await,
                0,
            ))
        }
        Source::Write {
            unconfirmed: Some(error),
            ..
        } => Err(error),
        Source::Write { affected, summary, .. } => {
            let (flow, rows) = emit_documents(sink, vec![summary], &Columns::Discovered, limit).await;
            if flow == SinkFlow::ConsumerGone {
                return Ok((flow, rows));
            }
            let flow = sink
                .accept(ResultEvent::CommandCompleted {
                    rows_affected: Some(affected),
                })
                .await;
            Ok((flow, rows))
        }
        Source::Count(count) => {
            let counted = bson::doc! { "count": Bson::Int64(i64::try_from(count).unwrap_or(i64::MAX)) };
            Ok(emit_documents(sink, vec![counted], &Columns::Discovered, limit).await)
        }
        Source::Documents { documents, columns } => Ok(emit_documents(sink, documents, &columns, limit).await),
        Source::Cursor { cursor, columns } => {
            crate::cursor_rows::stream(endpoint, *cursor, columns, session, sink, limit).await
        }
    }
}

async fn emit_documents(
    sink: &mut dyn ResultSink,
    documents: Vec<Document>,
    columns: &Columns,
    limit: Option<RowLimit>,
) -> (SinkFlow, u64) {
    let mut layout = Layout::new(columns);
    for document in &documents {
        layout.learn(document);
    }
    let total = documents.len() as u64;
    let retained = limit.map_or(total, |limit| limit.get().min(total));
    if sink
        .accept(ResultEvent::ResultSetStarted {
            columns: layout.columns(),
        })
        .await
        == SinkFlow::ConsumerGone
    {
        return (SinkFlow::ConsumerGone, 0);
    }
    // Rows made before the first await: an iterator whose closure lives
    // across one leaves the future no longer `Send` for every lifetime.
    let mut rows = documents
        .iter()
        .take(usize::try_from(retained).unwrap_or(usize::MAX))
        .map(|document| layout.row(document))
        .collect::<Vec<_>>()
        .into_iter();
    loop {
        let batch: Vec<_> = rows.by_ref().take(BATCH_ROWS).collect();
        if batch.is_empty() {
            break;
        }
        if sink.accept(ResultEvent::Rows(batch)).await == SinkFlow::ConsumerGone {
            return (SinkFlow::ConsumerGone, retained);
        }
    }
    let cut = retained < total;
    if cut && sink.accept(ResultEvent::RowLimitReached { retained }).await == SinkFlow::ConsumerGone {
        return (SinkFlow::ConsumerGone, retained);
    }
    let flow = sink
        .accept(ResultEvent::ResultSetFinished {
            retained,
            total_rows: Some(total),
            truncation: match cut {
                true => Truncation::ReadPastLimit,
                false => Truncation::Complete,
            },
        })
        .await;
    (flow, retained)
}

#[cfg(test)]
mod tests {
    use bson::doc;

    use super::*;

    #[test]
    fn a_found_layout_grows_with_the_fields_documents_bring() {
        let mut layout = Layout::new(&Columns::Discovered);

        assert!(layout.learn(&doc! { "_id": 1_i32, "a": "x" }));
        assert!(!layout.learn(&doc! { "_id": 2_i32 }));
        assert!(layout.learn(&doc! { "_id": 3_i32, "b": true }));

        assert_eq!(
            layout.row(&doc! { "b": false, "_id": 4_i32 }),
            [Value::Int(4), Value::Null, Value::Bool(false)]
        );
        let names: Vec<String> = layout.columns().iter().map(|column| column.name.clone()).collect();
        assert_eq!(names, ["_id", "a", "b"]);
    }

    #[test]
    fn a_named_layout_keeps_its_columns() {
        let aliased = NamedColumn {
            key: "__field_2".to_owned(),
            name: "a.b".to_owned(),
            json: false,
        };
        let nested = NamedColumn {
            json: true,
            ..NamedColumn::field("n")
        };
        let mut layout = Layout::new(&Columns::Named(vec![
            NamedColumn::field("b"),
            NamedColumn::field("a"),
            aliased,
            nested,
        ]));

        assert!(layout.learn(&doc! { "a": 1_i32, "c": 2_i32 }), "c is outside");
        assert!(!layout.learn(&doc! { "a": 1_i32, "__field_2": 3_i32, "n": 4_i64 }));
        assert_eq!(
            layout.row(&doc! { "a": 1_i32, "__field_2": 3_i32, "n": 4_i64 }),
            [
                Value::Null,
                Value::Int(1),
                Value::Int(3),
                Value::Json(tablepro_core::value::JsonText::parse(r#"{"$numberLong": "4"}"#.to_owned()).expect("JSON"))
            ]
        );
        let names: Vec<String> = layout.columns().iter().map(|column| column.name.clone()).collect();
        assert_eq!(names, ["b", "a", "a.b", "n"]);
    }
}
