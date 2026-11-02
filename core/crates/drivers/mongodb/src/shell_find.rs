use bson::{Bson, Document, doc};
use tablepro_core::sql_syntax::mongo::{ShellCall, ShellMethod};
use tablepro_core::statement::BoundParam;
use tablepro_core::{DriverError, UnsupportedFeature};

use crate::errors::value_error;
use crate::shell_command::{Columns, NamedColumn, Plan, Reply};
use crate::to_bson::{ValueError, to_bson};

/// Cursor methods that set one option of the `find` command, by the
/// method's name and the command's.
const OPTIONS: [(&str, &str); 14] = [
    ("sort", "sort"),
    ("limit", "limit"),
    ("skip", "skip"),
    ("projection", "projection"),
    ("hint", "hint"),
    ("maxTimeMS", "maxTimeMS"),
    ("batchSize", "batchSize"),
    ("comment", "comment"),
    ("collation", "collation"),
    ("allowDiskUse", "allowDiskUse"),
    ("min", "min"),
    ("max", "max"),
    ("returnKey", "returnKey"),
    ("showRecordId", "showRecordId"),
];

/// Cursor methods that change nothing the server is asked.
const NO_OPS: [&str; 3] = ["toArray", "pretty", "noCursorTimeout"];

/// `find` or `findOne` with the cursor methods after it, as one `find`
/// command: `sort`, `limit` and the rest become its options, `count()`
/// counts what it matches and `explain()` asks the planner.
pub(crate) fn find(
    call: &ShellCall,
    database: &str,
    collection: &str,
    params: &[BoundParam],
) -> Result<Plan, DriverError> {
    let Some(operation) = call.operation() else {
        return Err(unsupported("find"));
    };
    let mut command = doc! { "find": collection, "filter": document_arg(operation, 0, params)? };
    if let Some(projection) = optional_document(operation, 1, params)? {
        command.insert("projection", projection);
    }
    if let Some(mut options) = optional_document(operation, 2, params)? {
        // The collection is the one the statement names.
        options.remove("find");
        command.extend(options);
    }
    if operation.name == "findOne" {
        command.insert("limit", 1_i32);
        command.insert("singleBatch", true);
    }
    let mut counted = false;
    let mut explained = None;
    for method in call.modifiers() {
        let name = method.name.as_str();
        if let Some((_, option)) = OPTIONS.iter().find(|(cursor, _)| *cursor == name) {
            let value = match method.arg(0) {
                Some(value) => to_bson(value, params).map_err(value_error)?,
                None => Bson::Boolean(true),
            };
            command.insert(*option, value);
        } else if matches!(name, "count" | "itcount" | "size") {
            counted = true;
        } else if name == "explain" {
            let verbosity = match method.arg(0) {
                Some(value) => to_bson(value, params).map_err(value_error)?,
                None => Bson::String("queryPlanner".to_owned()),
            };
            explained = Some(verbosity);
        } else if name == "readConcern" {
            let level = to_bson(
                method
                    .arg(0)
                    .unwrap_or(&tablepro_core::sql_syntax::mongo::ShellValue::Null),
                params,
            )
            .map_err(value_error)?;
            command.insert("readConcern", doc! { "level": level });
        } else if !NO_OPS.contains(&name) {
            return Err(unsupported("this cursor method"));
        }
    }
    if let Some(verbosity) = explained {
        return Ok(Plan::Command {
            database: database.to_owned(),
            command: doc! { "explain": command, "verbosity": verbosity },
            reply: Reply::Whole,
        });
    }
    if counted {
        return Ok(count(database, collection, command));
    }
    let columns = command
        .get_document("projection")
        .map_or(Columns::Discovered, projected_columns);
    Ok(Plan::Cursor {
        database: database.to_owned(),
        command,
        columns,
        counted: false,
    })
}

/// A cursor's `count()`: how many documents the filter matches, past its
/// `skip` and up to its `limit` where it has them.
fn count(database: &str, collection: &str, find: Document) -> Plan {
    let mut pipeline = vec![Bson::Document(
        doc! { "$match": find.get("filter").cloned().unwrap_or(Bson::Document(Document::new())) },
    )];
    for stage in ["skip", "limit"] {
        if let Some(value) = find.get(stage) {
            pipeline.push(Bson::Document(doc! { format!("${stage}"): value.clone() }));
        }
    }
    pipeline.push(Bson::Document(
        doc! { "$group": { "_id": 1_i32, "n": { "$sum": 1_i32 } } },
    ));
    Plan::Cursor {
        database: database.to_owned(),
        command: doc! { "aggregate": collection, "pipeline": pipeline, "cursor": {} },
        columns: Columns::Discovered,
        counted: true,
    }
}

/// The columns a projection names, in its order: `_id` first unless it
/// is left out, then every field it includes or computes, by its
/// top-level name. A projection that leaves fields out, or returns every
/// field, names no columns, so they are found from the documents.
pub(crate) fn projected_columns(projection: &Document) -> Columns {
    let mut named: Vec<NamedColumn> = Vec::new();
    for (key, value) in projection {
        if key == "_id" {
            continue;
        }
        // An exclusion keeps every other field, and so does an array
        // operator in a projection that includes nothing else.
        if excluded(value) || shapes_an_array(value) {
            return Columns::Discovered;
        }
        let column = match aliased_field(value) {
            Some(name) => NamedColumn {
                key: key.clone(),
                name,
                json: false,
            },
            None => NamedColumn::field(key.split('.').next().unwrap_or(key)),
        };
        if !named.iter().any(|known| known.key == column.key) {
            named.push(column);
        }
    }
    let id = projection.get("_id");
    if named.is_empty() && id.is_none_or(excluded) {
        return Columns::Discovered;
    }
    let mut columns = Vec::with_capacity(named.len() + 1);
    if !id.is_some_and(excluded) {
        columns.push(NamedColumn::field("_id"));
    }
    columns.extend(named);
    Columns::Named(columns)
}

