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

/// Collection methods that drop the collection or its indexes, as SQL's
/// DROP does.
const COLLECTION_DROPS: [&str; 4] = ["drop", "dropIndex", "dropIndexes", "dropSearchIndex"];

/// Database methods that drop the database, a user or a role.
const DATABASE_DROPS: [&str; 5] = ["dropDatabase", "dropUser", "dropRole", "dropAllUsers", "dropAllRoles"];

/// Commands that drop a collection, a database, an index, a user or a
/// role. `deleteIndexes` is the server's old name for `dropIndexes`.
const COMMAND_DROPS: [&str; 9] = [
    "drop",
    "dropdatabase",
    "dropindexes",
    "deleteindexes",
    "dropsearchindex",
    "dropuser",
    "droprole",
    "dropallusersfromdatabase",
    "dropallrolesfromdatabase",
];

/// `validate` options that write when true: `repair` inserts and removes
/// index keys and removes invalid documents, `fixMultikey` rewrites index
/// metadata.
const VALIDATE_WRITES: [&str; 2] = ["repair", "fixMultikey"];

/// The aggregation stage that replaces its target collection with the
/// results, as a DROP and a fill would.
const REPLACING_STAGE: &str = "$out";

/// The aggregation stage that writes the results into a collection,
/// keeping the documents it does not match.
const MERGING_STAGE: &str = "$merge";

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
        (CallRoot::Db, Some(collection)) => collection_access(
            &operation.name,
            &operation.args,
            Source {
                database: call.database.as_deref(),
                collection,
            },
        ),
        (CallRoot::Db, None) => database_access(&operation.name, &operation.args, call.database.as_deref()),
    };
    match shaped {
        true => access,
        false => access.max(StatementAccess::Write),
    }
}

