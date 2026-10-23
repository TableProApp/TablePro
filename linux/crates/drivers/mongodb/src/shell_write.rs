use bson::oid::ObjectId;
use bson::{Bson, Document, doc};
use tablepro_core::sql_syntax::mongo::{ShellMethod, ShellValue};
use tablepro_core::statement::BoundParam;
use tablepro_core::{DriverError, UnsupportedFeature};

use crate::errors::value_error;
use crate::shell_command::{Plan, Reply, WriteKind};
use crate::to_bson::{ValueError, to_bson};

/// Options a single update or delete statement of the server takes.
const STATEMENT_OPTIONS: [&str; 4] = ["collation", "hint", "arrayFilters", "upsert"];

/// A method's arguments as BSON.
struct Args<'a> {
    method: &'a ShellMethod,
    params: &'a [BoundParam],
}

impl Args<'_> {
    fn arg(&self, index: usize) -> Result<Option<Bson>, DriverError> {
        self.method
            .arg(index)
            .filter(|value| !matches!(value, ShellValue::Null))
            .map(|value| to_bson(value, self.params).map_err(value_error))
            .transpose()
    }

    /// Argument `index` as a document, an empty one when it is left out.
    fn document(&self, index: usize) -> Result<Document, DriverError> {
        match self.arg(index)? {
            None => Ok(Document::new()),
            Some(Bson::Document(document)) => Ok(document),
            Some(_) => Err(shape(self.method, index, "a document")),
        }
    }
}

/// A collection method that writes, as the write command it is.
pub(crate) fn write(
    method: &ShellMethod,
    database: &str,
    collection: &str,
    params: &[BoundParam],
) -> Result<Plan, DriverError> {
    let args = Args { method, params };
    let name = collection.to_owned();
    let (command, reply) = match method.name.as_str() {
        "insertOne" | "insertMany" | "insert" => insert_call(&args, name)?,
        "updateOne" | "updateMany" | "replaceOne" | "update" => update_call(&args, name)?,
        "deleteOne" | "deleteMany" | "remove" => delete_call(&args, name)?,
        "findOneAndUpdate" | "findOneAndReplace" | "findOneAndDelete" | "findAndModify" => {
            find_and_modify(method, name, args.arg(0)?, args.arg(1)?, args.document(2)?)?
        }
        "createIndex" | "createIndexes" | "dropIndex" | "dropIndexes" | "hideIndex" | "unhideIndex" => {
            index_call(&args, name)?
        }
        "drop" => (doc! { "drop": name }, Reply::Whole),
        "renameCollection" => return rename(&args, database, collection),
        "bulkWrite" => return Err(unsupported("bulkWrite(); run each write on its own")),
        _ => return Err(unsupported("this method")),
    };
    Ok(Plan::Command {
        database: database.to_owned(),
        command,
        reply,
    })
}

fn insert_call(args: &Args<'_>, name: String) -> Result<(Document, Reply), DriverError> {
    let method = args.method;
    let documents = match (method.name.as_str(), args.arg(0)?) {
        ("insertOne" | "insert", Some(Bson::Document(document))) => vec![document],
        ("insertMany" | "insert", Some(Bson::Array(items))) => items
            .into_iter()
            .map(|item| match item {
                Bson::Document(document) => Ok(document),
                _ => Err(shape(method, 0, "documents")),
            })
            .collect::<Result<Vec<_>, _>>()?,
        _ => return Err(shape(method, 0, "a document")),
    };
    Ok(insert(name, documents, &args.document(1)?))
}

fn update_call(args: &Args<'_>, name: String) -> Result<(Document, Reply), DriverError> {
    let options = args.document(2)?;
    let multi = match args.method.name.as_str() {
        "updateMany" => true,
        "update" => options.get_bool("multi").unwrap_or(false),
        _ => false,
    };
    let update = match args.arg(1)? {
        Some(update @ (Bson::Document(_) | Bson::Array(_))) => update,
        _ => return Err(shape(args.method, 1, "an update document or pipeline")),
    };
    let mut statement = doc! { "q": args.document(0)?, "u": update, "multi": multi };
    copy_options(&options, &mut statement);
    Ok((
        doc! { "update": name, "updates": [statement] },
        Reply::Write(WriteKind::Update),
    ))
}