fn excluded(value: &Bson) -> bool {
    match value {
        Bson::Boolean(flag) => !flag,
        Bson::Int32(0) | Bson::Int64(0) => true,
        Bson::Double(number) => *number == 0.0,
        _ => false,
    }
}

fn shapes_an_array(value: &Bson) -> bool {
    value
        .as_document()
        .and_then(|operator| operator.keys().next())
        .is_some_and(|name| matches!(name.as_str(), "$slice" | "$elemMatch"))
}

/// The field a `$getField` of the whole document reads, which is how a
/// generated page reads a field whose name a projection cannot write.
fn aliased_field(value: &Bson) -> Option<String> {
    let lookup = value.as_document()?.get_document("$getField").ok()?;
    if lookup.get_str("input").ok()? != "$$ROOT" {
        return None;
    }
    match lookup.get("field")? {
        Bson::Document(literal) => literal.get_str("$literal").ok().map(str::to_owned),
        Bson::String(name) => Some(name.clone()),
        _ => None,
    }
}

fn document_arg(method: &ShellMethod, index: usize, params: &[BoundParam]) -> Result<Document, DriverError> {
    Ok(optional_document(method, index, params)?.unwrap_or_default())
}

fn optional_document(
    method: &ShellMethod,
    index: usize,
    params: &[BoundParam],
) -> Result<Option<Document>, DriverError> {
    match method.arg(index) {
        None | Some(tablepro_core::sql_syntax::mongo::ShellValue::Null) => Ok(None),
        Some(value) => match to_bson(value, params).map_err(value_error)? {
            Bson::Document(document) => Ok(Some(document)),
            _ => Err(value_error(ValueError(format!(
                "{}() takes a document as argument {}",
                method.name,
                index + 1
            )))),
        },
    }
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
        find(&call, "shop", call.collection.as_deref().unwrap_or_default(), &[]).expect("a plan")
    }

    #[test]
    fn cursor_methods_become_the_finds_options() {
        let Plan::Cursor {
            command,
            columns,
            counted,
            ..
        } = planned("db.users.find({age: {$gt: 30}}, {name: 1}).sort({name: -1}).skip(5).limit(10).pretty()")
        else {
            panic!("not a cursor");
        };

        assert_eq!(
            command,
            doc! {
                "find": "users",
                "filter": { "age": { "$gt": 30_i32 } },
                "projection": { "name": 1_i32 },
                "sort": { "name": -1_i32 },
                "skip": 5_i32,
                "limit": 10_i32,
            }
        );
        assert_eq!(
            columns,
            Columns::Named(vec![NamedColumn::field("_id"), NamedColumn::field("name")])
        );
        assert!(!counted);
    }

    #[test]
    fn find_one_reads_one_and_count_counts() {
        let Plan::Cursor { command, .. } = planned("db.users.findOne({a: 1})") else {
            panic!("not a cursor");
        };
        assert_eq!(command.get_i32("limit").ok(), Some(1));

        let Plan::Cursor { command, counted, .. } = planned("db.users.find({a: 1}).limit(5).count()") else {
            panic!("not a cursor");
        };
        assert!(counted);
        assert_eq!(command.get_str("aggregate").ok(), Some("users"));

        assert!(matches!(
            planned("db.users.find().explain('executionStats')"),
            Plan::Command { .. }
        ));
    }

    #[test]
    fn a_projection_names_the_columns_it_keeps() {
        let names = |projection: Document| match projected_columns(&projection) {
            Columns::Named(columns) => Some(
                columns
                    .into_iter()
                    .map(|column| (column.key, column.name))
                    .collect::<Vec<_>>(),
            ),
            _ => None,
        };
        let same = |names: &[&str]| Some(names.iter().map(|name| (name.to_string(), name.to_string())).collect());

        assert_eq!(names(doc! { "_id": 0_i32, "b": 1_i32, "a": "$x" }), same(&["b", "a"]));
        assert_eq!(
            names(doc! { "address.city": 1_i32, "address.zip": 1_i32 }),
            same(&["_id", "address"])
        );
        assert_eq!(names(doc! { "_id": 1_i32 }), same(&["_id"]));
        assert_eq!(names(doc! { "secret": 0_i32 }), None, "an exclusion keeps the rest");
        assert_eq!(names(doc! { "_id": 0_i32 }), None, "every field but _id");
        assert_eq!(names(doc! {}), None, "every field");
        assert_eq!(names(doc! { "tags": { "$slice": 2_i32 } }), None);
        assert_eq!(
            names(doc! { "__field_1": { "$getField": { "field": { "$literal": "a.b" }, "input": "$$ROOT" } } }),
            Some(vec![
                ("_id".to_owned(), "_id".to_owned()),
                ("__field_1".to_owned(), "a.b".to_owned())
            ])
        );
    }
}
