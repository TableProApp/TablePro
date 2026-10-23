use std::collections::BTreeSet;

use bson::{Bson, Document, doc};
use tablepro_core::sql_syntax::mongo::{CallRoot, ShellCall, ShellMethod, ShellStatement, ShellValue, ShowTarget};
use tablepro_core::statement::BoundParam;
use tablepro_core::{DriverError, UnsupportedFeature};

use crate::errors::value_error;
use crate::to_bson::{ValueError, to_bson};

/// The columns of a cursor's documents.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Columns {
    /// Named by the statement's projection, in its order.
    Named(Vec<NamedColumn>),
    /// Every top-level field, in the order the documents first show it.
    Discovered,
    /// One column, each value a row of its own.
    Values(String),
}

/// A column a projection names.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct NamedColumn {
    /// The field the documents hold it in, which is an alias for a field
    /// whose own name a projection cannot write.
    pub(crate) key: String,
    /// The field's own name, which the column shows.
    pub(crate) name: String,
    /// Shown as Extended JSON whatever its value's type, as the grid
    /// shows a field of nested or mixed values, so a `long` stays one
    /// through an edit.
    pub(crate) json: bool,
}

impl NamedColumn {
    pub(crate) fn field(name: impl Into<String>) -> Self {
        let name = name.into();
        Self {
            key: name.clone(),
            name,
            json: false,
        }
    }
}

