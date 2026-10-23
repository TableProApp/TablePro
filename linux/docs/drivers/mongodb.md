# MongoDB

Driver id `mongodb`, crate `crates/drivers/mongodb`. It speaks the wire protocol through the mongodb crate 3.9 with its default features off, `compat-3-3-0`, `bson-3`, `rustls-tls-aws-lc` and `dns-resolver`. The integration suite runs against MongoDB 8.0, and CI runs it again on 7.0 ([supported servers](../../README.md#supported-servers)). MongoDB has no SQL: how a document engine meets the contract is in [adding-drivers.md, Engines without SQL](../adding-drivers.md#engines-without-sql), and why collections open in the table tab is [ADR 0023](../decisions/0023-documents-in-the-table-tab.md).

The default port is 27017.

## Reaching the server

What the connection names decides how the crate reaches it:

| Route | What the crate dials | TLS |
|---|---|---|
| A host, directly | That one host, with `directConnection`, as mongosh does with one host: a replica set member is used as named, never swapped for the names the set gives its members, which the app may not be able to reach | The crate's, from files the driver writes (below) |
| DNS Seed List on | The servers the host's SRV records name, with the options its TXT record sets (`replicaSet`, `authSource`, `loadBalanced`), and the set's discovery | The crate's |
| SSH | A private Unix socket the driver listens on; each connection the crate opens there is a new `Transport::open()` stream through the forward, one host, `directConnection` | The driver's, around each stream |

A seed list is a DNS lookup the forward cannot carry, so DNS Seed List over SSH is refused before anything is opened (`ConfigError::SeedListOverSsh`). The seed list's port is the records' to give, so the connect dialog hides the Port row while DNS Seed List is on.

The relay socket sits in a private directory under `$XDG_RUNTIME_DIR` (the system temporary directory without one), mode 0700, and is removed with the connection. A stream the forward fails to open closes the crate's connection, and the transport's own error (the SSH master exited, the destination refused) is what the call reports.

## Clients

The crate keeps a pool per client. Each client opens with a `ping` under the login timeout, so a refused password or a failed handshake is the connect's error:

| Client | Pool | Used for | Opened |
|---|---|---|---|
| Workspace | 8 | The sidebar, the grid's pages and counts, saves | At connect |
| Probe | 1 | `probe` and the check after a failed call | At connect |
| Editor | 2 | One editor tab's statements, and its stop | When the tab first runs |
| Export | 2 | An export's reads | For the export, closed with it |

Every call runs in a logical session of its own. Retryable reads and writes are off: one operation is one send, which the stop and the write ledger account for.

The crate selects a server under the login timeout. A heartbeat that fails, such as a refused TLS handshake, fails the connect at once with that failure instead of waiting out server selection.

### The login

A username logs in with SCRAM, checked in the database the user is defined in: the Authentication Database when one is given, else for a seed list the one its TXT record names or `admin`, else the connection's database, else `admin`, as mongosh and the macOS app choose. No username connects without a login, to a server without access control.

The connection's database is the one named, else the first the login may see that is not `admin`, `config` or `local`, else `test`, as mongosh opens.

## Catalogue

Databases are the sidebar's schemas, collections its tables and views its views. `listDatabases` runs with `nameOnly` and `authorizedDatabases`, and `listCollections` with `authorizedCollections`, so a login sees what it may read.

A collection's columns are its top-level fields, found by the server from the first 1,000 documents in their natural order: the fields, the BSON types each holds, and where each first appears. No document crosses the wire for it. `_id` comes first, then the fields in the order the documents place them.

A field's column type is its values' type: a number widens across `int`, `long`, `double` and `decimal`, a string is text, a date a timestamp with a zone, an `objectId` its own type. A field that holds documents, arrays, binary data or more than one kind of value is a JSON column, written as relaxed Extended JSON from the BSON itself, with each `long` in its canonical `{"$numberLong": "..."}` form, so the type survives an edit. A UUID (binary subtype 4) is a UUID, other binary data bytes. A field missing from a document reads as NULL.

`_id` is the primary key and names a document for every save. A new row leaves `_id` out unless one is typed, and the document gets an ObjectId, as every driver gives it. A view has no key: its pages are counted off in the order the view gives, and its rows read and never write. Indexes come from `listIndexes`, `_id`'s first. The row count is the collection's metadata count, shown as an estimate.

## Pages, filters and saves

A collection opens in the table tab, and every statement the tab builds is a mongosh call ([ADR 0023](../decisions/0023-documents-in-the-table-tab.md)), so the history and the Safe Mode dialog show text the editor can run:

| What | Statement |
|---|---|
| A page | `db.getSiblingDB("shop").getCollection("users").aggregate([{$match: ...}, {$sort: ...}, {$skip: ...}, {$limit: ...}, {$project: ...}], {allowDiskUse: true})` |
| The count | `countDocuments` with the filter |
| An edit | `updateOne({_id: $1}, {$set: {...}})` |
| A new row | `insertOne({...})`, or `insertMany([...])` for several |
| A delete | `deleteOne({_id: $1})` |

Every value is a bound parameter, never spliced into the text. A sort always ends with `_id`, so a page is stable, and paging past the first pages walks `_id` by key: across `_id`s of more than one type, in the order MongoDB compares types.

A filter rule becomes a `$match` condition: equality, comparisons, `$in`, a pattern as an anchored `$regex`, NULL as missing or null. The raw filter takes a query document, `{ qty: { $gt: 1 }, status: 'A' }`, checked before it is sent. A field whose name holds a `.` or starts with `$` is read through `$getField` and shown, but cannot be filtered, sorted or edited, since a query cannot name it.

A JSON cell is edited as JSON text, refused when it does not parse, and saved as the BSON its Extended JSON names.

Each save step is one single-document write, which MongoDB applies whole or not at all (`WriteAtomicity::StatementByStatement`). A CSV import inserts a document a step too, since an `insertMany` that fails partway keeps the documents before the failure, so a failed import names exactly the rows that did not land. An edit or a delete must match exactly one document; one that matches none, because another client deleted it, stops the save there with what the steps before it applied. A write error such as a duplicate key fails the step with the server's code. A write concern the server could not meet, such as a majority that did not answer in time, leaves the write applied where it ran with its fate open, so the save reports it as unknown rather than as not applied.

## The editor

The editor runs mongosh statements. A statement ends at `;` or at the end of a line outside brackets, unless the next line starts with `.` or the line ends inside a call. It reads them with its own parser, never by running JavaScript:

- `use <db>`, `show dbs`, `show collections`, `show users`, `show roles`.
- `db.<collection>` or `db.getCollection("<name>")`, with `db.getSiblingDB("<db>")` in front, and the collection methods: `find`, `findOne`, `aggregate`, `countDocuments`, `estimatedDocumentCount`, `count`, `distinct`, `getIndexes`, `stats` and its sizes, the `insert`, `update`, `replace`, `delete` and `findOneAnd...` families, `findAndModify`, `remove`, `createIndex(es)`, `dropIndex(es)`, `hideIndex`, `unhideIndex`, `renameCollection` and `drop`.
- A cursor's `sort`, `limit`, `skip`, `projection`, `hint`, `maxTimeMS`, `batchSize`, `comment`, `collation`, `allowDiskUse`, `toArray`, `pretty`, `count`, `explain` and the like.
- The database methods: `runCommand`, `adminCommand`, `aggregate`, `getCollectionNames`, `getCollectionInfos`, `createCollection`, `createView`, `dropDatabase`, `stats`, `serverStatus`, `version`, `currentOp`, `killOp`, the user and role helpers, and `rs.status()`, `rs.conf()`.
- Values as mongosh writes them: unquoted keys, single quotes, regular expressions, `ObjectId`, `ISODate`, `Date`, `NumberInt`, `NumberLong`, `NumberDecimal`, `Timestamp`, `UUID`, `BinData`, `MinKey`, `MaxKey`. A whole number in the int32 range is an `int`, any other number a `double`, as mongosh stores them.

Anything else, a JavaScript function, a variable, `forEach`, `bulkWrite`, is refused before it is sent with a `SyntaxError` at its place, or `Unsupported`. As mongosh checks, `updateOne` and `updateMany` take update operators or a pipeline and `replaceOne` a document with none, so a forgotten `$set` never replaces a document, and `dropIndex()` has to name its index. A write's `writeConcern`, `ordered`, `comment` and `let` options go with its command. A statement's documents show one per row, a column per field: the fields a projection names, in its order, or every field the documents hold, in the order they first show it. A write shows what mongosh prints for it (`insertedId`, `matchedCount`, `modifiedCount`).

The run's row limit keeps 10,000 documents, all read before the first row is shown, so the columns hold every field they have: the cursor reads one more to say the result was cut, and closing it frees the rest on the server. A tab's `use` changes only its own database.

An export of an editor result whose columns are not named by a projection reads the documents twice: once for the fields they hold, then to write them under those columns. A document that gains a field between the two reads fails the export rather than losing the field.

A history entry is withheld when a statement carries a password: `createUser`, `updateUser`, `changeUserPassword`, `auth`, `connect` and `Mongo`, by name or in brackets (`db['changeUserPassword'](...)`), a `pwd`, `password` or `passwordDigestor` key, and a connection string with a password. Text that does not close is withheld too. The editor highlights JavaScript and has no SQL completion, formatter or comment toggle.

## Stops and timeouts

A stop is `killSessions` for the call's logical session, sent from the same client on a connection of its own (`OutOfBand(Statement)`): the server ends the operation that session runs and closes its cursors, and the call ends with `Interrupted` (11601) or `CursorKilled` (237), which reads as the stop it is. A session names one call, so a late stop cannot land on anything else: a session whose `killSessions` has not been answered stays out of the client's pool for a minute, so no later call takes its id while the stop could still arrive.

A statement also carries `maxTimeMS` for what is left of its deadline, so the server stops it on its own; `MaxTimeMSExpired` (50) is a timeout the server stopped. `EditorSessionOptions::statement_timeout` bounds each editor statement the same way.

A call that times out or loses its connection checks the server with the probe client within the cancel grace. Only a server that fails it marks the link lost.

## Read-only

MongoDB has no read-only session, so a read-only connection rests on the app's own check (`ReadOnlyEnforcement::ClientGuard`): each statement is read before it is sent, and one that is not a read is refused with `ReadOnlyRefusal::ClientGuard`, in the editor, in a save and in an export. A statement reads only when `sql_syntax::mongo` lists its method, or its command's name, as a read, with every cursor method after it a read too; an `aggregate` with `$out` or `$merge` at any depth writes, and so does an `explain` of a write. A method it does not know counts as a write. For a guarantee, log in as a user with only the `read` role.

Safe Mode reads statements the same way: Confirm Writes asks before every statement that is not a read, and Off asks before `drop`, `dropDatabase`, a `deleteMany`, `remove` or `updateMany` with no filter, `null` or `{}`, an `update` with `multi` and such a filter, and a `delete` or `update` command through `runCommand` that reaches every document the same way. `aggregate()` takes only its own options, so none can stand in for the pipeline that was checked, and a key written twice is read as its last value, as the shell sends it.

## Trust

The crate has no system store of its own: given no CA file it trusts only the Mozilla roots compiled into it. So where the crate does TLS, the driver hands it a bundle: the system store and the connection's CA file as one PEM (`tablepro_net::tls::ca_bundle_pem`), and the client certificate and key as one more, written mode 0600 into a private directory and removed once the client is built, which is when the crate reads them. The crate checks each server's certificate under that server's own name, so the server name override applies only through SSH (`ServerNameOverride::SshForwardOnly`). Require mode skips the check of the certificate and its name.

Through SSH the driver does TLS around each stream with `tablepro_net::tls::build_client_config`, the platform verifier and the CA file, checked against `tls_server_name()`. `tests/system_trust.rs` measures both paths against a CA only the system store holds.

## Server codes

A server error keeps its code and name as `ServerCode::Mongo { code, name }`, such as `11000 DuplicateKey`. `AuthenticationFailed` (18) is an authentication failure, `MaxTimeMSExpired` (50) a timeout the server stopped, and `Interrupted` (11601), `InterruptedAtShutdown` (11600), `CursorKilled` (237), `QueryPlanKilled` (175) and `CursorNotFound` (43) the server acknowledging a stop. A value the text names that BSON cannot hold is `BadValue` (2), refused before it is sent.

## Limits

- Sharded clusters are reached through `mongos` like any server; nothing shard-aware is shown.
- A DNS seed list resolves through the system resolver configuration; it is not tested end to end, since a test SRV record needs a DNS server the crate would ask.
- `bulkWrite`, transactions in the editor, change streams and GridFS are not offered.
- The structure of a collection is not edited: there is no schema to change. Indexes are listed and created or dropped in the editor.