fn delete_call(args: &Args<'_>, name: String) -> Result<(Document, Reply), DriverError> {
    // `remove` takes its `justOne` alone as well as in its options.
    let (options, just_one) = match (args.method.name.as_str(), args.arg(1)?) {
        ("remove", Some(Bson::Boolean(just_one))) => (Document::new(), just_one),
        _ => {
            let options = args.document(1)?;
            let just_one = options.get_bool("justOne").unwrap_or(false);
            (options, just_one)
        }
    };
    let one = match args.method.name.as_str() {
        "deleteOne" => true,
        "remove" => just_one,
        _ => false,
    };
    let mut statement = doc! { "q": args.document(0)?, "limit": i32::from(one) };
    copy_options(&options, &mut statement);
    Ok((
        doc! { "delete": name, "deletes": [statement] },
        Reply::Write(WriteKind::Delete),
    ))
}

fn index_call(args: &Args<'_>, name: String) -> Result<(Document, Reply), DriverError> {
    let method = args.method;
    let command = match method.name.as_str() {
        "createIndex" => create_indexes(name, vec![Bson::Document(args.document(0)?)], &args.document(1)?)?,
        "createIndexes" => match args.arg(0)? {
            Some(Bson::Array(keys)) => create_indexes(name, keys, &args.document(1)?)?,
            _ => return Err(shape(method, 0, "an array of index keys")),
        },
        "dropIndex" | "dropIndexes" => {
            let index = args.arg(0)?.unwrap_or_else(|| Bson::String("*".to_owned()));
            doc! { "dropIndexes": name, "index": index }
        }
        _ => {
            let index = args.arg(0)?.unwrap_or(Bson::Null);
            let key = match index {
                Bson::String(_) => "name",
                _ => "keyPattern",
            };
            let hidden = method.name == "hideIndex";
            doc! { "collMod": name, "index": { key: index, "hidden": hidden } }
        }
    };
    Ok((command, Reply::Whole))
}

/// A rename, which the server takes in `admin` with both full names.
fn rename(args: &Args<'_>, database: &str, collection: &str) -> Result<Plan, DriverError> {
    let target = match args.arg(0)? {
        Some(Bson::String(target)) => target,
        _ => return Err(shape(args.method, 0, "the new name in quotes")),
    };
    let drop_target = matches!(args.arg(1)?, Some(Bson::Boolean(true)));
    Ok(Plan::Command {
        database: "admin".to_owned(),
        command: doc! {
            "renameCollection": format!("{database}.{collection}"),
            "to": format!("{database}.{target}"),
            "dropTarget": drop_target,
        },
        reply: Reply::Whole,
    })
}

/// An insert. A document with no `_id` gets one here, as every driver
/// gives it, so the reply can name what was inserted.
fn insert(collection: String, mut documents: Vec<Document>, options: &Document) -> (Document, Reply) {
    let mut ids = Vec::with_capacity(documents.len());
    for document in &mut documents {
        let id = match document.get("_id") {
            Some(id) => id.clone(),
            None => {
                let id = Bson::ObjectId(ObjectId::new());
                let mut with_id = doc! { "_id": id.clone() };
                with_id.extend(std::mem::take(document));
                *document = with_id;
                id
            }
        };
        ids.push(id);
    }
    let mut command = doc! { "insert": collection, "documents": documents };
    if let Ok(ordered) = options.get_bool("ordered") {
        command.insert("ordered", ordered);
    }
    (command, Reply::Write(WriteKind::Insert(ids)))
}

fn copy_options(options: &Document, statement: &mut Document) {
    for option in STATEMENT_OPTIONS {
        if let Some(value) = options.get(option) {
            statement.insert(option, value.clone());
        }
    }
}

fn find_and_modify(
    method: &ShellMethod,
    collection: String,
    first: Option<Bson>,
    second: Option<Bson>,
    options: Document,
) -> Result<(Document, Reply), DriverError> {
    let mut command = doc! { "findAndModify": collection };
    let as_document = |value: Option<Bson>, index: usize| match value {
        None => Ok(Document::new()),
        Some(Bson::Document(document)) => Ok(document),
        Some(_) => Err(shape(method, index, "a document")),
    };
    match method.name.as_str() {
        "findAndModify" => {
            let mut fields = as_document(first, 0)?;
            // The collection is the one the statement names.
            fields.remove("findAndModify");
            command.extend(fields);
        }
        name => {
            command.insert("query", as_document(first, 0)?);
            let options = match name {
                "findOneAndDelete" => {
                    command.insert("remove", true);
                    as_document(second, 1)?
                }
                _ => {
                    command.insert("update", second.ok_or_else(|| shape(method, 1, "an update"))?);
                    options
                }
            };
            for (key, value) in options {
                match key.as_str() {
                    "projection" => command.insert("fields", value),
                    "returnDocument" => command.insert("new", value.as_str() == Some("after")),
                    "returnNewDocument" => command.insert("new", value),
                    "findAndModify" => continue,
                    _ => command.insert(key, value),
                };
            }
        }
    }
    Ok((command, Reply::Field("value")))
}