/// What a reply shows once a command answers.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Reply {
    /// The reply itself, as one row.
    Whole,
    /// The documents in one field of the reply, a row each.
    Rows(&'static str),
    /// The values in one field of the reply, a row each.
    Values { field: &'static str, column: String },
    /// One field's value, as one row.
    Field(&'static str),
    /// A count in one field of the reply.
    Count(&'static str),
    /// What a write did: its counts, and the ids it made.
    Write(WriteKind),
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) enum WriteKind {
    /// The ids the driver gave the documents, which the reply leaves out.
    Insert(Vec<Bson>),
    Update,
    Delete,
}

/// A statement as the server is asked it.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Plan {
    /// `use`: the editor's database from here on. Nothing is sent.
    Use(String),
    /// A command that answers with a cursor.
    Cursor {
        database: String,
        command: Document,
        columns: Columns,
        /// `countDocuments` and a cursor's `count()`: the count of what
        /// the cursor holds.
        counted: bool,
    },
    Command {
        database: String,
        command: Document,
        reply: Reply,
    },
}

impl Plan {
    /// The collection a cursor reads, in its database.
    pub(crate) fn collection(&self) -> Option<(&str, &str)> {
        let Self::Cursor { database, command, .. } = self else {
            return None;
        };
        let collection = command.get_str("aggregate").or_else(|_| command.get_str("find")).ok()?;
        Some((database, collection))
    }

    /// Show `fields` as Extended JSON.
    pub(crate) fn show_as_json(&mut self, fields: &BTreeSet<String>) {
        if let Self::Cursor {
            columns: Columns::Named(columns),
            ..
        } = self
        {
            for column in columns {
                column.json |= fields.contains(&column.name);
            }
        }
    }

    /// Whether the cursor's columns are found from its documents.
    pub(crate) fn discovers_columns(&self) -> bool {
        matches!(
            self,
            Self::Cursor {
                columns: Columns::Discovered,
                counted: false,
                ..
            }
        )
    }

    /// Fix the columns a first read of the cursor found.
    pub(crate) fn name_columns(&mut self, names: Vec<String>) {
        if let Self::Cursor { columns, .. } = self {
            *columns = Columns::Named(names.into_iter().map(NamedColumn::field).collect());
        }
    }

    /// Bound the command by the server's own time limit, which stops it
    /// there when the deadline passes.
    pub(crate) fn limit_time(&mut self, millis: Option<i64>) {
        let (Self::Cursor { command, .. } | Self::Command { command, .. }) = self else {
            return;
        };
        let Some(millis) = millis else {
            return;
        };
        let explain = command.keys().next().is_some_and(|name| name == "explain");
        if !explain && !command.contains_key("maxTimeMS") {
            command.insert("maxTimeMS", Bson::Int64(millis.max(1)));
        }
    }
}

type Planned = Result<Plan, DriverError>;

/// The server command for a statement, run in `database` unless the
/// statement names another, with `$n` taken from `params`.
pub(crate) fn plan(statement: &ShellStatement, database: &str, params: &[BoundParam]) -> Planned {
    match statement {
        ShellStatement::Use(name) => Ok(Plan::Use(name.clone())),
        ShellStatement::Show(target) => Ok(show(*target, database)),
        ShellStatement::Call(call) => {
            let database = call.database.clone().unwrap_or_else(|| database.to_owned());
            let args = Args { params };
            match (call.root, &call.collection) {
                (CallRoot::Rs, _) => replica_set(call),
                (CallRoot::Db, Some(collection)) => collection_call(call, &database, collection, &args),
                (CallRoot::Db, None) => database_call(call, database, &args),
            }
        }
    }
}

fn show(target: ShowTarget, database: &str) -> Plan {
    match target {
        ShowTarget::Databases => Plan::Command {
            database: "admin".to_owned(),
            command: doc! { "listDatabases": 1_i32, "authorizedDatabases": true },
            reply: Reply::Rows("databases"),
        },
        ShowTarget::Collections => Plan::Cursor {
            database: database.to_owned(),
            command: doc! { "listCollections": 1_i32, "nameOnly": true, "authorizedCollections": true },
            columns: Columns::Named(vec![NamedColumn::field("name")]),
            counted: false,
        },
        ShowTarget::Users => Plan::Command {
            database: database.to_owned(),
            command: doc! { "usersInfo": 1_i32 },
            reply: Reply::Rows("users"),
        },
        ShowTarget::Roles => Plan::Command {
            database: database.to_owned(),
            command: doc! { "rolesInfo": 1_i32 },
            reply: Reply::Rows("roles"),
        },
    }
}

/// The arguments of a method, as BSON.
struct Args<'a> {
    params: &'a [BoundParam],
}

impl Args<'_> {
    fn bson(&self, value: &ShellValue) -> Result<Bson, DriverError> {
        to_bson(value, self.params).map_err(value_error)
    }

    /// Argument `index` as a document, an empty one when it is left out.
    fn document(&self, method: &ShellMethod, index: usize) -> Result<Document, DriverError> {
        match method.arg(index) {
            None | Some(ShellValue::Null) => Ok(Document::new()),
            Some(value) => match self.bson(value)? {
                Bson::Document(document) => Ok(document),
                _ => Err(value_error(ValueError(format!(
                    "{}() takes a document as argument {}",
                    method.name,
                    index + 1
                )))),
            },
        }
    }

    fn optional_document(&self, method: &ShellMethod, index: usize) -> Result<Option<Document>, DriverError> {
        match method.arg(index) {
            None | Some(ShellValue::Null) => Ok(None),
            Some(_) => self.document(method, index).map(Some),
        }
    }

    fn array(&self, method: &ShellMethod, index: usize) -> Result<Vec<Bson>, DriverError> {
        match method.arg(index).map(|value| self.bson(value)).transpose()? {
            Some(Bson::Array(items)) => Ok(items),
            _ => Err(value_error(ValueError(format!(
                "{}() takes an array as argument {}",
                method.name,
                index + 1
            )))),
        }
    }

    fn text(&self, method: &ShellMethod, index: usize) -> Result<String, DriverError> {
        match method.arg(index).map(|value| self.bson(value)).transpose()? {
            Some(Bson::String(text)) => Ok(text),
            _ => Err(value_error(ValueError(format!(
                "{}() takes a name in quotes as argument {}",
                method.name,
                index + 1
            )))),
        }
    }
}

fn unsupported(command: &'static str) -> DriverError {
    DriverError::Unsupported {
        feature: UnsupportedFeature::EditorCommand { command },
    }
}

fn replica_set(call: &ShellCall) -> Planned {
    let Some(operation) = call.operation() else {
        return Err(unsupported("rs"));
    };
    let (command, reply) = match operation.name.as_str() {
        "status" => (doc! { "replSetGetStatus": 1_i32 }, Reply::Whole),
        "conf" | "config" => (doc! { "replSetGetConfig": 1_i32 }, Reply::Field("config")),
        "hello" | "isMaster" => (doc! { "hello": 1_i32 }, Reply::Whole),
        _ => return Err(unsupported("this rs helper")),
    };
    Ok(Plan::Command {
        database: "admin".to_owned(),
        command,
        reply,
    })
}

