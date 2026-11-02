use super::{CallRoot, ShellCall, ShellStatement, ShellValue, parse_statement, statement_ranges};
use crate::sql_syntax::StatementAccess;

/// Collection methods that only read. `aggregate` is here too, and reads
/// unless a stage writes.
const COLLECTION_READS: [&str; 22] = [
    "find",
    "findOne",
    "aggregate",
    "count",
    "countDocuments",
    "estimatedDocumentCount",
    "distinct",
    "getIndexes",
    "getIndexKeys",
    "getIndexSpecs",
    "indexes",
    "stats",
    "dataSize",
    "storageSize",
    "totalIndexSize",
    "totalSize",
    "isCapped",
    "latencyStats",
    "explain",
    "getName",
    "getFullName",
    "exists",
];

/// What may follow an operation to shape its cursor, all reads.
const CURSOR_METHODS: [&str; 22] = [
    "sort",
    "limit",
    "skip",
    "projection",
    "hint",
    "maxTimeMS",
    "batchSize",
    "comment",
    "collation",
    "allowDiskUse",
    "toArray",
    "pretty",
    "count",
    "itcount",
    "size",
    "explain",
    "min",
    "max",
    "returnKey",
    "showRecordId",
    "noCursorTimeout",
    "readConcern",
];

/// Database methods that only read.
const DATABASE_READS: [&str; 21] = [
    "getCollectionNames",
    "getCollectionInfos",
    "getName",
    "stats",
    "serverStatus",
    "hostInfo",
    "version",
    "serverBuildInfo",
    "hello",
    "isMaster",
    "currentOp",
    "getProfilingStatus",
    "getUsers",
    "getUser",
    "getRoles",
    "getRole",
    "listCommands",
    "getLogComponents",
    "serverCmdLineOpts",
    "getReplicationInfo",
    "aggregate",
];

/// Server commands, by the name a `runCommand` document opens with, that
/// only read.
const COMMAND_READS: [&str; 34] = [
    "find",
    "aggregate",
    "count",
    "distinct",
    "listcollections",
    "listdatabases",
    "listindexes",
    "dbstats",
    "collstats",
    "datasize",
    "serverstatus",
    "buildinfo",
    "hello",
    "ismaster",
    "ping",
    "connectionstatus",
    "hostinfo",
    "getcmdlineopts",
    "getparameter",
    "getlog",
    "replsetgetstatus",
    "replsetgetconfig",
    "currentop",
    "explain",
    "usersinfo",
    "rolesinfo",
    "top",
    "listcommands",
    "whatsmyuri",
    "features",
    "lockinfo",
    "validate",
    "dbhash",
    "getdefaultrwconcern",
];

/// Commands that drop a collection or a database.
const COMMAND_DROPS: [&str; 2] = ["drop", "dropdatabase"];

/// Aggregation stages that write the results to a collection.
const WRITING_STAGES: [&str; 2] = ["$out", "$merge"];

/// The strictest access of the statements in `text`. A statement that
/// does not parse is a write, since what it would do is a guess.
pub fn script_access(text: &str) -> StatementAccess {
    statement_ranges(text)
        .into_iter()
        .map(|range| match parse_statement(&text[range]) {
            Ok(statement) => access_of(&statement),
            Err(_) => StatementAccess::Write,
        })
        .max()
        .unwrap_or(StatementAccess::Read)
}

/// What one statement can do. A method the tables do not list is a
/// write.
pub fn access_of(statement: &ShellStatement) -> StatementAccess {
    match statement {
        ShellStatement::Show(_) | ShellStatement::Use(_) => StatementAccess::Read,
        ShellStatement::Call(call) => call_access(call),
    }
}

fn call_access(call: &ShellCall) -> StatementAccess {
    let Some(operation) = call.operation() else {
        return StatementAccess::Write;
    };
    let shaped = call
        .modifiers()
        .iter()
        .all(|method| CURSOR_METHODS.contains(&method.name.as_str()));
    let access = match (call.root, &call.collection) {
        (CallRoot::Rs, _) => match operation.name.as_str() {
            "status" | "conf" | "config" | "hello" | "isMaster" | "printReplicationInfo" => StatementAccess::Read,
            _ => StatementAccess::Write,
        },
        (CallRoot::Db, Some(_)) => collection_access(&operation.name, &operation.args),
        (CallRoot::Db, None) => database_access(&operation.name, &operation.args),
    };
    match shaped {
        true => access,
        false => access.max(StatementAccess::Write),
    }
}