fn collection_access(method: &str, args: &[ShellValue], source: Source<'_>) -> StatementAccess {
    match method {
        "aggregate" => args.first().map_or(StatementAccess::Read, |pipeline| {
            pipeline_access(pipeline, Some(source))
        }),
        _ if COLLECTION_READS.contains(&method) => StatementAccess::Read,
        _ if COLLECTION_DROPS.contains(&method) => StatementAccess::Destructive,
        // `dropTarget` drops the collection the rename replaces.
        "renameCollection" if args.get(1).is_some_and(drops_target) => StatementAccess::Destructive,
        // Every document, as a DELETE or UPDATE with no WHERE.
        "deleteMany" | "remove" | "updateMany" if args.first().is_none_or(matches_every_document) => {
            StatementAccess::Destructive
        }
        "update"
            if args.first().is_none_or(matches_every_document)
                && args
                    .get(2)
                    .and_then(|options| options.field("multi"))
                    .is_some_and(is_true) =>
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

/// `renameCollection`'s second argument, `true` or `{dropTarget: true}`.
fn drops_target(argument: &ShellValue) -> bool {
    match argument.as_object() {
        Some(_) => argument.field("dropTarget").is_some_and(is_true),
        None => is_true(argument),
    }
}

/// Whether the server reads a flag as set, as BSON's `trueValue` does:
/// anything but `false`, zero and `null`. A bound value or a helper such
/// as `NumberInt(0)` counts as set, the stricter reading.
fn is_true(value: &ShellValue) -> bool {
    match value {
        ShellValue::Bool(flag) => *flag,
        ShellValue::Null => false,
        ShellValue::Number(number) => number.as_f64() != Some(0.0),
        _ => true,
    }
}

fn database_access(method: &str, args: &[ShellValue], database: Option<&str>) -> StatementAccess {
    let database = match method {
        "adminCommand" => Some("admin"),
        _ => database,
    };
    match method {
        "runCommand" | "adminCommand" => args
            .first()
            .map_or(StatementAccess::Write, |command| command_access(command, database)),
        "aggregate" => args
            .first()
            .map_or(StatementAccess::Read, |pipeline| pipeline_access(pipeline, None)),
        _ if DATABASE_READS.contains(&method) => StatementAccess::Read,
        _ if DATABASE_DROPS.contains(&method) => StatementAccess::Destructive,
        _ => StatementAccess::Write,
    }
}

/// A command document by its first key, the command's name, which the
/// server matches without regard to case for most commands. `database`
/// is the one it runs in, `None` for the current one.
fn command_access(command: &ShellValue, database: Option<&str>) -> StatementAccess {
    let Some(name) = command
        .as_object()
        .and_then(|fields| fields.first())
        .map(|(name, _)| name)
    else {
        return StatementAccess::Write;
    };
    let name = name.to_ascii_lowercase();
    let set = |option: &str| command.field(option).is_some_and(is_true);
    let source = (name == "aggregate")
        .then(|| command.field("aggregate").and_then(ShellValue::as_str))
        .flatten()
        .map(|collection| Source { database, collection });
    let pipeline = command
        .field("pipeline")
        .map_or(StatementAccess::Read, |pipeline| pipeline_access(pipeline, source));
    let writes = pipeline > StatementAccess::Read
        || command
            .field("explain")
            .is_some_and(|inner| command_access(inner, database) > StatementAccess::Read)
        || (name == "validate" && VALIDATE_WRITES.into_iter().any(set));
    let destructive = pipeline == StatementAccess::Destructive
        || COMMAND_DROPS.contains(&name.as_str())
        || match name.as_str() {
            "renamecollection" => set("dropTarget"),
            "mapreduce" => command.field("out").is_some_and(replaces_output),
            // Oplog entries, applied unchecked: any one can drop, empty or overwrite a collection.
            "applyops" => true,
            // Rebuilds the collection capped, dropping its other indexes and the oldest documents past the size.
            "converttocapped" => true,
            _ => reaches_every_document(&name, command),
        };
    if destructive {
        return StatementAccess::Destructive;
    }
    match COMMAND_READS.contains(&name.as_str()) && !writes {
        true => StatementAccess::Read,
        false => StatementAccess::Write,
    }
}

/// A raw `delete`, `update` or `bulkWrite` command with an entry that
/// reaches every document, as `deleteMany({})` and `updateMany({}, ...)`
/// do: no filter, `null` or `{}`, and no limit of one or a `multi`
/// update. A `bulkWrite` op is a delete or an update by its key, and
/// `multi` takes either past one document.
fn reaches_every_document(name: &str, command: &ShellValue) -> bool {
    let (list, filter, every): (&str, &str, fn(&ShellValue) -> bool) = match name {
        "delete" => ("deletes", "q", |entry| {
            entry
                .field("limit")
                .is_none_or(|limit| !matches!(limit, ShellValue::Number(number) if number.as_f64() == Some(1.0)))
        }),
        "update" => ("updates", "q", |entry| entry.field("multi").is_some_and(is_true)),
        "bulkwrite" => ("ops", "filter", |entry| {
            (entry.field("delete").is_some() || entry.field("update").is_some())
                && entry.field("multi").is_some_and(is_true)
        }),
        _ => return false,
    };
    let Some(ShellValue::Array(entries)) = command.field(list) else {
        return false;
    };
    entries
        .iter()
        .any(|entry| every(entry) && entry.field(filter).is_none_or(matches_every_document))
}

/// The collection an aggregate reads, in `database`, `None` for the
/// current one.
#[derive(Clone, Copy)]
struct Source<'a> {
    database: Option<&'a str>,
    collection: &'a str,
}

/// What a pipeline does, by the stages it holds at any depth: a
/// `$lookup` or `$facet` holds pipelines of its own. A `$merge` into the
/// collection it reads rewrites that collection's documents.
fn pipeline_access(pipeline: &ShellValue, source: Option<Source<'_>>) -> StatementAccess {
    let stages = pipeline.keys();
    if stages.contains(&REPLACING_STAGE) || source.is_some_and(|source| merges_into(pipeline, source)) {
        StatementAccess::Destructive
    } else if stages.contains(&MERGING_STAGE) {
        StatementAccess::Write
    } else {
        StatementAccess::Read
    }
}

/// Whether a `$merge` at any depth may write into `source`. Its `into`
/// names a collection of the current database, or `{db, coll}`. A `db`
/// named where the call names none, which may be the current one, and a
/// target that is not a name count as the source, the stricter reading.
fn merges_into(value: &ShellValue, source: Source<'_>) -> bool {
    match value {
        ShellValue::Object(fields) => fields
            .iter()
            .any(|(key, value)| (key == MERGING_STAGE && merge_names(value, source)) || merges_into(value, source)),
        ShellValue::Array(items) | ShellValue::Constructor { args: items, .. } => {
            items.iter().any(|item| merges_into(item, source))
        }
        _ => false,
    }
}

fn merge_names(stage: &ShellValue, source: Source<'_>) -> bool {
    let into = match stage.as_object() {
        Some(_) => stage.field("into"),
        None => Some(stage),
    };
    let (database, collection) = match into {
        Some(ShellValue::String(collection)) => (None, Some(collection.as_str())),
        Some(target @ ShellValue::Object(_)) => (target.field("db"), target.field("coll").and_then(ShellValue::as_str)),
        _ => (None, None),
    };
    let other_database = matches!(
        (database, source.database),
        (Some(ShellValue::String(named)), Some(read)) if named != read
    );
    !other_database && collection.is_none_or(|collection| collection == source.collection)
}

/// Whether a `mapReduce` output replaces a collection: a collection's
/// name or `{replace: ...}`. `{merge: ...}` and `{reduce: ...}` write into
/// one, and `{inline: 1}` writes nowhere. Anything else but an object
/// counts as a name, the stricter reading.
fn replaces_output(out: &ShellValue) -> bool {
    match out.as_object() {
        Some(_) => out.field("replace").is_some(),
        None => true,
    }
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
                "db.runCommand({aggregate: 'a', pipeline: [], pipeline: [{$merge: 'b'}], cursor: {}})",
                StatementAccess::Write,
            ),
            (
                "db.runCommand({aggregate: 'a', pipeline: [], pipeline: [{$out: 'b'}], cursor: {}})",
                StatementAccess::Destructive,
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
    fn an_aggregate_that_merges_its_results_is_a_write() {
        for text in [
            "db.a.aggregate([{$merge: {into: 'b'}}])",
            "db.a.aggregate([{$match: {}}, {$merge: 'b'}])",
            "db.runCommand({aggregate: 'a', pipeline: [{$merge: 'b'}], cursor: {}})",
            "db.runCommand({explain: {aggregate: 'a', pipeline: [{$merge: 'b'}]}})",
            "db.aggregate([{$documents: [{}]}, {$merge: 'b'}])",
        ] {
            assert_eq!(script_access(text), StatementAccess::Write, "{text}");
        }
    }

    #[test]
    fn a_merge_into_the_collection_it_reads_is_destructive() {
        for text in [
            "db.users.aggregate([{$match: {}}, {$merge: {into: 'users', whenMatched: 'replace'}}])",
            "db.users.aggregate([{$merge: 'users'}])",
            "db.users.aggregate([{$merge: {into: {coll: 'users'}}}])",
            "db.getSiblingDB('shop').users.aggregate([{$merge: {into: {db: 'shop', coll: 'users'}}}])",
            "db.users.aggregate([{$merge: {into: {db: 'shop', coll: 'users'}}}])",
            "db.getCollection('users').aggregate([{$merge: {whenMatched: 'replace'}}])",
            "db.runCommand({aggregate: 'users', pipeline: [{$merge: {into: 'users'}}], cursor: {}})",
        ] {
            assert_eq!(script_access(text), StatementAccess::Destructive, "{text}");
        }
        for text in [
            "db.users.aggregate([{$merge: {into: 'users_copy', whenMatched: 'replace'}}])",
            "db.users.aggregate([{$merge: 'Users'}])",
            "db.getSiblingDB('shop').users.aggregate([{$merge: {into: {db: 'archive', coll: 'users'}}}])",
            "db.runCommand({aggregate: 'users', pipeline: [{$merge: 'totals'}], cursor: {}})",
            "db.adminCommand({aggregate: 'users', pipeline: [{$merge: {into: {db: 'shop', coll: 'users'}}}], cursor: {}})",
            "db.aggregate([{$documents: [{}]}, {$merge: 'users'}])",
            "db.runCommand({explain: {aggregate: 'users', pipeline: [{$merge: 'users'}]}})",
        ] {
            assert_eq!(script_access(text), StatementAccess::Write, "{text}");
        }
    }

    #[test]
    fn an_aggregate_that_replaces_a_collection_is_destructive() {
        for text in [
            "db.a.aggregate([{$match: {}}, {$out: 'b'}])",
            "db.a.aggregate([{$out: {db: 'archive', coll: 'b'}}])",
            "db.a.aggregate([{$facet: {x: [{$out: 'b'}]}}])",
            "db.a.aggregate([{$merge: 'b'}, {$out: 'c'}])",
            "db.getSiblingDB('shop').getCollection('a').aggregate([{$out: 'b'}]).toArray()",
            "db.runCommand({aggregate: 'a', pipeline: [{$out: 'b'}], cursor: {}})",
            "db.adminCommand({aggregate: 1, pipeline: [{$documents: [{}]}, {$out: 'b'}], cursor: {}})",
            "db.aggregate([{$documents: [{}]}, {$out: 'b'}])",
        ] {
            assert_eq!(script_access(text), StatementAccess::Destructive, "{text}");
        }
    }

    #[test]
    fn a_map_reduce_that_replaces_its_output_is_destructive() {
        let map_reduce = |out: &str| {
            format!(
                "db.runCommand({{mapReduce: 'orders', map: 'function() {{}}', reduce: 'function() {{}}', out: {out}}})"
            )
        };
        let cases = [
            (map_reduce("'totals'"), StatementAccess::Destructive),
            (map_reduce("{replace: 'totals'}"), StatementAccess::Destructive),
            (
                map_reduce("{replace: 'totals', db: 'archive'}"),
                StatementAccess::Destructive,
            ),
            (map_reduce("{merge: 'totals'}"), StatementAccess::Write),
            (map_reduce("{reduce: 'totals'}"), StatementAccess::Write),
            (map_reduce("{inline: 1}"), StatementAccess::Write),
            (map_reduce("{inline: 1}, out: 'totals'"), StatementAccess::Destructive),
            (map_reduce("'totals', out: {inline: 1}"), StatementAccess::Write),
            (
                "db.runCommand({mapreduce: 'orders', map: 'm', reduce: 'r', out: 'totals'})".to_owned(),
                StatementAccess::Destructive,
            ),
        ];
        for (text, expected) in cases {
            assert_eq!(script_access(&text), expected, "{text}");
        }
    }

    #[test]
    fn a_bulk_write_that_reaches_every_document_is_destructive() {
        let bulk =
            |ops: &str| format!("db.adminCommand({{bulkWrite: 1, ops: [{ops}], nsInfo: [{{ns: 'shop.users'}}]}})");
        let cases = [
            (
                bulk("{delete: 0, filter: {}, multi: true}"),
                StatementAccess::Destructive,
            ),
            (
                bulk("{delete: 0, filter: null, multi: true}"),
                StatementAccess::Destructive,
            ),
            (bulk("{delete: 0, multi: 1}"), StatementAccess::Destructive),
            (
                bulk("{update: 0, filter: {}, updateMods: {$set: {a: 1}}, multi: true}"),
                StatementAccess::Destructive,
            ),
            (
                bulk("{insert: 0, document: {a: 1}}, {delete: 0, filter: {}, multi: true}"),
                StatementAccess::Destructive,
            ),
            (bulk("{delete: 0, filter: {}}"), StatementAccess::Write),
            (bulk("{delete: 0, filter: {}, multi: false}"), StatementAccess::Write),
            (bulk("{delete: 0, filter: {a: 1}, multi: true}"), StatementAccess::Write),
            (
                bulk("{update: 0, filter: {}, updateMods: {$set: {a: 1}}}"),
                StatementAccess::Write,
            ),
            (
                bulk("{update: 0, filter: {a: 1}, updateMods: {$set: {a: 1}}, multi: true}"),
                StatementAccess::Write,
            ),
            (bulk("{insert: 0, document: {}}"), StatementAccess::Write),
        ];
        for (text, expected) in cases {
            assert_eq!(script_access(&text), expected, "{text}");
        }
    }

    #[test]
    fn apply_ops_is_destructive_and_multi_is_read_as_the_server_reads_a_flag() {
        for text in [
            "db.adminCommand({applyOps: [{op: 'd', ns: 'shop.users', o: {_id: 1}}]})",
            "db.runCommand({applyOps: []})",
            "db.users.update({}, {$set: {a: 1}}, {multi: 1})",
            "db.runCommand({update: 'users', updates: [{q: {}, u: {$set: {a: 1}}, multi: 1}]})",
            "db.runCommand({delete: 'users', deletes: [{q: null, limit: 0}]})",
        ] {
            assert_eq!(script_access(text), StatementAccess::Destructive, "{text}");
        }
        assert_eq!(
            script_access("db.users.update({}, {$set: {a: 1}}, {multi: 0})"),
            StatementAccess::Write
        );
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
    fn every_drop_is_destructive_as_sql_drop_is() {
        for text in [
            "db.users.dropIndex('a_1')",
            "db.users.dropIndex({a: 1})",
            "db.users.dropIndexes()",
            "db.users.dropIndexes(['a_1', 'b_1'])",
            "db.users.dropSearchIndex('s')",
            "db.getSiblingDB('shop').getCollection('users').dropIndexes()",
            "db.dropUser('ann')",
            "db.dropRole('auditor')",
            "db.dropAllUsers()",
            "db.dropAllRoles()",
            "db.runCommand({dropIndexes: 'users', index: '*'})",
            "db.runCommand({deleteIndexes: 'users', index: 'a_1'})",
            "db.runCommand({dropSearchIndex: 'users', name: 's'})",
            "db.runCommand({dropUser: 'ann'})",
            "db.runCommand({dropRole: 'auditor'})",
            "db.runCommand({dropAllUsersFromDatabase: 1})",
            "db.adminCommand({dropAllRolesFromDatabase: 1})",
            "db.runCommand({convertToCapped: 'orders', size: 4096})",
        ] {
            assert_eq!(script_access(text), StatementAccess::Destructive, "{text}");
        }
    }

    #[test]
    fn a_rename_that_drops_its_target_is_destructive() {
        let cases = [
            (
                "db.orders_new.renameCollection('orders', true)",
                StatementAccess::Destructive,
            ),
            (
                "db.orders_new.renameCollection('orders', {dropTarget: true})",
                StatementAccess::Destructive,
            ),
            (
                "db.orders_new.renameCollection('orders', 1)",
                StatementAccess::Destructive,
            ),
            ("db.orders_new.renameCollection('orders')", StatementAccess::Write),
            (
                "db.orders_new.renameCollection('orders', false)",
                StatementAccess::Write,
            ),
            (
                "db.orders_new.renameCollection('orders', {dropTarget: false})",
                StatementAccess::Write,
            ),
            (
                "db.adminCommand({renameCollection: 'shop.a', to: 'shop.b', dropTarget: true})",
                StatementAccess::Destructive,
            ),
            (
                "db.adminCommand({renameCollection: 'shop.a', to: 'shop.b', dropTarget: 1})",
                StatementAccess::Destructive,
            ),
            (
                "db.adminCommand({renameCollection: 'shop.a', to: 'shop.b'})",
                StatementAccess::Write,
            ),
            (
                "db.adminCommand({renameCollection: 'shop.a', to: 'shop.b', dropTarget: 0})",
                StatementAccess::Write,
            ),
            // A key written twice is sent with its last value.
            (
                "db.adminCommand({renameCollection: 'shop.a', to: 'shop.b', dropTarget: false, dropTarget: true})",
                StatementAccess::Destructive,
            ),
            (
                "db.adminCommand({renameCollection: 'shop.a', to: 'shop.b', dropTarget: true, dropTarget: false})",
                StatementAccess::Write,
            ),
        ];
        for (text, expected) in cases {
            assert_eq!(script_access(text), expected, "{text}");
        }
    }

    #[test]
    fn a_validate_that_repairs_is_a_write() {
        let cases = [
            ("db.runCommand({validate: 'orders'})", StatementAccess::Read),
            ("db.runCommand({validate: 'orders', full: true})", StatementAccess::Read),
            (
                "db.runCommand({validate: 'orders', repair: false})",
                StatementAccess::Read,
            ),
            (
                "db.runCommand({validate: 'orders', repair: true})",
                StatementAccess::Write,
            ),
            (
                "db.runCommand({validate: 'orders', repair: true, fixMultikey: true})",
                StatementAccess::Write,
            ),
            (
                "db.runCommand({validate: 'orders', fixMultikey: true})",
                StatementAccess::Write,
            ),
            ("db.runCommand({validate: 'orders', repair: 1})", StatementAccess::Write),
            (
                "db.runCommand({validate: 'orders', repair: false, repair: true})",
                StatementAccess::Write,
            ),
            (
                "db.runCommand({validate: 'orders', repair: true, repair: false})",
                StatementAccess::Read,
            ),
        ];
        for (text, expected) in cases {
            assert_eq!(script_access(text), expected, "{text}");
        }
    }

    #[test]
    fn a_write_may_change_the_catalog() {
        assert!(may_change_catalog("db.newcoll.insertOne({})"));
        assert!(may_change_catalog("db.a.drop()"));
        assert!(!may_change_catalog("db.a.find()"));
    }
}