fn database_call(call: &ShellCall, database: String, args: &Args<'_>) -> Planned {
    let Some(method) = call.operation() else {
        return Err(unsupported("db"));
    };
    let command = |command: Document, reply: Reply| Plan::Command {
        database: database.clone(),
        command,
        reply,
    };
    let admin = |command: Document, reply: Reply| Plan::Command {
        database: "admin".to_owned(),
        command,
        reply,
    };
    Ok(match method.name.as_str() {
        "runCommand" => command(args.document(method, 0)?, Reply::Whole),
        "adminCommand" => admin(args.document(method, 0)?, Reply::Whole),
        "aggregate" => {
            let pipeline = args.array(method, 0)?;
            return aggregate(Bson::Int32(1), pipeline, args.document(method, 1)?, database, call);
        }
        "getCollectionNames" | "getCollectionInfos" => {
            let mut listed = doc! { "listCollections": 1_i32, "authorizedCollections": true };
            if method.name == "getCollectionNames" {
                listed.insert("nameOnly", true);
            }
            if let Some(filter) = args.optional_document(method, 0)? {
                listed.insert("filter", filter);
            }
            let columns = match method.name.as_str() {
                "getCollectionNames" => Columns::Named(vec![NamedColumn::field("name")]),
                _ => Columns::Discovered,
            };
            Plan::Cursor {
                database,
                command: listed,
                columns,
                counted: false,
            }
        }
        "createCollection" => {
            let mut create = doc! { "create": args.text(method, 0)? };
            create.extend(args.document(method, 1)?);
            command(create, Reply::Whole)
        }
        "createView" => {
            let mut create = doc! {
                "create": args.text(method, 0)?,
                "viewOn": args.text(method, 1)?,
                "pipeline": args.array(method, 2)?,
            };
            create.extend(args.document(method, 3)?);
            command(create, Reply::Whole)
        }
        "dropDatabase" => command(doc! { "dropDatabase": 1_i32 }, Reply::Whole),
        "stats" => command(doc! { "dbStats": 1_i32 }, Reply::Whole),
        "serverStatus" => admin(doc! { "serverStatus": 1_i32 }, Reply::Whole),
        "hostInfo" => admin(doc! { "hostInfo": 1_i32 }, Reply::Whole),
        "version" => admin(doc! { "buildInfo": 1_i32 }, Reply::Field("version")),
        "serverBuildInfo" => admin(doc! { "buildInfo": 1_i32 }, Reply::Whole),
        "hello" | "isMaster" => admin(doc! { "hello": 1_i32 }, Reply::Whole),
        "serverCmdLineOpts" => admin(doc! { "getCmdLineOpts": 1_i32 }, Reply::Whole),
        "currentOp" => {
            let mut current = doc! { "currentOp": 1_i32 };
            current.extend(args.document(method, 0)?);
            admin(current, Reply::Rows("inprog"))
        }
        "killOp" => admin(
            doc! { "killOp": 1_i32, "op": method.arg(0).map(|value| args.bson(value)).transpose()?.unwrap_or(Bson::Null) },
            Reply::Whole,
        ),
        "getProfilingStatus" => command(doc! { "profile": -1_i32 }, Reply::Whole),
        "setProfilingLevel" => {
            let level = method
                .arg(0)
                .map(|value| args.bson(value))
                .transpose()?
                .unwrap_or(Bson::Int32(0));
            let mut profile = doc! { "profile": level };
            profile.extend(args.document(method, 1)?);
            command(profile, Reply::Whole)
        }
        "getUsers" => command(doc! { "usersInfo": 1_i32 }, Reply::Rows("users")),
        "getUser" => command(doc! { "usersInfo": args.text(method, 0)? }, Reply::Rows("users")),
        "getRoles" => command(doc! { "rolesInfo": 1_i32 }, Reply::Rows("roles")),
        "getRole" => command(doc! { "rolesInfo": args.text(method, 0)? }, Reply::Rows("roles")),
        "listCommands" => command(doc! { "listCommands": 1_i32 }, Reply::Field("commands")),
        _ => return user_management(method, database, args),
    })
}

