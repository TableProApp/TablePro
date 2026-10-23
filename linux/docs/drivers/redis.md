# Redis

Driver id `redis`, crate `crates/drivers/redis`. It speaks RESP2 through redis-rs 1.7 with its default features off, `aio` and `tokio-comp` only, over a stream the driver opens with `Transport::open` and wraps in TLS itself. The integration suite runs against Redis 8.10, and CI runs it again on 7.4 ([supported servers](../../README.md#supported-servers)). Valkey answers the same commands; the driver names it from `INFO server`, and no suite runs on it. Redis has no SQL: how a key-value engine meets the contract is in [adding-drivers.md, Engines without SQL](../adding-drivers.md#engines-without-sql).

The default port is 6379. Cluster and Sentinel deployments are not supported: the driver talks to one server.

## Links

Every link is a redis-rs `MultiplexedConnection` on a stream of its own:

| Link | Used for | Opened |
|---|---|---|
| Workspace | `SCAN` for the sidebar, a key tab's windows | At connect, and again on the next call after it closed |
| Editor | One editor tab's commands | When the tab first runs, never again behind its back |
| Export | Every reply of the commands an export reads | For the export, closed with it |
| Probe and control | `PING` for `probe` and the link check; `CLIENT UNBLOCK` and `CLIENT KILL` for a stop | For each, closed after |

A link logs in during redis-rs's handshake: `AUTH` with the username and password when there is a password (a password alone logs in as the `default` user), `SELECT` of the connection's database number, and `CLIENT SETINFO` with the app's name and version, whose errors redis-rs ignores. The driver then sends `CLIENT SETNAME TablePro` and `CLIENT ID`. A `NOAUTH` reply there means the server wants a password the connection does not have. A login whose ACL denies `CLIENT ID` connects without an id, and its editor stop can only close the link. Each step of the login, and the connect's `INFO server`, gives up at the login timeout.

The connection's database is a number from 0 (the connect dialog's Database Number, empty for 0). Text that is not a number is refused before anything is opened (`ConfigError::DatabaseNumber`); a number past the server's `databases` setting is the server's `SELECT` error.

A workspace call holds the shared link for one bounded command at a time, so no call waits behind another for long. `probe` opens a link of its own and sends `PING`, so a busy workspace link never makes a server look dead.

## Keys

`scan_keys` walks the keyspace with `SCAN <cursor> [MATCH <pattern>] COUNT 1000`, never `KEYS`, which holds the server for the whole keyspace. A key `SCAN` returns twice is kept once. The walk stops at the end of the keyspace, at the listing's limit (5,000 for the sidebar), or after 5 s of steps that matched little, and says whether it was complete. Each key's type comes from `TYPE`, 500 to a round trip; a key gone since the scan is left out, and a key the ACL lets the login list but not read is listed with the type Other.

A key is any bytes. One that is UTF-8 with no control character and does not open with `"` is listed as it is; any other is written as a quoted redis-cli argument, `"\xff\x00raw"`, which `read_key` reads back to the same bytes and the editor takes as written.

`read_key` reads `TYPE` and `PTTL` in one round trip, then the length and one window:

| Type | Length | Window | Next window |
|---|---|---|---|
| String | `STRLEN` | `GETRANGE 0 1048575`: the first MiB, marked cut when the value is longer | none |
| Hash | `HLEN` | `HSCAN <cursor> COUNT 500` | the scan's cursor |
| List | `LLEN` | `LRANGE <start> <start + 499>` | the next index |
| Set | `SCARD` | `SSCAN <cursor> COUNT 500` | the scan's cursor |
| Sorted set | `ZCARD` | `ZRANGE <start> <start + 499> WITHSCORES`, by rank | the next rank |
| Stream | `XLEN` | `XRANGE <start> + COUNT 500` | the last id plus one sequence number, which every version takes |

Each cursor names the type it was given for. When another client gives the key a new type before Load More, the read starts the new value over instead of sending one type's position to another type's command, and the key tab reloads. A module's type, such as ReJSON-RL, is named and not read. A value that is not UTF-8 reads as bytes, and a string cut inside a character drops the part it cut.

## The editor

The editor sends one command per line, each read as redis-cli's `sdssplitargs` reads a line: blanks part arguments, `"..."` takes C escapes and `\xHH`, `'...'` takes only `\'`, and a quoted argument may span lines. A command whose quotes do not close is refused before it is sent with redis-cli's own `Invalid argument(s)`. The script stops at the first command that fails.

A reply shows as redis-cli lays it out: one value in a cell of its own, an array numbered from 1, a map by its keys, and an element that is itself an array or a map as a JSON cell. A bare `OK` is a completed command. An error reply fails the command with its code, such as `WRONGTYPE`. The run's row limit keeps at most 10,000 rows of a reply; the reply is already whole in memory, so the rest are counted and dropped.

The editor refuses what would turn the link into a stream of pushes or stop its replies: `SUBSCRIBE` and the other pub/sub subscriptions, `MONITOR`, `SYNC`, `PSYNC`, `REPLCONF`, `QUIT`, `CLIENT REPLY` and `HELLO` with any protocol but 2.

`MULTI` opens a transaction the tab tracks from the replies: `MULTI` answered `OK` is in a transaction, `EXEC`, `DISCARD` and `RESET` end it, and a command that cannot be queued fails it, since `EXEC` will abort. The transaction banner's Commit sends `EXEC` and Roll Back `DISCARD`. A tab's `SELECT` changes only its own link.

The editor has no SQL highlighting, completion of tables or keywords, formatter or comment toggle. A history entry is withheld when a command carries a password: `AUTH`, `HELLO ... AUTH`, `MIGRATE ... AUTH | AUTH2`, `ACL SETUSER`, `CONFIG SET` of `requirepass`, `masterauth`, `primaryauth` or a TLS key passphrase, `SENTINEL SET` and `SENTINEL CONFIG SET`, and a script that names one of them. Text whose quotes do not close is withheld too.

## Stops and timeouts

Redis runs one command at a time. A command waiting on a key or a replica (`BLPOP`, `XREAD BLOCK`, `WAIT` and the like) yields the server, and the stop is `CLIENT UNBLOCK <id> ERROR` from a link of its own: the command ends with an `UNBLOCKED` error, the run reports Cancelled, or Timed out with the server's stop, and the tab's link runs the next command. A command still running when the cancel grace ends (a slow script, `DEBUG SLEEP`, `KEYS` on a large database) holds the server itself, so nothing can interrupt it: the driver sends `CLIENT KILL ID <id>`, which the server carries out once the command ends, closes the link, and the tab opens a new one on its next run, with any `MULTI` and `SELECT` gone. A reply that won the race with the stop is shown.

`EditorSessionOptions::statement_timeout` and the run's deadline bound each command the same way. A workspace call stops between its commands: nothing is sent, and a reply still on its way is read and dropped by redis-rs, so the link stays in step.

A call that times out or loses its link checks the route with a `PING` on a link of its own within the cancel grace. Only a route that fails it marks the link lost and turns the timeout into `ConnectionLost`.

## Read-only

Redis has no read-only session, so a read-only connection rests on the app's own check (`ReadOnlyEnforcement::ClientGuard`): each command is read before it is sent, and one that is not a read is refused with `ReadOnlyRefusal::ClientGuard`, in the editor and in an export. A command is a read only when `sql_syntax::redis` lists it, or its container's subcommand, as one; a command it does not know counts as a write, so a new one is refused until it is listed. `SORT` and `GEORADIUS` with `STORE` are writes. For a guarantee, connect as an ACL user that may only read (`+@read`). A replica's own refusal, `READONLY`, is the server's.

Safe Mode reads commands the same way: Confirm Writes asks before every command that is not a read, and Off asks before `FLUSHALL`, `FLUSHDB`, `SWAPDB`, `SHUTDOWN`, `DEBUG` and `FUNCTION FLUSH`.

## Writes

The app saves nothing to Redis but what the editor sends: there is no grid edit of a value, and `write_batch` is `Unsupported(Tables)`. `commit_resolution` is `Unavailable`. A command that writes lists the keys again once its run ends, since it may have added or removed one.

## Exports

A key tab exports the rows it shows. An editor result's All Rows runs its commands again on a link of its own through `stream_read`, refused unless every command is a read, without the tab's `SELECT`.

## Trust

TLS is rustls with aws-lc-rs from `tablepro_net::tls::build_client_config`, wrapped around the transport's stream with tokio-rustls, so an SSH forward carries it too. The certificate is checked against `tls_server_name()`, which the server name override can set on any route. A client certificate is presented when given; Redis does not map one to a user, and a server with `tls-auth-clients yes` refuses a client without one. Under TLS 1.3 that refusal arrives as an alert on the first read after the handshake, and the driver reports it as the TLS failure it is, not as a lost connection.

## Server codes

An error reply's first word is its code, kept as `ServerCode::Redis { prefix }` with the rest as the message. `WRONGPASS` and `NOAUTH` are an authentication failure, `READONLY` the server's read-only refusal, and `UNBLOCKED` the server acknowledging a stop.
