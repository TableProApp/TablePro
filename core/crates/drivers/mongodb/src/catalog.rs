use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Mutex, PoisonError};

use bson::spec::BinarySubtype;
use bson::{Binary, Bson, Document, doc};
use mongodb::{Client, ClientSession};
use tablepro_core::column::ColumnKind;
use tablepro_core::meta::{IndexInfo, IndexKey, ObjectInfo, ObjectKind, RowCountEstimate, SchemaInfo, TableEstimate};
use tablepro_core::{ColumnInfo, DriverError, LossPhase};

use crate::endpoint::MongoEndpoint;
use crate::field_types::{field_column, type_alias};
use crate::shell_command::Plan;

/// How many documents a collection's fields are found from, in their
/// natural order. Enough to meet the fields a collection's documents
/// share, bounded so a large one costs one short read.
const CENSUS_DOCUMENTS: i32 = 1_000;

/// Databases MongoDB keeps for itself.
const SYSTEM_DATABASES: [&str; 3] = ["admin", "config", "local"];

/// What one catalogue read needs: the client, the call's own session and
/// the server's time limit for it.
pub(crate) struct Reader<'a> {
    pub(crate) endpoint: &'a MongoEndpoint,
    pub(crate) client: &'a Client,
    pub(crate) session: &'a mut ClientSession,
    pub(crate) max_time: Option<i64>,
}

impl Reader<'_> {
    async fn command(&mut self, database: &str, mut command: Document) -> Result<Document, DriverError> {
        if let Some(millis) = self.max_time {
            command.insert("maxTimeMS", Bson::Int64(millis));
        }
        let answered = self
            .client
            .database(database)
            .run_command(command)
            .session(&mut *self.session)
            .await;
        match answered {
            Ok(answer) => Ok(answer),
            Err(error) => Err(self.endpoint.explain(&error, LossPhase::Statement).await),
        }
    }

    async fn documents(&mut self, database: &str, mut command: Document) -> Result<Vec<Document>, DriverError> {
        if let Some(millis) = self.max_time {
            command.insert("maxTimeMS", Bson::Int64(millis));
        }
        let opened = self
            .client
            .database(database)
            .run_cursor_command(command)
            .session(&mut *self.session)
            .await;
        let mut cursor = match opened {
            Ok(cursor) => cursor,
            Err(error) => return Err(self.endpoint.explain(&error, LossPhase::Statement).await),
        };
        let mut documents = Vec::new();
        loop {
            match cursor.advance(self.session).await {
                Ok(true) => documents.push(crate::nested_document::current_document(&cursor)?),
                Ok(false) => return Ok(documents),
                Err(error) => return Err(self.endpoint.explain(&error, LossPhase::Statement).await),
            }
        }
    }

    /// The databases the login may see, `default` among them even
    /// before it holds a collection.
    pub(crate) async fn databases(&mut self, default: &str) -> Result<Vec<SchemaInfo>, DriverError> {
        let answer = self
            .command(
                "admin",
                doc! { "listDatabases": 1_i32, "nameOnly": true, "authorizedDatabases": true },
            )
            .await?;
        let mut names: BTreeSet<String> = match answer.get("databases") {
            Some(Bson::Array(items)) => items
                .iter()
                .filter_map(|item| item.as_document()?.get_str("name").ok().map(str::to_owned))
                .collect(),
            _ => BTreeSet::new(),
        };
        names.insert(default.to_owned());
        Ok(names
            .into_iter()
            .map(|name| SchemaInfo {
                is_default: name == default,
                is_system: SYSTEM_DATABASES.contains(&name.as_str()),
                name,
            })
            .collect())
    }

    /// A database's collections and views.
    pub(crate) async fn collections(&mut self, database: &str) -> Result<Vec<ObjectInfo>, DriverError> {
        let listed = self
            .documents(
                database,
                doc! { "listCollections": 1_i32, "nameOnly": true, "authorizedCollections": true },
            )
            .await?;
        let mut objects: Vec<ObjectInfo> = listed
            .iter()
            .filter_map(|entry| {
                let name = entry.get_str("name").ok()?;
                let kind = match entry.get_str("type") {
                    Ok("view") => ObjectKind::View,
                    _ => ObjectKind::Table,
                };
                Some(ObjectInfo {
                    schema: Some(database.to_owned()),
                    name: name.to_owned(),
                    kind,
                    parent_table: None,
                })
            })
            .collect();
        objects.sort_by(|left, right| left.name.cmp(&right.name));
        Ok(objects)
    }

    /// What kind of collection it is, which decides whether `_id` names
    /// one document.
    pub(crate) async fn collection_type(
        &mut self,
        database: &str,
        collection: &str,
    ) -> Result<CollectionType, DriverError> {
        let listed = self
            .documents(
                database,
                doc! { "listCollections": 1_i32, "filter": { "name": collection }, "nameOnly": true, "authorizedCollections": true },
            )
            .await?;
        Ok(match listed.first().and_then(|entry| entry.get_str("type").ok()) {
            Some("view") => CollectionType::View,
            Some("timeseries") => CollectionType::TimeSeries,
            _ => CollectionType::Collection,
        })
    }

    /// The fields the first documents hold, each with the types it holds,
    /// in the order the documents place them: `_id` first. The server
    /// tallies them, so no document crosses the wire.
    pub(crate) async fn fields(&mut self, database: &str, collection: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        let mut pipeline = vec![doc! { "$limit": CENSUS_DOCUMENTS }];
        pipeline.extend(census_stages());
        let tallies = self
            .documents(
                database,
                doc! { "aggregate": collection, "pipeline": pipeline, "cursor": {} },
            )
            .await?;
        Ok(collection_columns(&tallies))
    }

    /// The collection's indexes, `_id`'s first.
    pub(crate) async fn indexes(&mut self, database: &str, collection: &str) -> Result<Vec<IndexInfo>, DriverError> {
        let listed = self.documents(database, doc! { "listIndexes": collection }).await?;
        Ok(listed.iter().filter_map(index_info).collect())
    }

    /// The count the collection's metadata keeps, which a crash or an
    /// orphaned chunk can leave off, so it reads as an estimate.
    pub(crate) async fn estimate(&mut self, database: &str, collection: &str) -> Result<TableEstimate, DriverError> {
        let answer = self.command(database, doc! { "count": collection }).await?;
        let rows = match answer.get("n") {
            Some(Bson::Int32(count)) => {
                u64::try_from(*count).map_or(RowCountEstimate::Unknown, RowCountEstimate::Approximate)
            }
            Some(Bson::Int64(count)) => {
                u64::try_from(*count).map_or(RowCountEstimate::Unknown, RowCountEstimate::Approximate)
            }
            Some(Bson::Double(count)) if *count >= 0.0 => RowCountEstimate::Approximate(*count as u64),
            _ => RowCountEstimate::Unknown,
        };
        Ok(TableEstimate {
            rows,
            heap_blocks: None,
        })
    }
}

