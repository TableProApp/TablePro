# Cassandra and ScyllaDB

Driver id `cassandra`, crate `crates/drivers/cassandra`, shown as "Cassandra / ScyllaDB". It speaks the CQL native protocol through the `scylla` crate 1.9 with its default features off and `rustls-023` on, with the driver's own rustls config. The integration suite runs against Apache Cassandra 5.0 and ScyllaDB 2026.1, and CI runs it again on Cassandra 4.0 and ScyllaDB 2025.1 ([supported servers](../../README.md#supported-servers)). The contract it implements is in [adding-drivers.md](../adding-drivers.md).

The default port is 9042. With TLS on, use the port the server encrypts: 9042 when it takes TLS only, 9142 when it keeps a separate TLS port.

## Reaching the node

scylla dials a TCP address itself and takes no stream, while an SSH forward is a Unix socket. So each scylla session dials a loopback relay of its own ([ADR 0023](../decisions/0023-loopback-relay-for-cql.md)):

- The relay listens on `127.0.0.1` on a port the kernel picks, for as long as the session lives.
- It serves a connection only after `/proc/net/tcp` shows the connecting socket belongs to this user, and carries it over a stream from `Transport::open`. Every byte to the server goes through the transport, direct, SSH or the tests' `FaultTransport`.
- A stream the transport fails to open closes the connection, and the connect reports the transport's own error.

The session stays on the node behind the transport, as cqlsh does with its host:

- A host filter takes the first node the session learns of, and an address translator sends every node to the relay, so the session never dials an address a node advertises. Through an SSH tunnel the other nodes' addresses would not be reachable anyway.
- After the login the session asks `SELECT host_id FROM system.local`. Where the node that answers is not the one the filter took, that node is pinned and the topology read again, until the two agree.
- The shard-aware port is the node's own, which no transport carries, so it is never used.

A session holds one connection to its node. CQL runs many requests at once on one connection, each under a stream id, so there is no pool to wait for and `probe` is one more request. The client sends no request timeout and retries nothing: every call is bounded by `OwnedCalls`, and a write is never sent twice behind the user's back. It reads no schema metadata at connect; the catalogue reads go to `system_schema` when the app asks.