/// The methods that manage users, whose documents carry passwords.
fn user_management(method: &ShellMethod, database: String, args: &Args<'_>) -> Planned {
    let command = match method.name.as_str() {
        "createUser" => {
            let mut user = args.document(method, 0)?;
            let name = user.remove("user").unwrap_or(Bson::Null);
            let mut create = doc! { "createUser": name };
            create.extend(user);
            create
        }
        "updateUser" => {
            let mut update = doc! { "updateUser": args.text(method, 0)? };
            update.extend(args.document(method, 1)?);
            update
        }
        "changeUserPassword" => doc! { "updateUser": args.text(method, 0)?, "pwd": args.text(method, 1)? },
        "dropUser" => doc! { "dropUser": args.text(method, 0)? },
        "grantRolesToUser" => doc! { "grantRolesToUser": args.text(method, 0)?, "roles": args.array(method, 1)? },
        "revokeRolesFromUser" => {
            doc! { "revokeRolesFromUser": args.text(method, 0)?, "roles": args.array(method, 1)? }
        }
        "auth" => return Err(unsupported("auth(); the connection logs in with its own settings")),
        _ => return Err(unsupported("this method")),
    };
    Ok(Plan::Command {
        database,
        command,
        reply: Reply::Whole,
    })
}

fn collection_call(call: &ShellCall, database: &str, collection: &str, args: &Args<'_>) -> Planned {
    let Some(method) = call.operation() else {
        return Err(unsupported("a collection"));
    };
    let name = Bson::String(collection.to_owned());
    match method.name.as_str() {
        "find" | "findOne" => crate::shell_find::find(call, database, collection, args.params),
        "aggregate" => aggregate(
            name,
            args.array(method, 0)?,
            args.document(method, 1)?,
            database.to_owned(),
            call,
        ),
        "countDocuments" => {
            let options = args.document(method, 1)?;
            let mut pipeline = vec![Bson::Document(doc! { "$match": args.document(method, 0)? })];
            for stage in ["skip", "limit"] {
                if let Some(value) = options.get(stage) {
                    pipeline.push(Bson::Document(doc! { format!("${stage}"): value.clone() }));
                }
            }
            pipeline.push(Bson::Document(
                doc! { "$group": { "_id": 1_i32, "n": { "$sum": 1_i32 } } },
            ));
            let mut command = doc! { "aggregate": name, "pipeline": pipeline, "cursor": {} };
            for option in ["hint", "collation", "comment"] {
                if let Some(value) = options.get(option) {
                    command.insert(option, value.clone());
                }
            }
            Ok(Plan::Cursor {
                database: database.to_owned(),
                command,
                columns: Columns::Discovered,
                counted: true,
            })
        }
        "estimatedDocumentCount" => single(database, doc! { "count": name }, Reply::Count("n")),
        "count" => single(
            database,
            doc! { "count": name, "query": args.document(method, 0)? },
            Reply::Count("n"),
        ),
        "distinct" => {
            let key = args.text(method, 0)?;
            let command = doc! { "distinct": name, "key": key.clone(), "query": args.document(method, 1)? };
            single(
                database,
                command,
                Reply::Values {
                    field: "values",
                    column: key,
                },
            )
        }
        "getIndexes" | "getIndexSpecs" | "indexes" | "getIndexKeys" => Ok(Plan::Cursor {
            database: database.to_owned(),
            command: doc! { "listIndexes": name },
            columns: Columns::Discovered,
            counted: false,
        }),
        "stats" | "dataSize" | "storageSize" | "totalIndexSize" | "totalSize" | "isCapped" => {
            let reply = match method.name.as_str() {
                "dataSize" => Reply::Field("size"),
                "storageSize" => Reply::Field("storageSize"),
                "totalIndexSize" => Reply::Field("totalIndexSize"),
                "totalSize" => Reply::Field("totalSize"),
                "isCapped" => Reply::Field("capped"),
                _ => Reply::Whole,
            };
            single(database, doc! { "collStats": name }, reply)
        }
        _ => crate::shell_write::write(method, database, collection, args.params),
    }
}