fn collection_access(method: &str, args: &[ShellValue]) -> StatementAccess {
    match method {
        "aggregate" if args.first().is_some_and(pipeline_writes) => StatementAccess::Write,
        _ if COLLECTION_READS.contains(&method) => StatementAccess::Read,
        "drop" => StatementAccess::Destructive,
        // Every document, as a DELETE or UPDATE with no WHERE.
        "deleteMany" | "remove" | "updateMany" if args.first().is_none_or(matches_every_document) => {
            StatementAccess::Destructive
        }
        "update"
            if args.first().is_none_or(matches_every_document)
                && matches!(
                    args.get(2).and_then(|options| options.field("multi")),
                    Some(ShellValue::Bool(true))
                ) =>
        {
            StatementAccess::Destructive
        }
        _ => StatementAccess::Write,
    }
}

/// A filter the methods read as every document: none, `null` or `{}`.
fn matches_every_document(filter: &ShellValue) -> bool {
    filter.is_empty_object() || matches!(filter, ShellValue::Null)
}

fn database_access(method: &str, args: &[ShellValue]) -> StatementAccess {
    match method {
        "runCommand" | "adminCommand" => args.first().map_or(StatementAccess::Write, command_access),
        "aggregate" if args.first().is_some_and(pipeline_writes) => StatementAccess::Write,
        _ if DATABASE_READS.contains(&method) => StatementAccess::Read,
        "dropDatabase" => StatementAccess::Destructive,
        _ => StatementAccess::Write,
    }
}

/// A command document by its first key, the command's name, which the
/// server matches without regard to case for most commands.
fn command_access(command: &ShellValue) -> StatementAccess {
    let Some(name) = command
        .as_object()
        .and_then(|fields| fields.first())
        .map(|(name, _)| name)
    else {
        return StatementAccess::Write;
    };
    let name = name.to_ascii_lowercase();
    let writes = command.field("pipeline").is_some_and(pipeline_writes)
        || command
            .field("explain")
            .is_some_and(|inner| command_access(inner) > StatementAccess::Read);
    if COMMAND_DROPS.contains(&name.as_str()) || reaches_every_document(&name, command) {
        return StatementAccess::Destructive;
    }
    match COMMAND_READS.contains(&name.as_str()) && !writes {
        true => StatementAccess::Read,
        false => StatementAccess::Write,
    }
}

/// A raw `delete` or `update` command with an entry that reaches every
/// document, as `deleteMany({})` and `updateMany({}, ...)` do: an empty
/// filter, and no limit of one or a `multi` update.
fn reaches_every_document(name: &str, command: &ShellValue) -> bool {
    let (list, every): (&str, fn(&ShellValue) -> bool) = match name {
        "delete" => ("deletes", |entry| {
            entry
                .field("limit")
                .is_none_or(|limit| !matches!(limit, ShellValue::Number(number) if number.as_f64() == Some(1.0)))
        }),
        "update" => ("updates", |entry| {
            matches!(entry.field("multi"), Some(ShellValue::Bool(true)))
        }),
        _ => return false,
    };
    let Some(ShellValue::Array(entries)) = command.field(list) else {
        return false;
    };
    entries
        .iter()
        .any(|entry| every(entry) && entry.field("q").is_none_or(ShellValue::is_empty_object))
}

/// Whether a pipeline holds a stage that writes, at any depth: a
/// `$lookup` or `$facet` holds pipelines of its own.
fn pipeline_writes(pipeline: &ShellValue) -> bool {
    pipeline.keys().iter().any(|key| WRITING_STAGES.contains(key))
}