The session names itself to the server as TablePro with the app's version. The username is optional: with none, the session sends no credentials, as a server on `AllowAllAuthenticator` expects. ScyllaDB's own version comes from `system.versions`; ScyllaDB 2026.1 lets only a role granted SELECT on it read it, and for another role the driver takes the Cassandra release ScyllaDB reports and writes as it does before 2026.1, with a probe before each write ([Writes](#writes)). Values travel as markers of a prepared statement, typed by what the server says each marker takes, and are never spliced into the SQL. A statement with no values goes as it is, so a schema change does not fill the prepared statement cache.

## TLS

- `VerifyFull` trusts the system store plus the connection's CA file ([Trust](../../ARCHITECTURE.md#trust)) and checks the certificate against `NetworkTarget::tls_server_name()`. scylla hands rustls the relay's address, so the driver's verifier checks the configured name instead (`tablepro_net::tls::FixedNameVerifier`). `Require` encrypts without checking the certificate.
- A client certificate is sent when one is set. Both servers ask every client for one or none (`require_client_auth`), and still log the role in by its password.

## Read-only

`ReadOnlyEnforcement::LoginPrivileges`. CQL has no read-only session, so only the role's grants hold on the server. The driver refuses before sending: a save on a read-only connection, and an editor statement the CQL grammar does not read as a read (`ReadOnlyRefusal::ClientGuard`).

## Stops and timeouts

The native protocol has no message that stops a request the server is running. A stopped call drops its request and returns at once: the stream id stays set aside until the late answer arrives, and the connection keeps serving every other call. `StopDelivery::InBand`, and nothing reaches the server. The server runs the statement to its end or to its own timeout: `read_request_timeout` (5 s by default), `range_request_timeout` (10 s), `write_request_timeout` (2 s), or the time limit of a user-defined function.

A workspace call is bounded by the nearer of its deadline and the workspace statement timeout, and reports `Timeout { phase: Statement, server_cancelled: false }` when it runs out. A call that times out or loses its connection is checked with `SELECT now() FROM system.local` within the cancel grace; only a check that fails marks the link lost.

| Server answer | Reported as |
|---|---|
| Authentication error (0x0100), or no authenticator answer at login | `Auth` |
| Any other error frame | `Server`, with `ServerCode::Cql` and the server's message |
| A stream that closed, a broken connection | `ConnectionLost`, or `Tls` where the TLS handshake failed |

The codes are the protocol's own (`native_protocol_v4.spec`, section 9): 0x1000 unavailable, 0x1001 overloaded (and ScyllaDB's rate limit), 0x1100 write timeout, 0x1200 read timeout, 0x1300 read failure, 0x1400 function failure, 0x1500 write failure, 0x2000 syntax error, 0x2100 unauthorized, 0x2200 invalid, 0x2400 already exists.

## Writes

CQL has no transactions: `WriteAtomicity::StatementByStatement` for row and schema changes, and `CommitResolutionSupport::Unavailable`. A row is named by its whole primary key, partition key then clustering columns (`RowIdentity::UniqueKey`).

A plain CQL `UPDATE` of a missing row creates it, and a plain `INSERT` of a taken key replaces the row. So a save says whether its row was there:

- On Cassandra and on ScyllaDB 2026.1 and later, each write is a lightweight transaction: `UPDATE ... IF EXISTS`, `DELETE ... IF EXISTS`, `INSERT ... IF NOT EXISTS`. Its `[applied]` column is an exact count of 0 or 1, so the guard is `AffectedExactly(1)`, and a refused write changes nothing.
- ScyllaDB before 2026.1 refuses a lightweight transaction on a table in a keyspace with tablets, its default for new keyspaces. There the writes are plain, and each runs after a probe, `SELECT COUNT(*) ... WHERE <key>`, that finds one row for an update or a delete and none for an insert. A write by someone else between the probe and the statement is not seen.

A static column holds one value for its partition, so an edit of it reaches every row of the partition. An update that sets static columns alone names only the partition key, as CQL requires, and goes plain after a probe for the edited row: its `IF EXISTS` would ask about the partition's static row instead. A partition that holds only static values reads as a row whose clustering columns are NULL, which names no row, so the grid keeps it read-only.

A statement on the wire is never dropped: the server applies it whatever the client does, so a stop waits for its answer within the cancel grace and is honoured between statements. A write timeout (0x1100), a write failure (0x1500), a lost connection or a timeout may have applied, and the outcome comes from the `WriteLedger`. A refusal applied nothing.

Some rows have no value a grid edit could set, and read as `RowIdentity::Unordered`: a materialized view, a counter table, and a table keyed by a map or a user-defined type. A CSV import writes one row per statement, each proved as a grid insert is, so a large file takes one round trip per row.

## Paging, filters and sorting

`TablePaging::ServerState`. A scan comes back in token order and CQL has no `OFFSET`, so a table pages by the paging state the server hands back with each page:

- The next page resumes from that state. The grid keeps the state of each page it has read, so going back is a resume from a kept state.
- A page reached by its number skips the rows before it on the server's paging, reading them without decoding them.
- The rows keep the server's order. A table cannot be sorted in the grid, since `ORDER BY` only orders within one partition.

A filter joins its rules with AND, the only join CQL has, and the driver offers only the comparisons the server evaluates for a column's type: equal and the ordered comparisons, `IN` (on Cassandra before 5.0 only on a key column), and on ScyllaDB `LIKE` for text. A filtered read ends with `ALLOW FILTERING`, so the server scans the table to filter it. A count is `SELECT COUNT(*)`, which reads every row, and there is no row estimate.

## Editor sessions

- An editor tab holds a scylla session of its own, so a `USE` moves only that tab.
- One statement per run (`ScriptExecution::SingleStatement`). The script planner splits on `;` and keeps a `BEGIN BATCH ... APPLY BATCH` whole, as cqlsh does.
- A result is read page by page, each page handed on before the next is asked for. Past the row limit the driver asks for no more pages: `Truncation::ServerStopped`.
- A stop drops the request, as a workspace call does. There is no transaction an editor statement can leave open, so the transaction state is always `Idle`.

## Structure

`DdlDialect` creates a table with its primary key, adds and drops columns, renames a primary key column (the only column CQL renames), and drops an index or the table. A column default and `NOT NULL` do not exist in CQL, so the structure tab does not offer them (`DdlCapabilities::column_defaults` and `required_columns`).

Show CREATE TABLE writes the statement from the server's schema tables: `system_schema.columns` for the columns, the key and the clustering order, `system_schema.tables` or `system_schema.views` for every option the release keeps (TTL, compaction, compression, caching and the rest, in DESCRIBE's order), then each secondary index from `system_schema.indexes`. The sidebar lists keyspaces, then tables and materialized views. It leaves out the view ScyllaDB keeps behind each secondary index and the `<table>$paxos` table it keeps for a table's lightweight transactions.

## Values

| CQL type | Read as |
|---|---|
| `tinyint`, `smallint`, `int`, `bigint`, `counter` | an integer |
| `varint`, `decimal` | a decimal of any length |
| `float`, `double` | a float |
| `text`, `ascii`, `boolean`, `blob`, `uuid`, `timeuuid`, `date`, `time`, `timestamp`, `duration` | the matching value; a timestamp in UTC |
| `inet` | text |
| `list`, `set`, `tuple`, `vector` | an array |
| `map`, a user-defined type | the CQL literal |

A zero-length value of a type that has none, which old clients could write, is neither NULL nor a value and reads as undecodable.