/// Indexes named as mongosh names them, each key and direction joined by
/// underscores, unless the options name one.
fn create_indexes(collection: String, keys: Vec<Bson>, options: &Document) -> Result<Document, DriverError> {
    let mut indexes = Vec::with_capacity(keys.len());
    for key in keys {
        let Bson::Document(key) = key else {
            return Err(value_error(ValueError("an index key is a document".to_owned())));
        };
        let name = key
            .iter()
            .map(|(field, direction)| match direction {
                Bson::String(kind) => format!("{field}_{kind}"),
                Bson::Int32(number) => format!("{field}_{number}"),
                Bson::Int64(number) => format!("{field}_{number}"),
                Bson::Double(number) => format!("{field}_{number}"),
                other => format!("{field}_{other}"),
            })
            .collect::<Vec<_>>()
            .join("_");
        let mut index = doc! { "key": key, "name": name };
        index.extend(options.clone());
        indexes.push(Bson::Document(index));
    }
    Ok(doc! { "createIndexes": collection, "indexes": indexes })
}

fn shape(method: &ShellMethod, index: usize, expected: &str) -> DriverError {
    value_error(ValueError(format!(
        "{}() takes {expected} as argument {}",
        method.name,
        index + 1
    )))
}

fn unsupported(command: &'static str) -> DriverError {
    DriverError::Unsupported {
        feature: UnsupportedFeature::EditorCommand { command },
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::sql_syntax::mongo::{ShellStatement, parse_statement};

    use super::*;

    fn planned(text: &str) -> Plan {
        let Ok(ShellStatement::Call(call)) = parse_statement(text) else {
            panic!("{text} is not a call");
        };
        let method = call.operation().expect("a method");
        write(method, "shop", call.collection.as_deref().unwrap_or_default(), &[]).expect("a plan")
    }

    #[test]
    fn an_insert_gives_each_document_an_id_first() {
        let Plan::Command { command, reply, .. } = planned("db.users.insertMany([{name: 'a'}, {_id: 7, name: 'b'}])")
        else {
            panic!("not a command");
        };
        let documents = command.get_array("documents").expect("documents");
        let first = documents[0].as_document().expect("a document");
        assert_eq!(first.keys().collect::<Vec<_>>(), ["_id", "name"]);
        let Reply::Write(WriteKind::Insert(ids)) = reply else {
            panic!("not an insert");
        };
        assert_eq!(ids[1], Bson::Int32(7));
    }

    #[test]
    fn remove_takes_just_one_alone_or_in_its_options() {
        for (text, limit) in [
            ("db.users.remove({a: 1}, true)", 1_i32),
            ("db.users.remove({a: 1}, false)", 0),
            ("db.users.remove({a: 1}, {justOne: true})", 1),
            ("db.users.remove({a: 1})", 0),
        ] {
            let Plan::Command { command, .. } = planned(text) else {
                panic!("{text} is not a command");
            };
            let deletes = command.get_array("deletes").expect("deletes");
            let limit_of = deletes[0].as_document().and_then(|delete| delete.get_i32("limit").ok());
            assert_eq!(limit_of, Some(limit), "{text}");
        }
    }

    #[test]
    fn updates_and_deletes_are_their_write_commands() {
        let Plan::Command { command, .. } = planned("db.users.updateMany({a: 1}, {$set: {b: 2}}, {upsert: true})")
        else {
            panic!("not a command");
        };
        assert_eq!(
            command,
            doc! { "update": "users", "updates": [{ "q": { "a": 1_i32 }, "u": { "$set": { "b": 2_i32 } }, "multi": true, "upsert": true }] }
        );
        let Plan::Command { command, .. } = planned("db.users.deleteOne({_id: 3})") else {
            panic!("not a command");
        };
        assert_eq!(
            command,
            doc! { "delete": "users", "deletes": [{ "q": { "_id": 3_i32 }, "limit": 1_i32 }] }
        );
        let Plan::Command { command, .. } = planned("db.users.createIndex({a: 1, b: -1}, {unique: true})") else {
            panic!("not a command");
        };
        assert_eq!(
            command.get_array("indexes").expect("indexes")[0],
            Bson::Document(doc! { "key": { "a": 1_i32, "b": -1_i32 }, "name": "a_1_b_-1", "unique": true })
        );
    }

    #[test]
    fn find_one_and_update_asks_for_the_document_after_it() {
        let Plan::Command { command, reply, .. } =
            planned("db.users.findOneAndUpdate({a: 1}, {$inc: {n: 1}}, {returnDocument: 'after'})")
        else {
            panic!("not a command");
        };
        assert_eq!(command.get_bool("new").ok(), Some(true));
        assert_eq!(reply, Reply::Field("value"));
    }
}