/// Each collection's fields that its columns show as JSON, from the last
/// census of its fields, so a page or an export of it shows them as
/// Extended JSON straight from the BSON, which keeps an `int` apart from
/// a `long`.
#[derive(Debug, Default)]
pub(crate) struct JsonFields(Mutex<BTreeMap<(String, String), BTreeSet<String>>>);

impl JsonFields {
    /// Keep the fields among a collection's columns that are JSON.
    pub(crate) fn remember(&self, database: &str, collection: &str, columns: &[ColumnInfo]) -> BTreeSet<String> {
        let fields: BTreeSet<String> = columns
            .iter()
            .filter(|column| matches!(column.column_type.kind, ColumnKind::Json { .. }))
            .map(|column| column.name.clone())
            .collect();
        self.0
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert((database.to_owned(), collection.to_owned()), fields.clone());
        fields
    }

    /// The JSON fields of the collection `planned` reads. A connection
    /// that has not read them, as a new one after a reconnect has not,
    /// takes the census first in the same call, so it shows the fields the
    /// columns it was handed show as JSON.
    pub(crate) async fn of(&self, planned: &Plan, reader: &mut Reader<'_>) -> Result<BTreeSet<String>, DriverError> {
        let Some((database, collection)) = planned.collection() else {
            return Ok(BTreeSet::new());
        };
        let known = self
            .0
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&(database.to_owned(), collection.to_owned()))
            .cloned();
        if let Some(fields) = known {
            return Ok(fields);
        }
        let columns = reader.fields(database, collection).await?;
        Ok(self.remember(database, collection, &columns))
    }
}