/// Whether running `text` can add, rename or remove a collection or a
/// database: any statement that writes, since an insert creates the
/// collection it names.
pub fn may_change_catalog(text: &str) -> bool {
    script_access(text) >= StatementAccess::Write
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_read_and_writes_write() {
        let cases = [
            ("db.users.find({a: 1}).sort({b: 1}).limit(3)", StatementAccess::Read),
            (
                "db.users.aggregate([{$match: {}}, {$group: {_id: '$a'}}])",
                StatementAccess::Read,
            ),
            ("db.users.countDocuments({})", StatementAccess::Read),
            ("show dbs", StatementAccess::Read),
            ("use admin", StatementAccess::Read),
            ("db.runCommand({listCollections: 1})", StatementAccess::Read),
            ("db.adminCommand({ ping: 1 })", StatementAccess::Read),
            ("rs.status()", StatementAccess::Read),
            ("db.getCollectionNames()", StatementAccess::Read),
            ("db.users.insertOne({a: 1})", StatementAccess::Write),
            ("db.users.updateOne({_id: 1}, {$set: {a: 2}})", StatementAccess::Write),
            ("db.users.createIndex({a: 1})", StatementAccess::Write),
            ("db.createCollection('x')", StatementAccess::Write),
            ("db.users.find().forEach(printjson)", StatementAccess::Write),
            ("db.users.find().map(x)", StatementAccess::Write),
            ("db.runCommand({insert: 'x', documents: []})", StatementAccess::Write),
            ("db.killOp(1)", StatementAccess::Write),
            ("db.users.find(", StatementAccess::Write),
            (
                "db.runCommand({aggregate: 'a', pipeline: [], pipeline: [{$out: 'b'}], cursor: {}})",
                StatementAccess::Write,
            ),
            (
                "db.runCommand({delete: 'users', deletes: [{q: {}, limit: 0}]})",
                StatementAccess::Destructive,
            ),
            ("db.users.deleteMany(null)", StatementAccess::Destructive),
            (
                "db.users.updateMany(null, {$set: {a: 1}})",
                StatementAccess::Destructive,
            ),
            (
                "db.users.update({}, {$set: {a: 1}}, {multi: true})",
                StatementAccess::Destructive,
            ),
            ("db.users.update({}, {$set: {a: 1}})", StatementAccess::Write),
            (
                "db.runCommand({delete: 'users', deletes: [{q: {}, limit: 1}]})",
                StatementAccess::Write,
            ),
            (
                "db.runCommand({update: 'users', updates: [{q: {}, u: {$set: {a: 1}}, multi: true}]})",
                StatementAccess::Destructive,
            ),
            (
                "db.runCommand({update: 'users', updates: [{q: {a: 1}, u: {$set: {a: 2}}, multi: true}]})",
                StatementAccess::Write,
            ),
        ];
        for (text, expected) in cases {
            assert_eq!(script_access(text), expected, "{text}");
        }
    }

    #[test]
    fn an_aggregate_that_writes_its_results_is_a_write() {
        for text in [
            "db.a.aggregate([{$match: {}}, {$out: 'b'}])",
            "db.a.aggregate([{$merge: {into: 'b'}}])",
            "db.a.aggregate([{$facet: {x: [{$out: 'b'}]}}])",
            "db.runCommand({aggregate: 'a', pipeline: [{$out: 'b'}], cursor: {}})",
            "db.runCommand({explain: {aggregate: 'a', pipeline: [{$merge: 'b'}]}})",
            "db.aggregate([{$documents: [{}]}, {$out: 'b'}])",
        ] {
            assert_eq!(script_access(text), StatementAccess::Write, "{text}");
        }
    }

    #[test]
    fn dropping_or_emptying_is_destructive() {
        for text in [
            "db.users.drop()",
            "db.dropDatabase()",
            "db.users.deleteMany({})",
            "db.users.deleteMany()",
            "db.users.updateMany({}, {$set: {a: 1}})",
            "db.runCommand({drop: 'users'})",
            "db.runCommand({dropDatabase: 1})",
            "db.a.find()\ndb.users.drop()",
        ] {
            assert_eq!(script_access(text), StatementAccess::Destructive, "{text}");
        }
        assert_eq!(script_access("db.users.deleteMany({a: 1})"), StatementAccess::Write);
        assert_eq!(script_access(""), StatementAccess::Read);
    }

    #[test]
    fn a_write_may_change_the_catalog() {
        assert!(may_change_catalog("db.newcoll.insertOne({})"));
        assert!(may_change_catalog("db.a.drop()"));
        assert!(!may_change_catalog("db.a.find()"));
    }
}