fn single(database: &str, command: Document, reply: Reply) -> Planned {
    Ok(Plan::Command {
        database: database.to_owned(),
        command,
        reply,
    })
}

/// The options `aggregate()` takes that are fields of the command as
/// they stand. Any other key could stand in for a field the command is
/// built from, its pipeline above all, past the check of that pipeline.
const AGGREGATE_OPTIONS: [&str; 9] = [
    "allowDiskUse",
    "bypassDocumentValidation",
    "collation",
    "comment",
    "hint",
    "let",
    "maxTimeMS",
    "readConcern",
    "writeConcern",
];

/// An aggregate. Its columns are the last `$project`'s, where it ends on
/// one, and its `explain()` asks the planner instead.
fn aggregate(target: Bson, pipeline: Vec<Bson>, options: Document, database: String, call: &ShellCall) -> Planned {
    let columns = pipeline
        .last()
        .and_then(Bson::as_document)
        .and_then(|stage| stage.get_document("$project").ok())
        .map_or(Columns::Discovered, crate::shell_find::projected_columns);
    let mut explained = false;
    for modifier in call.modifiers() {
        match modifier.name.as_str() {
            "explain" => explained = true,
            "toArray" | "pretty" => {}
            _ => return Err(unsupported("this aggregate cursor method")),
        }
    }
    let mut command = doc! { "aggregate": target, "pipeline": pipeline, "cursor": {} };
    for (key, value) in options {
        match key.as_str() {
            "batchSize" => {
                command.insert("cursor", doc! { "batchSize": value });
            }
            "explain" => explained |= value.as_bool().unwrap_or(false),
            name if AGGREGATE_OPTIONS.contains(&name) => {
                command.insert(key, value);
            }
            _ => return Err(value_error(ValueError(format!("aggregate() takes no option {key}")))),
        }
    }
    if explained {
        return Ok(Plan::Command {
            database,
            command: doc! { "explain": command },
            reply: Reply::Whole,
        });
    }
    Ok(Plan::Cursor {
        database,
        command,
        columns,
        counted: false,
    })
}

#[cfg(test)]
mod tests {
    use tablepro_core::sql_syntax::mongo::parse_statement;

    use super::*;

    fn planned(text: &str) -> Planned {
        plan(&parse_statement(text).expect("a statement"), "shop", &[])
    }

    #[test]
    fn an_aggregate_option_cannot_stand_in_for_its_pipeline() {
        let Ok(Plan::Cursor { command, .. }) =
            planned("db.a.aggregate([{$match: {}}], {allowDiskUse: true, comment: 'x'})")
        else {
            panic!("not a cursor");
        };
        assert_eq!(command.get_bool("allowDiskUse").ok(), Some(true));

        assert!(planned("db.a.aggregate([], {pipeline: [{$out: 'b'}]})").is_err());
        assert!(planned("db.a.aggregate([], {aggregate: 'other'})").is_err());
        assert!(matches!(
            planned("db.a.aggregate([], {explain: true})"),
            Ok(Plan::Command { .. })
        ));
        assert!(
            planned("db.a.aggregate([]).sort({a: 1})").is_err(),
            "an aggregate takes no sort()"
        );
        assert!(planned("db.a.aggregate([{$out: 'b'}]).itcount()").is_err());
    }

    #[test]
    fn a_page_of_aliased_fields_shows_their_own_names() {
        let Ok(Plan::Cursor { columns, .. }) = planned(
            r#"db.getCollection("users").aggregate([{"$limit": 5}, {"$project": {"_id": 1, "__field_1": {"$getField": {"field": {"$literal": "a.b"}, "input": "$$ROOT"}}}}])"#,
        ) else {
            panic!("not a cursor");
        };
        let Columns::Named(columns) = columns else {
            panic!("no named columns");
        };
        let names: Vec<&str> = columns.iter().map(|column| column.name.as_str()).collect();
        assert_eq!(names, ["_id", "a.b"]);
    }
}