/// What a collection is, as `listCollections` says.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CollectionType {
    Collection,
    /// Takes no writes, and its documents are named by nothing a write
    /// could reach.
    View,
    /// Holds measurements whose `_id` the server does not keep unique, so
    /// it cannot name one for a save or a page.
    TimeSeries,
}

impl CollectionType {
    /// Whether `_id` names one document.
    pub(crate) fn keyed(self) -> bool {
        self == Self::Collection
    }
}

/// The stages that tally the fields of the documents before them, each
/// with the types it holds and the least position a document puts it at,
/// for `columns_from`.
pub(crate) fn census_stages() -> [Document; 3] {
    [
        doc! { "$project": { "_id": 0_i32, "field": { "$objectToArray": "$$ROOT" } } },
        doc! { "$unwind": { "path": "$field", "includeArrayIndex": "position" } },
        doc! { "$group": {
            "_id": { "name": "$field.k", "type": census_type() },
            "position": { "$min": "$position" },
        } },
    ]
}

/// A field value's `$type`, or `uuid` for a UUID. `$type` names every
/// binary subtype `binData` and `$subtype` is new in MongoDB 8.3, but BSON
/// orders binary data by length, then subtype, then bytes, so a UUID is
/// a value between the least and the greatest 16-byte subtype 4 values.
fn census_type() -> Document {
    let uuid = |byte: u8| {
        Bson::Binary(Binary {
            subtype: BinarySubtype::Uuid,
            bytes: vec![byte; 16],
        })
    };
    doc! { "$cond": {
        "if": { "$and": [
            { "$eq": [{ "$type": "$field.v" }, "binData"] },
            { "$gte": ["$field.v", uuid(0x00)] },
            { "$lte": ["$field.v", uuid(0xff)] },
        ] },
        "then": "uuid",
        "else": { "$type": "$field.v" },
    } }
}

/// The columns of a collection whose first documents tallied `tallies`,
/// `_id` among them even when they hold none, as every document has one.
fn collection_columns(tallies: &[Document]) -> Vec<ColumnInfo> {
    let mut columns = columns_from(tallies);
    if !columns.iter().any(|column| column.name == "_id") {
        columns.insert(0, field_column("_id", &["objectId"].into_iter().collect()));
    }
    columns
}

/// The columns the fields a census tallied make, in the order the
/// documents place them, `_id` first where they hold one.
pub(crate) fn columns_from(tallies: &[Document]) -> Vec<ColumnInfo> {
    let mut fields: BTreeMap<String, (i64, BTreeSet<&'static str>)> = BTreeMap::new();
    for tally in tallies {
        let Ok(key) = tally.get_document("_id") else {
            continue;
        };
        let (Ok(name), Ok(kind)) = (key.get_str("name"), key.get_str("type")) else {
            continue;
        };
        let position = match tally.get("position") {
            Some(Bson::Int64(position)) => *position,
            Some(Bson::Int32(position)) => i64::from(*position),
            _ => i64::MAX,
        };
        let alias = alias_named(kind);
        let entry = fields.entry(name.to_owned()).or_insert((position, BTreeSet::new()));
        entry.0 = entry.0.min(position);
        entry.1.insert(alias);
    }
    let mut ordered: Vec<(String, (i64, BTreeSet<&'static str>))> = fields.into_iter().collect();
    ordered.sort_by(|(left_name, (left, _)), (right_name, (right, _))| {
        (left_name != "_id", left, left_name).cmp(&(right_name != "_id", right, right_name))
    });
    ordered
        .iter()
        .map(|(name, (_, aliases))| field_column(name, aliases))
        .collect()
}

/// A `$type` name the server reported, as one of the names the types
/// module knows.
fn alias_named(name: &str) -> &'static str {
    let sample = match name {
        "double" => Bson::Double(0.0),
        "string" => Bson::String(String::new()),
        "object" => Bson::Document(Document::new()),
        "array" => Bson::Array(Vec::new()),
        "objectId" => Bson::ObjectId(bson::oid::ObjectId::from_bytes([0; 12])),
        "bool" => Bson::Boolean(false),
        "date" => Bson::DateTime(bson::DateTime::from_millis(0)),
        "null" => Bson::Null,
        "int" => Bson::Int32(0),
        "long" => Bson::Int64(0),
        "decimal" => Bson::Decimal128(bson::Decimal128::from_bytes([0; 16])),
        "uuid" => return "uuid",
        "binData" => return "binData",
        "timestamp" => return "timestamp",
        "regex" => return "regex",
        _ => return "mixed",
    };
    type_alias(&sample)
}

fn index_info(entry: &Document) -> Option<IndexInfo> {
    let name = entry.get_str("name").ok()?.to_owned();
    let key = entry.get_document("key").ok()?;
    let keys = key
        .iter()
        .map(|(field, direction)| match direction {
            Bson::Int32(number) => IndexKey::Column {
                name: field.clone(),
                descending: *number < 0,
            },
            Bson::Int64(number) => IndexKey::Column {
                name: field.clone(),
                descending: *number < 0,
            },
            Bson::Double(number) => IndexKey::Column {
                name: field.clone(),
                descending: *number < 0.0,
            },
            other => IndexKey::Expression {
                sql: format!("{field}: {other}"),
                descending: false,
            },
        })
        .collect();
    let primary = name == "_id_";
    let predicate = entry
        .get_document("partialFilterExpression")
        .ok()
        .map(|filter| crate::extended_json::extended_json(&Bson::Document(filter.clone())));
    Some(IndexInfo {
        unique: primary || entry.get_bool("unique").unwrap_or(false),
        primary,
        name,
        keys,
        predicate,
        definition: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tally(name: &str, kind: &str, position: i64) -> Document {
        doc! { "_id": { "name": name, "type": kind }, "position": position }
    }

    #[test]
    fn fields_come_in_the_order_documents_place_them_with_id_first() {
        let tallies = [
            tally("b", "string", 2),
            tally("_id", "objectId", 0),
            tally("a", "int", 1),
            tally("a", "long", 3),
            tally("c", "string", 1),
            tally("c", "int", 4),
        ];

        let columns = columns_from(&tallies);

        let names: Vec<&str> = columns.iter().map(|column| column.name.as_str()).collect();
        assert_eq!(names, ["_id", "a", "c", "b"]);
        assert!(
            matches!(columns[1].column_type.kind, ColumnKind::Json { .. }),
            "an int and a long"
        );
        assert!(
            matches!(columns[2].column_type.kind, ColumnKind::Json { .. }),
            "a mixed field"
        );
        assert_eq!(columns[3].column_type.name, "string");
        assert!(columns[0].primary_key);
    }

    #[test]
    fn a_uuid_tally_is_a_uuid_column_unless_other_binary_data_shares_it() {
        let tallies = [
            tally("_id", "uuid", 0),
            tally("blob", "uuid", 1),
            tally("blob", "binData", 1),
        ];

        let columns = columns_from(&tallies);

        assert_eq!(columns[0].column_type.kind, ColumnKind::Uuid);
        assert!(matches!(columns[1].column_type.kind, ColumnKind::Json { .. }));
    }

    #[test]
    fn an_empty_collection_still_has_its_id() {
        let columns = collection_columns(&[]);

        assert_eq!(columns.len(), 1);
        assert_eq!(columns[0].name, "_id");
    }

    #[test]
    fn a_census_of_documents_without_an_id_names_only_their_fields() {
        let names = |tallies: &[Document]| -> Vec<String> {
            columns_from(tallies).into_iter().map(|column| column.name).collect()
        };

        assert!(names(&[]).is_empty());
        assert_eq!(names(&[tally("total", "int", 0)]), ["total"]);
    }

    #[test]
    fn an_index_lists_its_keys_and_uniqueness() {
        let index =
            index_info(&doc! { "v": 2_i32, "key": { "a": 1_i32, "b": -1_i32 }, "name": "a_1_b_-1", "unique": true })
                .expect("an index");

        assert!(index.unique && !index.primary);
        assert_eq!(index.keys.len(), 2);
        assert!(index.keys[1].descending());
        assert!(index_info(&doc! { "key": { "_id": 1_i32 }, "name": "_id_" }).is_some_and(|index| index.primary));
    }
}
