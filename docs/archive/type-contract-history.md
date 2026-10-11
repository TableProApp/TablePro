# Historical record: type-contract-strategy.md

Archived 2026-10-03 from `0cf70382eed72c144ea94208dfef5f5706e0a7dd`. The original content below preserves
dated decisions, commands, test counts and source evidence. Its words such as
‘current’, ‘next’ and ‘pending’ describe their original checkpoint.
Use [the documentation entry point](../README.md), [active sprint](../bookie-0.2-sprint.md)
and [the ADR index](../decisions/README.md) for current instructions. Type/value rules
are owned by ADR 0007; connection/session and persistence rules by ADRs 0008/0009.
Read a relevant heading only; this archive is not mandatory agent startup context.

---

# Type contracts for B3 and future drivers

Coverage reconciled against source at `35d457fa488768a5204a26d785c90114073d4acd`
and documentation tip `62dc257c7` on 2026-09-29. The source baseline includes
the Redis RESP3 contracts, PostgreSQL multirange metadata cases, ClickHouse
DateTime64(9) boundary behavior and SQL Server's safe `sql_variant` metadata
refusal, DuckDB mixed-interval exact-text round trips, and MySQL comment behavior
under both backslash modes. DuckDB primary-key metadata now includes composite
keys for keyed grid edits. The SQL Server type remains unsupported for exact
decoding. MongoDB's app parser now sends values beyond Rust Decimal range through
canonical `$numberDecimal` markers and preserves a 34-digit integer on a native
Decimal128 keyed edit. The strict value suite passed on this clean baseline with
16 DuckDB, 4 Redis, 8 MongoDB driver and 12 app contracts (133 selected tests across 11
suites, no missing suites);
other gates remain distinct from this source/test inventory. Evidence:
`target/quality/20260929T215946474345Z-values/report.json` (`dirty: false`).

A successful query is not evidence that its values survived. The acceptance unit
is a database type, its boundary cases, and each operation that consumes it.
Keep this work inside the current eight drivers. Oracle is a later driver project,
not a dependency of the 0.2.0 sprint.

## Required proof

| Layer | What to assert | Failure to prevent |
| --- | --- | --- |
| Wire decoder | Exact independent expected value, malformed lengths, invalid tags, overflow and resource limits | Debug text, truncation, panic, invalid data becoming NULL |
| Engine round trip | Compare the original native representation with parameter and SQL re-import | Rounding, timezone shifts, loss of decimal scale or interval fields |
| Shared consumers | Parser, grid editing, SQL INSERT, JSON/MCP, file export and import where applicable | Correct decode followed by a lossy consumer |
| Sessions | Repeat under relevant timezone, date/interval style, collation and SQL modes | Defaults masking configuration-dependent corruption |
| Failure paths | Unsupported values remain explicit; writes refuse; existing files survive | A green test produced by skipping, fallback conversion or partial output |
| Mutation and generated cases | Stable seeds, persisted failures, targeted arithmetic/sign/guard mutations | Assertions that execute code without detecting wrong results |

Use four distinct outcomes: exact typed support, exact text fallback, explicit
refusal, and untested. A refusal is a safety contract, not completed support.
Do not mark a type complete from one scalar query or from a crate's green badge.

## Boundary corpus

- Integers: every width and signedness boundary, adjacent values, zero and values
  around 2^53. Never compare exact integers through floating point.
- Decimal: precision and scale limits, trailing zeroes, negative values, exponents,
  tiny nonzero values, overflow, NaN/infinity where the engine supports them.
- Floating point: adjacent representable values, negative zero, subnormals,
  infinities and NaNs. Distinguish numeric equality from bit preservation.
- Temporal: both sides of every epoch, fractional units, precision truncation,
  leap dates, BC/large years, infinities, midnight versus 24:00, UTC offsets with
  seconds, DST folds/gaps, and the engine's finite range.
- Interval: preserve months, days and sub-day units independently; cross mixed
  signs with extremes and session styles. Duration equality alone is insufficient.
- Collections: NULL collection, empty collection, NULL elements, empty text,
  nesting, dimensions/lower bounds, element precision and size limits.

The existing shared scalar corpus remains in `testdata/value-contract.json`.
Add engine-specific fixtures when semantics differ; do not force all engines into
the narrowest shared type. PostgreSQL interval tests now add a deterministic
32-case generated corpus to explicit boundaries and run all 59 cases under four
styles. They construct expected wire bytes independently of the decoder and
verify the fixture before using it as an oracle.

## Current evidence and next targets

This is a prioritization ledger, not an exhaustive inventory of all crate tests.
Detailed checkpoint evidence is in [value contracts](../value-contracts.md).

| Driver | Evidence established by the B3 contract suite | Remaining native-type targets |
| --- | --- | --- |
| PostgreSQL | Scalars, wide NUMERIC text, exact BIT/VARBIT text including leading zeroes, exact six-octet MACADDR and eight-octet MACADDR8 text, IPv6 `inet` host-prefix versus `cidr` network semantics and maximum `pg_lsn` across results, SQL literals and typed binding; scalar and temporal arrays, temporal eras/offsets/infinities, interval fields across styles; array SQL literals, typed text bindings, JSON text and server wire equality; boolean[], bytea[], uuid[], timestamptz[], integer[], text[], numeric[] and float8[] grid edits through allowlisted text casts, with float8[] proving adjacent values, negative zero, minimum subnormal, NaN/infinities and NULL against array_send, boolean[] verifying NULL/sibling identity, bytea[] verifying escaped bytea elements/empty bytes/NULL, uuid[] verifying NULL/sibling identity and timestamptz[] verifying offset-origin fractional instants/NULL plus sibling identity against array_send; PostgreSQL `[]` metadata is retained as text before scalar app parsing; ordinary custom-enum scalar/array projections preserve exact labels and SQL NULL as text with `pg_typeof` checks; direct result projections also preserve literal label `NULL` after the vendored SQLx text-array fix; `json[]` and `jsonb[]` have independent server type/value oracles and are explicitly refused by result, SQL-literal and parameter consumers; a custom enum[] has exact server type/text/JSON oracles; all six built-in range types are explicitly refused against server type/text/bounds/inclusivity oracles; all six built-in multirange types have native type/text/hull/component oracles, with direct projection refused explicitly by SQLx metadata resolution; built-in point, line, lseg, box, path, polygon and circle each have exact native type/text oracles and are explicitly undecodable, with SQL-literal and parameter refusal and separate NULL checks; named composite results are explicitly refused against independent `row_to_json` and field-value oracles; native `money` is explicitly `Undecodable` against a `money::numeric::text` oracle and NULL remains distinct; `citext` preserves case-sensitive label text through results, SQL literal and typed binding while PostgreSQL comparisons remain case-insensitive; custom domains over `numeric`, `uuid`, and `jsonb` preserve their exact values through results and supported SQL consumers, with JSON null distinct from SQL NULL; enum labels preserve exact text through `enum::text`, SQL literal and typed text binding, with a server `pg_typeof` oracle; NUMERIC(80,40), NUMERIC(1000,1000), unconstrained numeric with 16,383 fractional digits and 131,072 integer digits, and other wide numeric grid edits preserve exact text on PostgreSQL; the app parser feeds wide input through the keyed-update builder to server `numeric::text` oracles for declared and unconstrained numeric; year-1,000,000 DATE and upper-bound year-294276 TIMESTAMP are visibly undecodable while their independent server text values remain exact | Full support for finite temporal values beyond the shared calendar, other non-numeric domains, automatic enum parameter type inference and remaining enum write/export consumers, other composites and other range types, other JSON array element types, automatic typing outside the safe built-in array list, additional custom types, and remaining consumer parity |
| DuckDB | Scalars, exact scalar HUGEINT signed min/max, UBIGINT signed-boundary/max and UHUGEINT max through results, SQL literals and text-bound casts; bounded native temporals and date text fallbacks; empty, literal-NULL and Unicode enum labels survive results, SQL literals and typed bindings while SQL NULL stays distinct; native DATE, microsecond TIME and TIMESTAMP parameters; sub-microsecond TIME/TIMESTAMP and every TIMESTAMPTZ parameter use exact VARCHAR fallback, verified by parameter type and echoed value; explicit casts to TIME_NS/TIMESTAMP_NS compare equal to exact nanosecond server literals, while DuckDB rejects `TIME_NS + INTERVAL`; a direct native binding test against the pinned DuckDB crate proves nanosecond TIME/TIMESTAMP parameters are reduced to microseconds; grid parsing refuses sub-microsecond edits for microsecond TIME, TIMESTAMP and TIMESTAMPTZ columns before writes, while finer TIME_NS/TIMESTAMP_NS types retain nanoseconds; independent cast oracles confirm the lower-precision native types drop those digits; simple/composite primary-key columns come from native constraint metadata; all eight sign combinations for mixed month/day/microsecond INTERVAL components decode as exact text, round-trip through SQL literals and explicitly cast parameters, and survive the app parser/keyed-update path as a native interval; interval month/day limits and the largest positive/negative microsecond-aligned carrier values have native `typeof`, `VARCHAR`, `date_part`, literal-cast and bound-cast oracles; wide-valued MAP, LIST, fixed ARRAY, STRUCT and UNION have native type/value oracles and are explicitly refused by decode and SQL-literal/parameter consumers; nested UHUGEINT and UBIGINT array/struct cases, plus a UHUGEINT UNION case, are explicitly refused with native type/text oracles | Installed GTK edit acceptance, additional nested collection combinations, extended timestamps, native sub-microsecond TIME/TIMESTAMP and TIMESTAMPTZ binding (exact text transport is tested; native typed binding remains unsupported), remaining nested unsigned combinations, consumer parity |
| MySQL | Shared scalar and exact decimal paths; values wider than Rust `Decimal`, including 65 integer digits and scale 30, stay exact text through results and JSON/CSV export/import; typed CSV fallback is limited to values fitting explicitly declared precision/scale, accepts catalog `UNSIGNED`/`ZEROFILL` modifiers and refuses unknown/malformed suffixes and out-of-range values; native `HEX(CAST(... AS CHAR))` checks bound and SQL-literal re-import; unsigned BIGINT, signed and extended TIME, zero and partial-zero dates, YEAR, UTC TIMESTAMP decoding with pool reset before each checkout and explicit refusal in non-UTC dedicated sessions, text and JSON SQL export/re-import under default, `NO_BACKSLASH_ESCAPES`, `ANSI_QUOTES`, and combined modes on MySQL and MariaDB, `STRICT_TRANS_TABLES` versus permissive unsigned clamp behavior, `PAD_CHAR_TO_FULL_LENGTH` fixed-width CHAR through results/CSV/bound/literal writes, BIT(1..64) as integers (bytes above i64), ENUM/SET labels, spatial values as stored SRID-prefixed bytes; unignored app parser contracts enforce signed/unsigned integer width boundaries, while the live keyed edit preserves `TINYINT UNSIGNED` 255 and `BIGINT UNSIGNED` `u64::MAX` with native text oracles; this edit refuses 256 before permissive-mode clamping can corrupt it; BIT(1), BIT(8) and BIT(63) also have parser-to-keyed-update contracts with native HEX() oracles; BIT(64) above i64 remains bytes and is refused by the parser; GTK tests keep spatial and too-wide BIT bytes read-only; backslash-bearing column comments are refused explicitly, with a live-server regression proving default and NO_BACKSLASH_ESCAPES store different comment bytes; unexpected SQLx I/O EOF after a server-side connection kill maps to `Disconnected` and the pool recovers, while `ConnectionRefused` remains distinct | Other SQL modes outside the enumerated cases, session-aware DDL comments, installed GTK-to-MySQL edit acceptance, consumer parity |
| SQL Server | Shared scalar and Unicode SQL export paths; datetime2(7) result decoding preserves the seventh fractional digit against independent server text and SQL literal re-import; smalldatetime's 29.998/29.999-second rounding threshold matches native text; all 300 legacy `datetime` ticks now use exact typed nanosecond values where possible and canonical style-126 text otherwise, with native text and parameter round trips matching all eight stored bytes and representative SQL-literal re-import matching bytes; SQL NULL remains distinct; DATE year-0001/year-9999, TIME(7) minimum/maximum and DATETIME2(7) minimum/maximum supported calendar values are checked against independent native text through results, parameters and SQL export/re-import; datetimeoffset retains its original offset and 100 ns fraction through results, parameters, SQL export/re-import, exact JSON, and CSV export/import with native instant and offset oracles; money/smallmoney values are explicitly undecodable because Tiberius exposes them as floats; the pinned Tiberius `sql_variant` metadata panic is converted to an explicit unsupported error and the affected connection/session is retired, with a Docker regression checking exact bigint server text first | Money/smallmoney and `sql_variant`, plus temporal types or conversions outside the tested DATE/TIME/DATETIME2 calendar edges |
| ClickHouse | Shared scalar, decimal with declared scale, nonfinite and long-value contracts, `DateTime64` every scale 0 through 9 in-range plus extended-range scales 0 through 7, named-zone instants decoded through IANA timezone rules, nanosecond temporal parameters and SQL exports, local refusal of out-of-range `DateTime64(9)` parameters and SQL literals; a Docker-backed boundary contract checks exact lower/upper nanosecond epochs and pins ClickHouse 24.8 behavior just outside them (lower-year clamp, upper-range error); a New York DST fold proves ambiguous local text is `Undecodable` and refused by SQL-literal/parameter consumers, while a nonexistent spring-forward input is checked against ClickHouse 24.8's normalized wall time and epoch; Int128 min/max and UInt128 max remain exact text through real-server results, text binding, SQL and CSV export/import both with formula sanitization disabled and with default sanitization; keyed grid edits cover Int128 min/max and UInt128 zero/max adjacent values; fifteen nested Array/Map/Tuple combinations, including `Map(UInt8, Nullable(UInt128))`, `Map(UInt8, Array(Nullable(UInt128)))` and `Array(Map(UInt8, Nullable(UInt128)))`, preserve exact JSON against native type and toJSONString oracles; nested Decimal(38, 9)/DateTime64 and nullable/empty Decimal-array cases preserve exact JSON through JSON and CSV exports plus CSV import; SQL export and typed parameters refuse values without native type metadata, and real MergeTree keyed-edit attempts refuse all nested shapes while the native stored rows remain unchanged | Other temporal precision/timezone boundaries, additional nested combinations and cross-consumer parity |
| MongoDB | Decimal128 extremes remain exact text; BSON dates outside chrono's RFC3339 range, nested documents/arrays and all BSON enum kinds preserve canonical Extended JSON where needed; Generic, Function, BinaryOld, UUIDOld, UUID, MD5, Encrypted, Sensitive, Vector, Reserved `0a`, UserDefined `80`, and valid Column subtype `07` survive native-server keyed edits with exact subtype and bytes; valid BSONColumn payloads come from compressed time-series buckets, while malformed opaque bytes are refused by MongoDB as `NonConformantBSON` 378; aligned BSON DateTime edits preserve milliseconds and sub-millisecond `DateTime`/`TimestampTz` values are refused before rounding; native keyed-edit contracts cover Timestamp, regex, JavaScript, code-with-scope, Symbol, ObjectId, DbPointer, Undefined, MinKey and MaxKey, with canonical Extended JSON conversion and `value_to_bson` unit round trips; page metadata combines the first-50 sample with returned rows and now drives visible grid editability, filters and factory rebuilds when types change; homogeneous positive Decimal128 and formula-sanitized negative Decimal128 survive default CSV export, typed import parsing and keyed grid save as native BSON Decimal128; mixed BSON columns now decode each value as canonical Extended JSON, preserving String versus Decimal128 through JSON/CSV/XLSX; a real MongoDB MCP browse round trip compares the response with native BSON values for Decimal128, DateTime, user-defined binary, Int64, NULL and Unicode | Collection-wide heterogeneity outside sampled and returned-page documents |
| Redis | Integer/text/NULL protocol contracts; RESP3 hash maps retain key/value rows and invalid UTF-8 bulk values as bytes; XREAD stream replies preserve nested arrays and binary markers; a local RESP3 TCP fixture proves attribute wire frames survive the redis client and become tagged JSON; nested arrays, maps, sets and binary leaves retain JSON structure with explicit tags; BigNumber replies retain exact decimal digits as text, including inside nested arrays; map row caps set `truncated`; Pub/Sub subscribe/unsubscribe, MONITOR and CLIENT TRACKING ON are explicitly refused by the one-shot query interface and verified against Redis 7.4; tracking refusal covers BCAST, OPTIN, NOLOOP, REDIRECT and mixed-case command spellings | Consuming asynchronous push frames remains open; SQL date types are not applicable |
| SQLite | Shared scalar/binary contracts; NUMERIC affinity text, real, integer, blob and NULL transitions survive bound edits, SQL-literal re-import and policy-guarded CSV import; the app parser plus keyed-update contract verifies `42.50` becomes SQLite REAL `42.5` | Installed GTK/package acceptance across storage-class transitions; fixed-decimal storage is not applicable |

ClickHouse's temporal boundary evidence now includes both a one-hour New York
fall-back and Lord Howe's 30-minute fall-back; both ambiguous local values are
refused by result and type-less write consumers. This adds two named folds, not
an exhaustive IANA transition matrix.

### B3-P1 consumer audit result — September 29

The remaining-column entries above are classified as untested combinations or
unfinished exact support unless they explicitly name a refusal or an external
blocker. Explicit refusal protects existing data but does not satisfy exact
support. Applied across drivers, the live status is: PostgreSQL has exact
scalar/array/temporal coverage plus explicit refusal or SQLx metadata blockage
for several advanced families; DuckDB has exact text fallbacks, grid-edit and
filter refusals for sub-microsecond values targeting lower-precision temporal
columns, with native sub-microsecond bindings still unsupported; MySQL now has
live contracts for `PAD_CHAR_TO_FULL_LENGTH`, `STRICT_TRANS_TABLES`, permissive
unsigned clamping, and both backslash modes, while other SQL-mode and
DDL-session cases remain open; SQL Server now has exact typed/text support for
all legacy `datetime` ticks, while money and `sql_variant` still refuse pending
exact representations;
ClickHouse has explicit finite-range/DST behavior and now selects a lower exact
DateTime64 precision for values beyond the scale-9 Int64 ceiling, while more
nested/temporal combinations remain open; MongoDB has native-server edits for
named BSON kinds, including Generic and UUID-subtype binary; millisecond-aligned
DateTime writes are exact and sub-millisecond writes refuse before rounding.
Collection-wide type heterogeneity outside sampled/current-page documents
remains unverified, and other top-level edits outside named grid contracts
remain untested;
Redis refuses identified asynchronous command streams and tests RESP3 attribute
wire decoding, while asynchronous push consumption is unsupported; SQLite has
storage-class/parser/import contracts but installed GTK acceptance is untested.

The October 1 PostgreSQL CSV follow-up closes one temporal consumer gap:
formula-safe `-infinity` markers are restored only for recognized PostgreSQL
temporal columns, and text parameters are explicitly cast back to the catalog
temporal type. Mixed finite/infinite rows share the same parameter type. The
live integration contract checks DATE, TIME, TIMETZ, TIMESTAMP and TIMESTAMPTZ
against exact server text after import; see the
[value ledger](value-contract-history.md#postgresql-era-and-mutation-checkpoint).

### PostgreSQL scalar custom-enum diagnostic contract — October 2

The scalar enum contract permanently exercises the direct projection as well
as exact `enum::text`, SQL-literal and typed-text behavior against `pg_typeof`.
Ordinary labels and SQL NULL now return exact text/NULL values for both scalar
and array projections. A label whose text is exactly `NULL`, alongside SQL
NULL, still triggers SQLx `enum_labels: unexpected NULL` during metadata
resolution. That dependency error is not a BookiE `Undecodable` value or an
accepted 0.2 refusal; complete enum label coverage remains open for B3.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --test integration value_contracts::value_contract_scalar_enum_labels_preserve_exact_text -- --include-ignored --exact --test-threads=1
```

The [value ledger](value-contract-history.md#postgresql-scalar-enum-label-text-projection)
records the passing PostgreSQL 16 contract and clean 185-test value run on
`e704831`. Direct native enum decoding remains unsupported; B3 still has the
other named matrix targets above.

The DuckDB `UBIGINT[]` case above the signed boundary compares exact native
array text and records the current `Undecodable` result plus SQL-literal/bind refusal; see the
[value ledger](value-contract-history.md#duckdb-nested-ubigint-array-refusal-2026-10-02).
This closes that shape's behavior contract, not nested-array support. A second
contract covers `STRUCT` fields with `UBIGINT` values above the signed boundary,
`u64::MAX` and NULL; native `typeof`/`VARCHAR` and explicit result/literal/bind
refusal passed in the clean 187-test strict layer at `19c5b6a`. A third
contract covers `MAP(VARCHAR, UBIGINT)` with the same wide boundaries and NULL.
Exact native oracles and result/literal/bind refusal passed in the clean
188-test strict layer at `efcbec7`. A fixed-size `UHUGEINT[2]` case also pins
the >`u64::MAX` value and SQL NULL, with explicit result/literal/bind refusal.
Its focused test, strict 189-test layer and quick gate passed on `98611db`.
Other nested unsigned collection shapes remain open.

The ClickHouse nested contract now covers fifteen Array/Map/Tuple shapes,
including `Map(UInt8, Nullable(UInt128))`,
`Map(UInt8, Array(Nullable(UInt128)))`, and
`Array(Map(UInt8, Nullable(UInt128)))` with wide unsigned values and NULL. It
uses native type and JSON oracles and checks JSON/CSV preservation plus
type-less SQL, binding and edit refusal. Other nested combinations remain open;
the strict 186-test, 11-suite value layer passed at code commit `0970896`.
See the [value ledger](value-contract-history.md#clickhouse-numeric-key-nullable-map-2026-10-02)
for the report.

### Connection-loss contract update — September 30

Docker-backed tests stop each remote server after a successful request and
require the next operation on the established connection to return
`DriverError::Disconnected` for PostgreSQL, MySQL, SQL Server, MongoDB, Redis
and ClickHouse. PostgreSQL and MySQL verify pool recovery both after a query
terminates a pooled connection and after the server container stops and restarts
with its host port held stable. SQL Server, MongoDB, Redis and ClickHouse restart
the same container, open a fresh driver connection and require a protocol-level
operation to succeed. These tests verify pool or explicit reconnect after
restart, not transparent recovery of a previous non-pooled connection handle.
SQLite and DuckDB are local engines, so they are not part of this remote-server-
loss set. All six remote drivers also have native-driver checks against an unused
local TCP port, proving connect-time refusal is distinct from established loss.
PostgreSQL and MySQL exercise this through SQLx pool setup, not only the pure
error mapper. After these cases were added, the complete `drivers` layer passed
207 driver, MCP, socket and SSH tests in 864.5 seconds with no failures. Evidence:
`20260930T021134930354Z-layers/report.json` (historical artifact `../target/quality/20260930T021134930354Z-layers/report.json` is unavailable in this checkout).

The complete layer was rerun at source SHA `8ed0f66ed54b1411feaac5d7a8e49abc6999fb18` on September 30. It ran 219 tests with zero failures or ignored tests in the executed suites, taking 939.7 seconds. All six remote-driver disconnect and stream/page-loss cases passed, including PostgreSQL/MySQL pool recovery and SQL Server/MongoDB/Redis/ClickHouse restart paths. Evidence: `20260930T110146955489Z-layers/report.json` (historical artifact `../target/quality/20260930T110146955489Z-layers/report.json` is unavailable in this checkout).

At `f88159dcb23dd74a960c638a6af42b608a1b4345`, the full `drivers` layer
passed again: 220 tests, zero failures, in 984 seconds. The executed log
contains established disconnect, whole-query failure after mid-stream loss,
pool or reconnect recovery, and six unused-port `ConnectionRefused` checks.
`20260930T232244336622Z-layers/report.json` (historical artifact `../target/quality/20260930T232244336622Z-layers/report.json` is unavailable in this checkout)
is the clean-tree report.

After splitting the nested MongoDB test into its own support module, the strict combined value-contract layer passed with GTK and DuckDB enabled at base SHA `736a73f8434a57fd33dbe9d6212956e29351b168`: 144 selected tests across 11 suites, no missing suites, and zero failures in 201.7 seconds. Its report records 746 fresh build artifacts and one rebuilt package. The quick layer then passed in 92.0 seconds, including the file-size and function-size guards. Evidence: `20260930T114622059959Z-layers/report.json` (historical artifact `../target/quality/20260930T114622059959Z-layers/report.json` is unavailable in this checkout) and `20260930T114425279874Z-layers/report.json` (historical artifact `../target/quality/20260930T114425279874Z-layers/report.json` is unavailable in this checkout).

Redis and ClickHouse mapper mutations are retained at
`target/quality/20260930-redis-disconnect-mutants-final/` and
`target/quality/20260930-clickhouse-disconnect-mutants-final/`. Redis caught
8/9 mutants, with one unviable and none missed or timed out; a temporary-filesystem
quota blocked the first copy-based baseline before mutation execution. The
in-place retry exposed two equivalent Redis predicates, which were simplified
before the final run. ClickHouse caught 4/5 mutants, with one unviable and none
missed or timed out; the first run's missed connect-error distinction gained a
regression before the final run. MySQL and MongoDB disconnect mapper mutation
evidence is recorded in [value contracts](../value-contracts.md).

PostgreSQL and MySQL have Docker regressions that terminate a slow query after
row production has begun; each whole query must fail as `Disconnected`, never
return a partial result, and its pool must recover. ClickHouse tests both a
hard server stop (`Disconnected`) and graceful shutdown, which must return the
server's cancellation error rather than partial rows. SQL Server now tests
server loss while draining a multi-result stream and requires `Disconnected`,
no partial result, and a successful fresh connection after restart. These
focused cases passed. MongoDB now has a cursor `getMore` loss test after its
first batch, and Redis has a browse-page loss test after `SCAN` while reading a
key. Both require the whole operation to fail as `Disconnected`; Redis also
verifies that a later browse through the same driver object uses a fresh
operation-local connection and returns the full row. MongoDB now pins its
container to a stable host port and verifies the existing client recovers after
restart; a focused Docker regression passed. MongoDB also tests an in-flight
cancellation separately: the held-open socket yields
`OperationOutcomeUnknown(Cancelled)`, not `Disconnected`. PostgreSQL, MySQL,
ClickHouse, Redis and SQL Server retain their distinct cancellation and
post-cancellation connection policies. The tested expectations and runner
ownership are consolidated in [disconnect contracts](../disconnection-contracts.md).
Native-type and consumer targets in this matrix remain open. Passing the
server-loss and explicit reconnect cases does not close those other gaps.

The MongoDB cancellation cell now has a Docker regression: `currentOp` confirms
`listCollections` is active before cancellation, the outcome is
`OperationOutcomeUnknown(Cancelled)`, and the same client successfully performs
a later collection listing. This completes the consolidated disconnect and
cancellation index; its per-driver test ownership and remaining post-cancellation
limits are in [disconnect contracts](../disconnection-contracts.md). Native-type
and consumer targets in this type matrix remain open.

The strict combined values layer also passed against source SHA `636584f` on
September 30 in 219.9 seconds, with all selected suites exiting 0. Its report is
`target/quality/20260929T233014301456Z-layers/report.json`; local Docker
server-loss regressions are recorded separately because they are not all part of
the shared value-contract filter.

MongoDB Decimal128's bounded grid-edit gap is now covered for 34-digit integer
and fractional text beyond `rust_decimal`, with an independent BSON oracle; input
outside Decimal128 precision is explicitly refused.

PostgreSQL and MySQL now have failing-first server-side connection-loss tests.
PostgreSQL maps server-termination SQLSTATEs and unexpected SQLx socket loss to
`Disconnected`, preserving query cancellation, TLS and connection-refusal
errors. MySQL maps unexpected SQLx I/O loss to `Disconnected` while preserving
TLS and connection refusal; both Docker cases verify pooled query recovery.
The MySQL unsigned grid-edit contract now uses pinned sessions to compare the
permissive clamp with `STRICT_TRANS_TABLES` rejection, then verifies parser
refusal and a valid exact edit in strict mode. Other SQL-mode and DDL-session
combinations remain open.

MongoDB late-page BSON conflicts now have an app-level native-server contract:
after an initial 50-row string sample, a fetched page containing Decimal128
updates the column to `mixed`, rebuilds the grid layout and blocks inline edit.
An independent client checks the persisted BSON kind and row identity. This
establishes the current-page safety contract; a full-collection type census is
not part of the paged browse contract and is not claimed.

The Docker-backed app case passed with the strict GTK/DuckDB value selector:
26 app tests and 163 tests across all 11 configured suites passed at working
tree source `7fd33187c1f9bfa024a09be85e203bb82e8f24c4`. The quick layer also
passed on that tree. Reports:
`20260930T215342621227Z-values/report.json` (historical artifact `../target/quality/20260930T215342621227Z-values/report.json` is unavailable in this checkout)
and
`20260930T215742792833Z-layers/report.json` (historical artifact `../target/quality/20260930T215742792833Z-layers/report.json` is unavailable in this checkout).
Scoped mutation testing of `columns_for_browse_page` caught three of six
generated changes; the other three were unviable, with no misses or timeouts.
The in-place report is
`outcomes.json` (historical artifact `../target/quality/20261001-mongodb-page-schema-mutants-inplace/mutants.out/outcomes.json` is unavailable in this checkout).

ClickHouse nested refusal coverage now also includes an array of tuples carrying
`Decimal(38, 9)` and `DateTime64(9, 'UTC')`, checked against native type and JSON
oracles with unchanged-row assertions after consumer refusals. It now also
includes an `Array(Tuple(String, Array(Nullable(Decimal(38, 9)))))` case with
an exact high-precision decimal, NULL element and empty nested array. It uses the
same native JSON oracle and requires export, binding and keyed-edit refusal with
the stored row unchanged. More nested temporal, decimal and collection
combinations remain untested. Its scoped decoder mutation run caught 9 of 10
generated changes; one was compile-time unviable, with no survivors or
timeouts. The strict 163-test value run and quick layer passed on the working
tree; details are in [value contracts](../value-contracts.md).

An October 6 ClickHouse 24.8 follow-up adds
`Map(UInt8, Array(Tuple(String, Nullable(UInt128))))` to the nested consumer
matrix. The native type/JSON oracle includes a UInt128 above `u64::MAX`, a NULL
tuple field and an empty nested array; JSON/CSV retain the oracle value, while
SQL literals, parameter binding and keyed edits refuse without changing the
stored row. The focused case and all 33 ClickHouse integration tests passed
([evidence](../evidence/clickhouse-nested-map-array-tuple-results-2026-10-06/manifest.json)).

The October 6 XLSX follow-up checks all 16 nested shapes from the same Docker
contract. Each result is written as an XLSX text cell and its shared-string
entry equals ClickHouse's native `toJSONString()` oracle; type-less write
refusals remain unchanged. The focused contract and full 33-test ClickHouse
integration suite passed
([evidence](../evidence/clickhouse-nested-xlsx-consumers-2026-10-06/manifest.json)).

Two small MongoDB edit gaps identified in this audit now have native-server
contracts: a non-key ObjectId edit preserves `_id` and BSON kind, and an RFC3339
BSON DateTime edit preserves millisecond UTC instants while refusing sub-ms
input before writes. The latter combines app parsing, keyed update construction,
and an independent MongoDB client oracle. The clean strict run passed 133
selected contracts across 11 suites at
`35d457fa488768a5204a26d785c90114073d4acd`. Collection-wide heterogeneity and
named top-level edits without native-server assertions remain open; evidence is
in [value contracts](value-contract-history.md#mongodb-nested-bson-and-native-boundary-checkpoint).

## Consumer coverage reconciliation, 2026-09-28

| Type / consumer | Established behavior | Remaining status |
| --- | --- | --- |
| PostgreSQL supported arrays / decode, SQL INSERT, JSON | Exact PostgreSQL array text preserves NULL, literal `NULL`, dimensions, lower bounds and supported scalar/temporal elements; real-server wire equality is tested after SQL and typed-text re-import | Built-in `integer[]`, `text[]`, `numeric[]`, `float8[]`, `boolean[]`, `bytea[]`, `uuid[]`, and `timestamptz[]` grid write-back are verified. The text case includes NULL and escaped text; numeric covers high precision, scale, special values and NULL; float8 covers adjacent/special values; bool, bytea and uuid cover NULL and sibling identity; timestamptz covers offset-origin fractional instants/NULL and sibling identity with native array_send oracles. Builder-level generated SQL assertions cover every allowlisted built-in cast alias and reject malformed modifiers. PostgreSQL `[]` metadata remains text in the app parser so scalar element names do not parse the whole array literal. Both `json[]` and `jsonb[]` are explicitly undecodable and refused by SQL literal and parameter consumers against independent server type/value oracles; no JSON-array support is claimed. `inet[]`, `cidr[]`, `macaddr[]`, `macaddr8[]`, `pg_lsn[]`, `bit[]`, and `bit varying[]` now have explicit refusal contracts against native type, text and JSON oracles; the catalog census now covers every other enumerated built-in array: 22 named arrays have exact native type/text/JSON oracles and an asserted driver-level blocker (SQLx composite/multirange metadata failures or PostgreSQL missing binary output for `aclitem`/`gtsvector`); `name[]` is tested separately. The complete built-in array census is therefore recorded, though those blocked arrays remain unsupported. |
| PostgreSQL array text / grid edit | Array values are `Value::Text`; app parser preserves array literals and the shared update builder casts allowlisted built-in array types safely. CSV import now also classifies array cells as text, preserving driver array syntax instead of parsing the element type as a scalar. | The real-server contracts reproduce and prevent SQLSTATE 42804 (`integer[]` target, TEXT expression); integer[], text[], numeric[], float8[], boolean[], bytea[], uuid[] and timestamptz[] grid regressions compare native values/wire bytes, with float8[] also tested through CSV export/import and keyed re-edit; timestamptz[] checks offset-origin fractions and NULL. Server oracles check array contents and sibling identity. UUID[] added a regression for accidental scalar parsing of the whole literal and verifies its native array_send representation. |
| PostgreSQL wide NUMERIC / grid edit | Builder unit tests prove `NUMERIC(80,40)` text edits emit a cast through `text` to static `pg_catalog.numeric`; ordinary text columns remain uncast and hostile metadata is rejected. Docker-backed contracts verify exact equality for `NUMERIC(80,40)`, `NUMERIC(1000,1000)`, unconstrained `numeric` with a 40-digit integer/40-digit fraction, maximum 16,383-digit fractional scale, maximum 131,072-digit integer width, a numeric domain through results and both SQL consumers, and keyed edits of `NaN`, `Infinity`, and `-Infinity` through PostgreSQL's `numeric::text` oracle. The app parser output reaches the keyed-update builder and real server for declared and unconstrained numeric, including all three special values. | Other text-backed PostgreSQL types remain open. |
| MongoDB nested BSON / grid, JSON, CSV, XLSX, MCP | Existing integration cases cover nested values and Timestamp/regex/MinKey/MaxKey/JavaScriptCode/JavaScriptCodeWithScope/Symbol/Undefined/DbPointer top-level edits plus canonical Extended JSON preservation across these consumers. The CodeWithScope edit verifies native code and Int64 scope fields; standalone JavaScriptCode, Symbol, Undefined and DbPointer edits verify native BSON kinds. A new Docker-backed app contract parses and saves a whole nested document through the keyed-update path, then checks exact Int64, Decimal128 and ObjectId kinds, the stable row key and untouched sibling. Page metadata combines the first-50 sample with returned page rows. Homogeneous positive and negative Decimal128 values survive default CSV export, typed parsing (including removal of the formula-safety marker for a valid decimal), and keyed edit as native BSON Decimal128. Mixed BSON columns decode to canonical Extended JSON values; a Docker-backed mixed String/Decimal128 contract verifies distinct JSON values plus CSV and XLSX output, retains native stored kinds, and is read-only in the app grid. A separate ignored Docker-backed MCP `browse_table` contract first checks the seeded document through MongoDB's native BSON driver, then verifies exact Extended JSON markers for nested Decimal128, BSON DateTime, user binary subtype `80`, Int64 above 2^53, NULL and Unicode in the real MCP response. The focused MCP contract passed on the current baseline. BSON `int` grid edits now retain Int32 (rather than silently widening to Int64) and refuse overflow; `long` edits preserve Int64 including values above 2^53, with native server oracles. | Collection-wide heterogeneity outside the sampled and returned page remains unknown. Other top-level BSON kinds outside the named edit cases remain untested. |
| SQLite NUMERIC affinity / parser, keyed grid save and import | The app parses `42.50` as Decimal, materializes the keyed edit, and SQLite stores the NUMERIC-affinity result as REAL `42.5`; driver contracts cover TEXT, BLOB, NULL, REAL and INTEGER transitions plus SQL-literal re-import | Installed GTK/package grid acceptance across the storage-class matrix remains open. |
| ClickHouse Int128/UInt128 / result, SQL, JSON, CSV, XLSX and grid consumers | Local raw-token parser checks plus Docker-backed ClickHouse 24.8 tests prove Int128 signed minimum/maximum and UInt128 maximum remain exact `Value::Text` through results, text binding, SQL INSERT and CSV export/import both with formula sanitization disabled and default sanitization. The typed import removes the apostrophe marker only for valid Int128/UInt128 values in range; unit cases retain it for invalid, overflow, negative UInt128 and ordinary text. Keyed grid edits cover Int128 min/max and UInt128 zero/max adjacent values, with non-target row identity checked after each edit. JSON and XLSX writer contracts now check all three full-width values remain exact JSON strings and workbook shared-string cells. | Other value-consumer boundaries remain untested. |
| JSON / floating point | Negative zero exports as numeric `-0.0`; parsing preserves its IEEE-754 sign bit and keeps positive zero and SQL NULL distinct. A deterministic matrix covers six explicit edge values, 65,536 raw finite-bit samples and 20,470 sign/exponent/mantissa boundary values (86,012 entries total) through CSV typed import and JSON export/parse with exact bit comparisons; the raw-bit sample excludes exponent-all-ones patterns. See [the retained finite-float evidence](../evidence/finite-float-consumer-results-2026-10-04/manifest.json). Booleans remain JSON booleans and distinct from text `"true"`/`"false"` and SQL NULL. | Exhaustive finite-`f64` enumeration, spreadsheet-application re-import and broader temporal combinations remain open. |
| CSV / numeric, floating point, time zone and NULL | `BIGINT` CSV export/import preserves `i64::MIN`, `i64::MAX`, and `9007199254740993` exactly; typed `DECIMAL(10,4)` export/import preserves the `12.3000` trailing-zero scale; negative zero, the smallest positive subnormal, largest finite `f64`, six explicit edge values, 65,536 deterministic raw finite-bit samples and 20,470 deterministic sign/exponent/mantissa boundaries preserve IEEE-754 bits through CSV export, typed import and JSON export/parse (86,012 entries total); a nine-digit offset-origin `TIMESTAMP WITH TIME ZONE` produces identical canonical UTC text through CSV and JSON, then CSV typed import recovers the same instant; `NaN`, positive/negative infinity and NULL retain distinct float/null variants through CSV export/import | Exhaustive finite-`f64` enumeration, broader temporal combinations and spreadsheet-application import remain open. |
| XLSX / wide numeric, temporal, nested BSON | Wide integers and exact decimals use text cells; temporal values use native cells only when exact, otherwise text; an offset-origin nine-digit `TIMESTAMP WITH TIME ZONE` is emitted as its exact canonical UTC instant; nested BSON markers are retained; Excel-safe finite floats remain numeric; negative zero, subnormals, values beyond 15 significant digits and out-of-range magnitudes use exact text cells, with workbook XML tests for both numeric boundaries | Spreadsheet-application re-import and remaining XLSX precision/format limitations remain per the checkpoint entries below. |

The October 1 PostgreSQL array import follow-up closes the INSERT side of the
CSV consumer contract for all 20 allowlisted built-in array families. A real
server test renders and parses the arrays through the shared CSV consumers,
executes `build_insert_plan`, then compares each imported value's exact native
text and `array_send` bytes. `float8[]` also retains its extra grid-edit, keyed
re-edit and CSV export checks described above. Automatic typing beyond the
static allowlist, unsupported element OIDs, and other consumer parity targets
remain open.

DuckDB `INTERVAL` now has an embedded-engine CSV export/import contract for all
eight component-sign combinations, carrier extrema, zero and NULL. Import keeps
interval text exact, reverses the formula-safety prefix only for the driver's
canonical interval grammar, and compares native `typeof`, `VARCHAR`, and
independent `date_part` fields. The failing-first case also corrected the
shared classifier's `INTERVAL`/`POINT` substring collision with `int`.

### DuckDB nested UHUGEINT refusal coverage — September 30

The native type ledger now includes both `STRUCT(amount UHUGEINT)` and a list
of that struct. Each case checks DuckDB's independent `typeof` and exact text
before requiring `Undecodable` output and refusal by SQL-literal and parameter
consumers. Other nested collection combinations remain open; this does not
claim general nested unsigned support.

### MySQL spatial grid refusal — September 30

All eight MySQL spatial column types now have driver-aware parser refusal
coverage. A native MySQL contract verifies type, WKT and stored HEX values for
GEOMETRY, POINT and MULTIPOLYGON and confirms the refused edit leaves both rows
unchanged. GTK-level read-only behavior remains covered separately; installed
GTK-to-MySQL acceptance and other SQL-mode cases remain open.

### PostgreSQL scalar-enum CSV boundary whitespace — October 6

The scalar custom-enum CSV round trip now includes labels with leading and
trailing spaces. Exported CSV parsing and typed import preserve both labels
exactly; the native query checks their text, enum type, and sibling notes.
The same case keeps empty-label versus SQL NULL ambiguity explicitly refused
unless the CSV provides a NULL marker. See the
[focused PostgreSQL evidence](../evidence/postgres-enum-scalar-csv-whitespace-2026-10-06/manifest.json).

## Test workflow

1. Add a failing native-engine or decoder reproducer. Record the failure before
   changing production code. Include an independent expected value or native wire
   representation so a shared formatter bug cannot make both sides agree.
2. Add nearby boundaries and malformed input. Seed generated cases deterministically;
   promote every discovered failure into a named minimal regression.
3. Fix the narrow conversion boundary, then test its consumers and session paths.
   Keep exact text and unsupported markers distinct from ordinary typed values.
4. Run the affected crate tests, then `python3 scripts/run-test-layer.py full values
   harness`. The values layer includes GTK and DuckDB and checks that every listed
   contract executes exactly once; Docker failures are failures, not skips.
5. Run scoped cargo-mutants on the changed logic. Investigate survivors and timeouts;
   report unviable mutations separately. Broader scheduled mutation coverage
   complements this step. Add byte-level fuzz targets for decoder/parser input
   as a separate follow-up; this checkpoint does not add a fuzzing pipeline.
6. Update the ignored-test inventory when adding fixture tests, preserve reports,
   and document remaining gaps. Installed UI, Wayland and release acceptance remain
   separate gates.

When Oracle is introduced later, require this same applicable conformance suite
plus Oracle-native cases before claiming support. Define its NUMBER, DATE,
timestamp/timezone, interval, LOB and empty-string semantics explicitly. Do not

## PostgreSQL `citext[]` refusal baseline — 2026-10-06

The scalar `citext` contract covers case-preserving text and case-insensitive
comparison. This original test and evidence packet recorded a then-current
refusal boundary: non-null and empty arrays displayed as
`Undecodable("CITEXT[]")`, with SQL NULL distinct. That status was superseded
by `value_contract_citext_array_decodes_and_rebinds_exact_values` and
`value_contract_postgres_citext_array_grid_edit_preserves_case_nulls_and_sibling`,
which now cover result, parameter, grid and CSV round-trips against native wire
oracles ([current evidence](../evidence/postgres-citext-array-roundtrip-results-2026-10-06/manifest.json),
[original refusal evidence](../evidence/postgres-citext-array-refusal-results-2026-10-06/manifest.json)).

## PostgreSQL BIT and VARBIT arrays — 2026-10-06

An uncovered built-in array family failed first as `Undecodable("BIT[]")`.
The array decoder now uses the existing scalar BIT/VARBIT binary decoder for
array elements, and the SQL planner allowlists only PostgreSQL's built-in
`bit[]` and `varbit[]` casts. The Docker contract checks fixed-width values,
1/8/9-bit varying values, an empty bit string, SQL NULL arrays/elements, and a
zero-based lower bound. Native `array_to_json`, `pg_typeof`, and `array_send`
values are compared after text-parameter rebinding and typed CSV restore. The
built-in OID census includes BIT and VARBIT; remaining-unlisted array families
continue to require visible refusal. See
[evidence](../evidence/postgres-bit-arrays-results-2026-10-06/manifest.json).

The app grid contract now parses and writes `bit(5)[]` and `bit varying[]`
through the fixed built-in casts. PostgreSQL 16 confirms edited types and
`array_send` bytes match native literals for zero-based arrays, empty bit
strings and SQL NULL elements. Malformed input returns SQLSTATE `22P02` and
leaves the edited and sibling rows unchanged ([grid evidence](../evidence/postgres-bit-array-grid-edit-results-2026-10-06/manifest.json)).

## PostgreSQL `pg_lsn[]` refusal baseline superseded — October 6

The earlier built-in array census recorded `pg_lsn[]` as explicitly undecodable.
That result is superseded by `value_contract_pg_lsn_array_result_bind_keyed_edit_and_csv_are_exact`:
the binary decoder and inferred binding preserve the full LSN range and SQL
NULL; the keyed-update builder and typed CSV import restore the native type and
`array_send` bytes, with malformed input refused before mutation and the sibling
row unchanged. Other unlisted array families remain open
([current evidence](../evidence/postgres-pg-lsn-array-results-2026-10-06/manifest.json)).


---

# Archived B3 board narrative (2026-10-09 consolidation pass 2)

Moved from [type-contract-strategy.md](../type-contract-strategy.md) at tip `2978efe67`. This is dated evidence narrative, not the live board. Open remaining scope stays on the board's engine table; case proof lives in [value-contracts.md](../value-contracts.md) and `evidence/`. Failed or incomplete acceptance notes below remain retest indicators.

## Intro paragraphs (pre-section)

MySQL transaction queries already shared the production result collector; the
Docker suite now also checks the decoded-byte limit, exact retained payloads,
the `truncated` flag, and continued use of the same transaction
([test](../../crates/drivers/mysql/tests/shared/mysql_atomic.rs)).

SQL Server server-owned columns now have native consumer coverage across grid,
CSV import, Copy as SQL and SQL export. Fetched metadata makes identity,
computed and rowversion columns read-only while a normal text column stays
editable. CSV input maps hostile supplied values for all three server-owned
columns, yet the core plan inserts only the ordinary value. Copy as SQL omits
them too, and an exported SQL file replays into a second native table with new
identity values and server-generated computed and rowversion values; both
tables' rows are checked in
`value_contract_mssql_server_owned_columns_use_native_defaults_across_consumers`.

PostgreSQL enum metadata refresh now also has a unit guard proving built-in
`INT4` is not an enum leaf, alongside the native enum array rename/schema-move
contract. The Docker contract catches enum/array-recursion changes; the unit
guard catches an over-broad classification that would add enum catalog lookups
to ordinary scalar results.

The core Markdown exporter at source SHA-256
`dc0e5b79166eb2f23d75708f9e62ac06189b0b0ea29330a24fdea9511ac34b0d` was
mutation-audited across `render_markdown`, its header/separator/row/value
formatters, cell escaping and the streaming writer. All 14 generated variants
were caught by the existing renderer and writer tests. The HTML exporter at
source SHA-256
`94a7b3ff2660e04862c7d97fc741cd4307f9422a3413a3f8dbc26f439b7f69ad` generated
7 variants across escaping and streaming output; all 7 were caught. Both
unmutated baselines passed, with no missed, unviable or timed-out mutants. These
add focused consumer slices to TEST-2, not a claim that the broader core/package
audit is complete.

A dedicated PostgreSQL session binds enum text and SQL NULL while the target
schema is absent from `search_path` and a same-named shadow enum is the only
visible type. The test checks assignment, `COALESCE`, and `array_append`
inference against the target's native type. It also verifies that the
shadow-only label is refused with SQLSTATE `22P02` and does not change the
target row. The active schema list, native literal, returned type and sibling
row are asserted in
`value_contract_enum_parameter_resolves_without_target_schema_in_session_path`.

## Current evidence and next targets

Merged [PR #384](https://github.com/cozyGarage/BookiE/pull/384) implements
PERF-9: saved hidden non-key columns are removed from SQL browse projections
while primary keys and hidden filter or sort columns remain usable. Projected
rows distinguish unfetched cells from SQL NULL; full-row copy, row JSON and
current-page export refuse incomplete rows, and the inspector labels them “Not
fetched.” Pending edits disable projection. Native SQLite tests assert the
visible projection and the hidden stored value; planner, keyset mapping,
sparse-row, row-search and app regressions passed with the required GitHub
checks. The release-binary PostgreSQL Xvfb scenario
`postgres_hidden_projection_refresh_and_edit_preserve_hidden_value` now covers
hide, refresh, inspector, edit/sibling preservation and unhide; distribution
Wayland/GNOME acceptance remains open under UI-14b. After hiding columns, refresh
the browse page for the reduced SELECT to take effect.

SQL-backed browse rows now keep an 8 KiB text/JSON/binary sample and original
byte count in each materialized grid row. View Value refetches one column using
the complete primary key through the policy-guarded connection; the query caps
at two rows and refuses missing or ambiguous matches. PostgreSQL enum/domain
key casts have planner regressions. Arbitrary SQL editor result grids now use the
same typed 8 KiB preview and byte count. View Value reads the exact full value
from the already-returned guarded result instead of rerunning arbitrary SQL.
The result still retains full values, so this does not reduce shared-result
memory. MongoDB refetches selected fields
by `_id`; Redis string refetch binds arbitrary key bytes. Local SQLite and
Docker MySQL service tests refetch a 9,000-byte BLOB by
composite key and compare its exact returned bytes with native storage oracles;
the MySQL test also checks `LONGBLOB`, byte length and the native hex prefix. A
Docker PostgreSQL 16 test uses catalog enum/domain key metadata, confirms both
native types with `pg_typeof`, and refetches the same-size BLOB through the
typed composite key. The SQLite test also runs the same parameterized refetch
through `PolicyGuard` and compares the exact bytes. MySQL and PostgreSQL also
run the same guarded query; the Docker cases retain native storage and key-type
oracles. SQL Server now covers the guarded refetch with a composite VARBINARY/
BIGINT key and checks the 9,000-byte payload against native `DATALENGTH` and
`fn_varbintohexstr` results (`mssql_value_query_refetches_the_exact_blob_for_a_composite_key`).
DuckDB now has a feature-gated app-service contract that refetches a 9,000-byte
BLOB through `PolicyGuard` using a hostile composite key; native storage class,
length and prefix checks prove the value before refetch. ClickHouse also checks
a guarded 12,000-byte String refetch with native type/length/prefix oracles.
MongoDB browse cells now also preview long text, binary and structured values
and refetch one selected field through a bound `_id` query under `PolicyGuard`.
Its Docker app-service contract binds an ObjectId and checks exact 9,000-byte
text, generic binary and nested BSON document values against native MongoDB
storage. MongoDB browse and paged find requests sort by unique _id before
applying skip/limit, so page boundaries remain deterministic. Redis string
refetch binds arbitrary key bytes and checks an exact
9,000-byte value through `PolicyGuard` against native Redis GET. Arbitrary SQL,
shared result memory, installed GTK and memory profiling remain open under
PERF-10.

The core result budget tests exact byte, cell and row limits; owned text, byte
and recursive JSON memory accounting; retained rows across result sets; and
first-result truncation from either the batch or its first set. A full-file
`cargo-mutants` run on query source SHA-256
`ef3bb83d9461c146fceff51cf0ae4c61dc47daff8bcdc9018f2230249325fb69` tested all
35 generated variants: 33 were caught and 2 constructor replacements were
unviable, with no missed or timed-out mutants. This closes the scoped result
budget mutation audit; broader TEST-2 coverage remains open.

The MySQL ENUM/SET editor parser now has focused regressions for malformed
declarations and MySQL literal escapes. Invalid type prefixes, incomplete
label lists, missing quotes, or trailing metadata must refuse the edit rather
than infer members; NUL and control-character labels plus backslash-percent
and backslash-underscore labels retain their declared text. Docker coverage
checks this against MySQL's reported column type and native enum ordinal/bytes
([test](../../crates/app/tests/support/mysql_enum_set_contract.rs)).
This pins the parser boundary; it does not expand MySQL ENUM/SET support.
The GTK MySQL fixture now also edits an ENUM label and a multi-member SET
through the grid, proves both remain pending until Save, and checks native
ordinals, bytes, SQL NULL, empty and literal `NULL` values, plus untouched
sibling rows ([scenario](../../scripts/test-gtk-mysql.sh)). This local Xvfb
scenario does not replace installed Wayland acceptance.

The MySQL and MariaDB result decoders also have native result-charset contracts
for ENUM and SET values whose Latin-1 bytes are not valid UTF-8. They preserve
those raw bytes while an equally unrepresentable VARCHAR remains
`Undecodable`; these catch removal of the ENUM/SET byte fallback in
`decode_by_type`.

[PR #369](https://github.com/cozyGarage/BookiE/pull/369) extends the PostgreSQL
enum-domain recursion contract to a tested 513-layer point and is merged. This
is a checkpoint, not a maximum-depth claim, and it does not close the broader
B3 matrix.

The local follow-up now extends schema-aware scalar reads, keyed edits, draft
inserts, filters and shadowed-`search_path` checks through 4,096 domain layers
in `value_contract_deep_domain_levels_over_enum_ignore_shadowed_search_path`
([test](../../crates/drivers/postgres/tests/support/domain_contract_parts/deep_domains.rs)).
PR #409 previously extended those paths through 1,025 layers. Raw inferred text
and SQL NULL parameters still refuse at 64 layers. Domain-over-enum array
results decode with their exact native value, wire bytes and type through
1,024 layers, then refuse at 1,025, 2,048 and 4,096 layers. Inferred text and
SQL NULL array parameters to `array_cat` and `array_append` refuse at the tested
deep boundaries. At 64 and deeper, `COALESCE(status, $1)`, both `CASE` result
branches, and `GREATEST`/`LEAST` retain text and SQL NULL values with the enum
leaf type. Raw `NULLIF(status, $1)` retains native SQLSTATE 42883, while
`array_append(ARRAY[status], $1)` refuses at the driver's resolvable-depth
boundary. A scoped mutation run on PostgreSQL parameter inference source
SHA-256 `8626deee182c090ce18aaa4628df3e3d296bc3ca15521e714604cf883bc9feb8`
caught 23 of 24 resolver mutants with the deep-domain contract; one generated
return-value mutant was unviable, with no misses or timeouts.
The expression assertions are in
`../crates/drivers/postgres/tests/support/domain_contract_parts/deep_enum_expression_contract.rs`;
the depth matrix remains in
`../crates/drivers/postgres/tests/support/domain_contract_parts/deep_domains.rs`.

The same sampled 63-to-4,096-layer shadowed-path matrix now distinguishes scalar
array-function parameters: `array_remove(ARRAY[status], $1)` and
`array_prepend($1, ARRAY[status])` preserve the native enum parameter and exact
array value at 63 layers, then refuse at 64 and deeper;
`array_position(ARRAY[status, NULL], $1)` and
`array_positions(ARRAY[status, NULL], $1)` retain the enum parameter type and
PostgreSQL's NULL-element matching semantics through 4,096 layers. Both text
and SQL NULL are checked against the expected result and `pg_typeof`; the Docker contract is
`value_contract_deep_domain_levels_over_enum_ignore_shadowed_search_path`.

ClickHouse Enum8 now covers its signed endpoints and zero (`-128`, `0`, `127`)
in the existing native contract. Parameter insertion, result label decoding,
native Int8 casts, CSV import and SQL-literal replay all preserve the labels;
an undeclared Enum8 label is refused and leaves all stored rows unchanged.
Empty-string labels now remain distinct from SQL NULL across Enum8 and Enum16
parameter writes, reads, CSV import and SQL-literal replay, including nullable
Enum8. Native enum-code and `isNull` checks distinguish the empty label from
NULL.
Enum16 now covers its signed endpoints and zero (`-32768`, `0`, `32767`) with
the same consumers and native Int16 casts; an undeclared Enum16 label is also
refused without changing stored rows. Both widths share the same native test
([test](../../crates/drivers/clickhouse/tests/support/enum_values.rs)). A driver
unit test separately pins Enum16 label text and SQL NULL decoding
([test](../../crates/drivers/clickhouse/src/tests.rs)). Other ClickHouse type and
consumer combinations remain open.

Nullable Enum16 additionally preserves SQL NULL separately from the literal
`NULL` label through parameter writes, native casts, CSV import and SQL-literal
replay, with the native type and null flag as oracles. The same support test
covers this nullable consumer path.

Nested `Array(Enum8)` results preserve escaped, Unicode, literal-`NULL` and
zero-code labels as the exact native `toJSONString` value through JSON, CSV and
XLSX exports. `Array(Nullable(Enum8))` also keeps SQL NULL elements distinct
from the literal `NULL` enum label. The same contract proves type-less SQL
literals, bindings and keyed grid edits refuse both nested values while the
stored row remains unchanged
([test](../../crates/drivers/clickhouse/tests/support/nested_values.rs)).
ClickHouse `Map(String, Enum8)` values now exercise apostrophe and Unicode
labels plus the literal `NULL` label; `Map(String, Nullable(Enum16))` keeps an
empty label, SQL NULL and the literal `NULL` distinct. Both use the same native
JSON/export oracle and explicit refusal/preservation checks for lossy writes
([test](../../crates/drivers/clickhouse/tests/support/nested_values.rs)).
The same contract now covers the two complementary map values,
`Map(String, Enum16)` and `Map(String, Nullable(Enum8))`, completing all four
Enum8/Enum16 nullable/non-nullable pairings. The new cases include signed
Enum16 endpoints, the Enum8 high endpoint, and empty-label versus SQL NULL
versus literal `NULL`; they use the same native JSON, JSON/CSV/XLSX, and
lossy-write refusal/postcondition checks.
Enum8 and Enum16 map keys also retain signed endpoint labels through the native
JSON, JSON/CSV/XLSX consumers; SQL, binding and keyed grid writes retain the
explicit refusal behavior and leave the stored row unchanged in the same test.
`Array(Enum16)` and `Array(Nullable(Enum16))` now cover their signed endpoints,
SQL NULL versus the literal `NULL` label where nullable, the same native JSON
and export oracles, and lossy SQL, binding and grid-write refusal in that
contract. Tuples containing Enum8 and Enum16, with nullable elements and a
literal `NULL` label, use the same native JSON/export oracle and explicit
lossy-consumer refusal checks.
The app grid path also has a native Enum8/Enum16 keyed-edit contract: unquoted
labels remain convenient, quoted empty, literal `NULL` and apostrophe-bearing
labels survive parsing, blank input stores SQL NULL, native Int8/Int16 codes
are checked, and an undeclared label is refused without changing any row
([test](../../crates/app/tests/support/clickhouse_enum_contract.rs)).
The installed GTK suite edits nullable Enum8 and Enum16 cells against native
ClickHouse, proves both values stay pending until Save, and checks native enum
codes plus SQL NULL, literal `NULL`, empty-label and sibling-row preservation
([scenario](../../scripts/test-gtk-clickhouse.sh)). This Xvfb run does not replace
the later distribution-package/Wayland acceptance.

The PostgreSQL GTK fixture now edits a native enum cell through the grid and
checks it remains pending until Save. The database oracle confirms the new
labels after editing both an ordinary label and the literal `NULL` label. The
database oracle keeps SQL NULL, an empty label and a sibling row distinct
([scenario](../../scripts/test-gtk-postgres.sh)). This local Xvfb run does not
replace the later distribution-package/Wayland acceptance.

PostgreSQL `citext` scalar and array values preserve exact label text while
comparisons remain case-insensitive. `citext[]` now round-trips SQL NULL, empty
arrays, zero lower bounds, empty elements, literal `NULL`, quoting and Unicode
through result decoding, typed parameter binding, keyed grid edits and CSV
export/import. Native `array_send`, JSON, type and sibling-row checks are the
oracles; malformed array text and same-named composite types are refused without
data loss ([evidence](../evidence/postgres-citext-array-roundtrip-results-2026-10-06/manifest.json)).
Domain-over-array columns retain their declared PostgreSQL domain metadata in query and table metadata. Optimistic grid edits cast both submitted and previously read values to the qualified domain, so PostgreSQL can perform assignment and stale-row comparison; native tests cover value-to-value and SQL NULL-to-empty edits, type/JSON/wire values, sibling preservation and domain CHECK refusal ([test](../../crates/drivers/postgres/tests/support/domain_array_type_contract.rs)). Custom-enum scalar edits use the same qualified cast for the old-value comparison under restricted roles and shadowed `search_path` ([test](../../crates/drivers/postgres/tests/support/enum_role_context_contract.rs)). Enum-array grid edits cover qualified old/new casts, SQL NULL and empty arrays, invalid labels, native type/wire output and sibling preservation ([test](../../crates/drivers/postgres/tests/support/array_contract_parts/enum_consumers.rs)). Other custom PostgreSQL array families remain open.

PostgreSQL `bit[]` and `varbit[]` now decode from their native array wire
format. Fixed-width values, varying lengths, empty bit strings, SQL NULL,
non-default lower bounds, parameter rebinding and typed CSV restore are checked
against native JSON/type/wire oracles; the built-in OID census includes both
bit element OIDs, while remaining unlisted built-ins still refuse visibly. The
app grid parser and keyed update also
cover zero-based bounds, empty strings, NULL elements, byte equality, sibling
preservation and SQLSTATE `22P02` refusal for malformed bits
([result evidence](../evidence/postgres-bit-arrays-results-2026-10-06/manifest.json),
[grid evidence](../evidence/postgres-bit-array-grid-edit-results-2026-10-06/manifest.json)).
Array dimension products are checked against the remaining element-length words
before decoding; `value_contract_dimension_product_must_fit_element_length_words`
pins the exact two-element payload boundary at 7 versus 8 bytes.

The built-in `name[]` contract covers empty text, SQL NULL, literal `NULL`,
commas, quotes, backslashes, Unicode and a 63-byte UTF-8 name. Pooled decoding
and session typed rebinding preserve exact server wire bytes; the keyed grid
edit casts to `pg_catalog.name[]` and preserves its sibling row; typed CSV
import also covers these distinctions against native wire bytes
(`value_contract_arrays_preserve_elements_dimensions_and_exports` and
`value_contract_array_grid_edit_preserves_array_elements` in
`crates/drivers/postgres/tests/support/array_contract.rs`).

The `oid[]` keyed grid edit preserves zero, `4294967295` and SQL NULL through
the qualified `pg_catalog.oid[]` cast. Native type, text and `array_send` bytes
match, and the sibling row is unchanged (`value_contract_array_grid_edit_preserves_array_elements`
in `crates/drivers/postgres/tests/support/array_contract.rs`).

The built-in PostgreSQL `pg_lsn[]` now preserves full-width LSNs and SQL NULL
through binary result decoding, inferred typed binding, the keyed-update builder
and typed CSV import. Tests compare native type, text, JSON and `array_send`
bytes; malformed LSN elements are rejected before a write and sibling rows stay
unchanged ([evidence](../evidence/postgres-pg-lsn-array-results-2026-10-06/manifest.json)).

The built-in PostgreSQL `macaddr[]` now preserves canonical six-octet text,
SQL NULL and non-default lower bounds across binary result decoding, inferred
typed bindings, keyed updates and typed CSV import. Tests compare native type,
text, JSON and `array_send` bytes; malformed octets are rejected without
changing the target or sibling row. The built-in OID census includes element
OID 829. The built-in `macaddr8[]` now preserves eight-octet EUI-64 text,
SQL NULL and non-default lower bounds across binary result decoding, inferred
typed bindings, keyed updates and typed CSV import. Native type/text/JSON and
`array_send` comparisons cover malformed-input refusal and target/sibling
preservation; the OID census includes element OID 774.

The built-in PostgreSQL `inet[]` and `cidr[]` preserve IPv4/IPv6 addresses,
prefixes, SQL NULL and non-default lower bounds through binary result decoding,
inferred typed bindings, keyed updates and typed CSV import. Native type, text,
JSON and `array_send` comparisons cover full-host and network prefixes,
malformed-prefix refusal, CIDR host-bit refusal and target/sibling preservation.
The built-in OID census includes element OIDs 869 (`inet`) and 650 (`cidr`)
([evidence](../evidence/postgres-network-array-roundtrip-results-2026-10-06/manifest.json)).
The `inet[]` and `cidr[]` XLSX writers preserve the driver's quoted array text
as string cells; Gnumeric and Calc XLSX/ODS/XLSX round trips retained each
exactly, while native PostgreSQL queries separately check stored type, text and
JSON values. Regressions: `value_contract_inet_array_xlsx_preserves_native_network_text`
and `value_contract_cidr_array_xlsx_preserves_native_network_text`.

PostgreSQL arbitrary query results have Docker regressions that cross the shared
64 MiB decoded-result budget, verify retained row order and payloads, assert
server cancellation, and reuse the pooled connection. A byte-capped query in an
explicit transaction also verifies PostgreSQL's aborted state (`25P02`),
rollback, and connection reuse
([tests](../../crates/drivers/postgres/tests/support/query_budget_contract.rs)).
The core unit test separately checks the `MAX_QUERY_ROWS` guard; byte accounting
reaches its limit first for current materialized rows, so an exact one-million
row driver result is not reachable under the present 64 MiB limit.

Other unlisted built-in and custom array families remain explicitly open
([macaddr[] evidence](evidence/postgres-macaddr-array-roundtrip-results-2026-10-06/manifest.json),
[macaddr8[] evidence](evidence/postgres-macaddr8-array-roundtrip-results-2026-10-06/manifest.json)).

PostgreSQL `xml[]` now preserves its native array text and wire bytes through
result decoding, inferred parameter rebinding, typed CSV restore and keyed grid
edits. XML fragments with commas, quoted attributes, Unicode, entities and SQL
NULL are checked against `pg_typeof` and `array_send`; malformed XML retains the
native `2200N` refusal, with the target and sibling rows unchanged
([validation on PR #118](https://github.com/cozyGarage/BookiE/pull/118#issuecomment-6027920545)).
The same XML array now also survives JSON, CSV, XML, HTML, Markdown, XLSX and
SQL file exports with its native array text, NULL element, and wire bytes
preserved on SQL replay (`value_contract_xml_array_file_exports_preserve_native_text`
in `crates/drivers/postgres/tests/support/array_contract_parts/xml_array_file_exports.rs`).

Custom composite arrays now have a named explicit-refusal contract. The test
checks the undecodable value against PostgreSQL's native composite type, JSON,
text and wire output, then verifies literal/bind refusal leaves target and
sibling rows unchanged (`value_contract_custom_composite_array_refusal_preserves_rows`
in `crates/drivers/postgres/tests/support/custom_array_contract.rs`). Other
custom array families and their consumers remain open. The unlisted built-in
`money[]` refusal covers populated values, SQL NULL
elements, native text/JSON/wire snapshots, literal/bind refusal and
target/sibling preservation (`value_contract_money_array_refusal_preserves_target_and_sibling_rows`).
The same explicit-refusal contract now covers `point[]` with native type, text,
JSON and wire oracles plus target/sibling preservation
(`value_contract_point_array_refusal_preserves_target_and_sibling_rows`). Both
tests are in `crates/drivers/postgres/tests/support/custom_array_contract.rs`;
all six built-in range arrays now receive the same explicit refusal, native
JSON, exact type and post-refusal row/wire preservation checks in
`crates/drivers/postgres/tests/support/range_array_contract.rs`.
User-defined range arrays now have a separate explicit-refusal case: a
schema-qualified integer range array preserves its native type, range text,
JSON and wire snapshot; BookiE's JSON and CSV exports emit the visible
undecodable-type marker, as do Markdown, HTML, XML and XLSX exports. SQL export
refuses the value without replacing an existing destination. Empty arrays
remain visibly undecodable while a whole-array SQL NULL remains `Value::Null`.
SQL-literal, query-parameter and update bindings refuse the value without
changing the target or sibling rows
(`value_contract_custom_range_array_refusal_preserves_target_and_sibling_rows`
in `crates/drivers/postgres/tests/support/range_array_contract.rs`). This is a
refusal contract; other user-defined array families remain open.
Custom range scalars have a separate refusal contract: native type, text, JSON
and `range_send` bytes identify the original value, while empty ranges remain
distinct from SQL NULL. Literal rendering, query binding and keyed update
binding refuse the value without changing target or sibling rows
(`value_contract_custom_range_scalar_refusal_preserves_target_and_sibling_rows`
in `crates/drivers/postgres/tests/support/range_array_contract.rs`). This
documents a safe refusal boundary, not custom range support.
The six built-in scalar range types now follow the same visible refusal policy:
native text, JSON and wire values are checked, empty ranges stay distinct from
SQL NULL, and refused literals/bindings leave target and sibling rows unchanged
([test](../../crates/drivers/postgres/tests/support/range_scalar_contract.rs)).
PostgreSQL built-in multirange scalars and arrays resolve through SQLx's type
metadata and reach BookiE's value decoder. BookiE returns a named
`Value::Undecodable` for non-NULL values; SQL literal rendering and parameter
binding refuse them, while SQL NULL remains `Value::Null`. Docker-backed scalar
tests compare native type, text, range hull and component count; the built-in
array OID census compares native type, text and JSON and verifies explicit
consumer refusal. This is a safe refusal contract, not multirange support.
The built-in `tsvector[]` and `tsquery[]` now have separate explicit-refusal
assertions with native text-search JSON and wire oracles; refused literals and
bindings leave target and sibling rows unchanged
([test](../../crates/drivers/postgres/tests/support/unsupported_builtin_array_contract.rs)).
The same explicit-refusal and preservation contract now covers built-in
`json[]` and `jsonb[]`, with native array text, JSON, and wire snapshots in the
same test file. Empty arrays remain visibly undecodable with their native type,
while whole-array SQL NULL remains `Value::Null` for both types
(`value_contract_empty_json_arrays_refuse_but_sql_null_stays_null`).
PostgreSQL geometric arrays `point[]`, `line[]`, `lseg[]`, `box[]`, `path[]`,
`polygon[]`, and `circle[]` now share an explicit-refusal contract. It checks
native type/text/JSON/wire oracles, SQL-literal and parameter refusal, and
unchanged target and sibling rows (`value_contract_geometric_array_refusals_preserve_target_and_sibling_rows`).

Detailed native cases and old counts are in [type-contract history](type-contract-history.md)
and [the value evidence index](../value-contracts.md). Those records keep their
source/SHA attribution; this summary does not certify the current tree.

The shared UUID contract now checks bound and SQL-literal round trips on
PostgreSQL, SQL Server, ClickHouse and DuckDB, with UUID-shaped text and SQL NULL
as controls. DuckDB now decodes UUID by its logical column type and preserves
the value as `Value::Uuid`. A DuckDB mixed multi-column, multi-row regression
checks UUID, UUID-shaped text and typed NULL alongside logical result metadata;
a separate zero-row projection retains UUID metadata too ([scalar evidence](../evidence/value-uuid-multidriver-results-2026-10-05/manifest.json),
[mixed projection evidence](../evidence/duckdb-uuid-mixed-projection-results-2026-10-06/manifest.json)).

The PostgreSQL `timestamp[]` DateStyle case now extends typed rebinding to
canonical JSON/CSV output and SQL replay after switching from `SQL, DMY` to
`ISO, MDY`; typed CSV import now restores the same source after that session
change, with native type/JSON/wire checks and an untouched sibling
([test](../../crates/drivers/postgres/tests/support/array_contract_parts/result_consumers_timestamp_dmy.rs)).
The `date[]` SQL/DMY CSV import path also restores BC dates, infinity and SQL
NULL after switching to ISO/MDY, with native type/JSON/wire checks and an
untouched sibling
([test](../../crates/drivers/postgres/tests/support/date_array_csv_import.rs)).
The `timetz[]` case also preserves explicit offsets through an `America/New_York`
to UTC transition and the JSON/CSV/XLSX/SQL consumer paths. CSV import under
the changed UTC session preserves native type, JSON and wire bytes, with an
untouched sibling row
([test](../../crates/drivers/postgres/tests/support/array_contract_parts/result_consumers_text.rs)).
`timestamptz[]` also rebinds across an `America/Los_Angeles` to UTC session
change, including the repeated DST-overlap wall-clock time with distinct `-04`
and `-05` offsets. CSV import under UTC preserves native type, JSON, wire bytes
and an untouched sibling row. The test compares native type, JSON and wire
output after rebinding, and confirms the wire bytes match the original session
(`value_contract_timestamptz_array_rebinding_preserves_instants_after_timezone_change`).
The `interval[]` CSV import contract now also changes `IntervalStyle` from
`postgres_verbose` to `iso_8601`; the imported row retains native type and exact
`array_send` bytes, while a pre-existing sibling remains unchanged
([test](../../crates/drivers/postgres/tests/support/interval_array_csv_import.rs)).
Other temporal-array session/consumer combinations remain open.

PostgreSQL inferred enum-array binding now has direct evidence for the
domain-over-enum `ANY($1)` predicate, including native type and wire-byte
oracles. Follow-up contracts cover containment and overlap operators with the
parameter on either side, including a same-named shadow enum earlier in
`search_path`; the bound OID and bytes continue to match the qualified target
type. A separate case now covers inferred scalar parameters to
`array_remove(ARRAY[status::base_enum], $1)` for text and SQL NULL; native typed
queries provide the result oracle while `pg_typeof` checks the parameter and
result types ([evidence](../evidence/postgres-domain-enum-array-remove-results-2026-10-04/manifest.json)).
`array_position` is covered for the same inputs, including PostgreSQL's
`IS NOT DISTINCT FROM` behavior where SQL NULL matches a NULL array element
([evidence](../evidence/postgres-domain-enum-array-position-results-2026-10-04/manifest.json)).
`array_replace` now covers two inferred scalar parameter slots together,
including NULL search/replacement values and both parameter types
([evidence](../evidence/postgres-domain-enum-array-replace-results-2026-10-04/manifest.json)).
The same two-slot context now also has a shadowed-`search_path` contract: both
parameters retain the qualified target enum type, native array bytes match,
and shadow-only labels fail in either slot ([evidence](../evidence/postgres-domain-enum-array-replace-shadowed-results-2026-10-05/manifest.json)).
The first array argument is now covered too: `array_position($1, enum_value)`,
`array_remove($1, enum_value)`, `array_append($1, enum_value)` and
`array_prepend(enum_value, $1)` infer the target enum array under that path,
including lower bounds, empty/NULL arrays, NULL elements and shadow-only label
refusal ([evidence](../evidence/postgres-domain-enum-array-input-functions-shadowed-results-2026-10-05/manifest.json)).
`array_cat` now covers inferred text and SQL NULL array parameters for a
domain-over-enum source under a same-named shadow enum in `search_path`
([evidence](../evidence/postgres-domain-enum-array-cat-results-2026-10-04/manifest.json)).
`array_positions` now checks inferred scalar enum parameters, repeated matches and
NULL-element matching under the same shadowed path
([evidence](../evidence/postgres-domain-enum-array-positions-results-2026-10-04/manifest.json)).
All six PostgreSQL array comparison operators now cover inferred domain-over-enum
array parameters, NULL arrays, NULL elements, empty arrays and lower-bound-sensitive
comparisons against native results and wire bytes while a same-named shadow enum
leads transaction `search_path` ([evidence](../evidence/postgres-domain-enum-array-equality-results-2026-10-04/manifest.json)).
The `array_append` and `array_prepend` function contexts now also preserve the
target enum type under a same-named shadow enum, verified with typed native
results, `pg_typeof`, result wire bytes, text labels including literal `NULL`,
SQL NULL and native invalid-label SQLSTATE ([evidence](../evidence/postgres-domain-enum-array-functions-shadowed-results-2026-10-04/manifest.json)).
The PostgreSQL 16 `trim_array` boundary is now explicit: a standalone
`trim_array($1, n)` cannot infer an unknown polymorphic array parameter
(`42804`), while a schema-qualified array cast preserves NULL, empty, NULL
element and lower-bound inputs against native result and wire oracles under a
shadowed `search_path` ([evidence](../evidence/postgres-trim-array-enum-inference-boundary-results-2026-10-05/manifest.json)).
`unnest($1)` is now an explicit PostgreSQL boundary: without a typed argument,
server function resolution returns SQLSTATE `42725`; a schema-qualified enum
array cast works under a same-named shadowed `search_path`, with native value,
type and wire-byte comparisons for NULL, empty, multidimensional, lower-bound,
NULL-element and escaped-label cases ([unnest evidence](../evidence/postgres-enum-array-unnest-inference-results-2026-10-05/manifest.json)).
`generate_subscripts($1, dimension, reverse)` is a separate polymorphic boundary:
an untyped enum array returns SQLSTATE `42804` (unlike `unnest`'s `42725`). A
qualified cast under the same-named shadow path matches native subscripts for
both dimensions, reverse ordering, non-default lower bounds, empty arrays and
SQL NULL, with array type and wire-byte checks
([evidence](../evidence/postgres-enum-array-generate-subscripts-results-2026-10-05/manifest.json)).
The enum-array shape family is also checked with a same-named shadow type:
`array_dims`, `array_ndims`, `array_length`, `array_lower`, `array_upper`, and
`cardinality` match typed native literals and `array_send` bytes for multidimensional
non-default bounds, empty labels/arrays, and SQL NULL. Untyped shape calls return
`42804`; empty-array length is NULL while cardinality is zero
([evidence](../evidence/postgres-enum-array-shape-functions-results-2026-10-05/manifest.json)).
The driver also round-trips three-dimensional custom enum arrays with non-default
bounds, SQL NULL, empty and escaped labels, plus a six-dimensional array at
PostgreSQL's supported limit. Dimensions, JSON values, type metadata and wire
bytes match native results.
Custom enum-array slicing now has a native consumer contract: slicing a
non-1-based multidimensional array resets the result bounds to `[1:2][1:2]`,
while preserving empty text, literal `NULL`, SQL NULL, Unicode and exact wire
bytes through typed rebinding. SQL NULL and an empty array remain distinct
([test](../../crates/drivers/postgres/tests/support/array_contract_parts/enum_array_slices.rs)).
Quoted enum schema/type identifiers containing embedded quotes also retain the
target type under a same-named shadowed `search_path`; keyed writes and filters
match native qualified/unqualified type names, preserve both target and shadow
rows, and reject a shadow-only label ([identifier evidence](../evidence/postgres-enum-quoted-shadow-path-results-2026-10-05/manifest.json)).
`array_to_string` now has explicit output contracts for empty labels, literal
`NULL`, SQL NULL elements with and without a replacement marker, empty arrays,
SQL NULL arrays, lower bounds, multidimensional arrays, and shadowed enum names.
Untyped calls return SQLSTATE `42804`; qualified casts match native string,
type, and wire-byte oracles ([evidence](../evidence/postgres-enum-array-to-string-results-2026-10-05/manifest.json)).
`array_fill` now checks polymorphic type inference and qualified enum casts
under a same-named shadow path. Empty and `NULL` labels, SQL NULL fill values,
zero-sized and multidimensional arrays, non-default bounds, JSON, native type,
and `array_send` agree with native calls ([evidence](../evidence/postgres-enum-array-fill-results-2026-10-05/manifest.json)).
Multi-array `unnest` now covers a schema-qualified enum array beside an integer
array under a same-named shadow path. The native oracle checks storage order,
multidimensional flattening, shorter/NULL/empty-array NULL padding, ordinality,
per-column types and shadow-only label refusal. Untyped calls return SQLSTATE
`42725` ([evidence](../evidence/postgres-enum-multi-array-unnest-results-2026-10-05/manifest.json)).
The named random-result enum-array functions `array_sample` and
`array_shuffle` are now covered with multiset and result-shape oracles rather
than fixed random output. Repeated samples enforce count-bounded subset
membership; shuffles preserve the full multiset; multidimensional operations
select or reorder whole first-dimension slices. Empty/NULL inputs, sample-size
boundaries and shadowed enum resolution are checked
([evidence](../evidence/postgres-enum-random-arrays-results-2026-10-05/manifest.json)).
An ordered `array_agg` result also checks custom enum-array result metadata,
ordered labels, literal `NULL` versus SQL NULL, empty/Unicode/quoted labels,
JSON semantics and native wire-byte equality after rebinding. No input rows
return SQL NULL with enum[] metadata, separate from an array with a SQL NULL
element
([evidence](../evidence/postgres-enum-array-agg-results-2026-10-05/manifest.json)).
A companion case now combines `array_agg(DISTINCT ... ORDER BY ...)` with a
selective `FILTER`; duplicate enum labels collapse in declared enum order,
filtered-out labels stay absent, and duplicate SQL NULL inputs produce one NULL
element, with native JSON/type/wire checks after rebinding
([evidence](../evidence/postgres-enum-array-agg-distinct-filter-results-2026-10-05/manifest.json)).
Enum parameters in both branches of `UNION ALL` and both row positions of
`VALUES` now match native enum literals for ordinary, empty, literal `NULL`,
and SQL NULL labels. The contract compares `pg_typeof`, `enum_send` bytes and
native invalid-label SQLSTATE `22P02`. A warmed transaction also changes to a
same-named shadow enum first in `search_path`, reuses the prepared queries, and
confirms target-column inference plus shadow-only label refusal
([evidence](../evidence/postgres-enum-union-values-inference-results-2026-10-05/manifest.json)).
The same aggregate also has a same-named enum in a leading shadow schema; native
type OID and wire checks confirm the qualified table's enum array survives
rebinding, and a shadow-only label is refused
([shadow-path evidence](../evidence/postgres-enum-array-agg-shadowed-path-results-2026-10-05/manifest.json)).
`enum_range(NULL::qualified_enum)` now has a separate result contract under a
same-named leading shadow type: metadata stays qualified to the target schema,
enum order and empty/Unicode labels match native JSON and wire-byte oracles,
and rebinding refuses a shadow-only label
([evidence](../evidence/postgres-enum-range-shadowed-path-results-2026-10-05/manifest.json)).
The bounded two-argument form now checks inclusive bounds, NULL endpoints,
reversed bounds, and a literal `NULL` label under the same shadow-path
collision, with native type, JSON, dimensions, wire bytes and typed-rebind
checks ([evidence](../evidence/postgres-enum-range-bounds-shadowed-results-2026-10-05/manifest.json)).
`enum_first` and `enum_last` now have scalar-result contracts under the same
shadow-path collision, with qualified metadata, native `enum_send` byte checks,
typed rebinding and SQLSTATE `22P02` for shadow-only labels
([evidence](../evidence/postgres-enum-first-last-shadowed-path-results-2026-10-05/manifest.json)).
Scalar enum `min`/`max` aggregates now preserve declared enum order, qualified
metadata and wire identity under the same shadow-path collision, including
all-NULL and no-row aggregate results
([evidence](../evidence/postgres-enum-min-max-shadowed-path-results-2026-10-05/manifest.json)).
The existing session's `enum_range` result also follows `ALTER TYPE ADD VALUE`
with no position clause and the explicit `BEFORE` and `AFTER` forms, preserving
the append and inserted-label order plus qualified type after native catalog
and wire-byte checks
([default/position evidence](../evidence/postgres-enum-add-value-default-append-results-2026-10-05/manifest.json),
[before/after evidence](../evidence/postgres-enum-add-value-positions-results-2026-10-05/manifest.json),
[original BEFORE evidence](../evidence/postgres-enum-add-value-session-results-2026-10-05/manifest.json)).
The warmed range query also observes `ALTER TYPE RENAME VALUE` in that session,
with catalog-order and native array-byte checks after rebinding
([rename evidence](../evidence/postgres-enum-rename-value-session-results-2026-10-05/manifest.json)).
Separate reader and writer sessions now verify that a warmed range query sees
`ADD VALUE BEFORE`, `RENAME VALUE`, `ADD VALUE AFTER` and default append, with
catalog, JSON and wire-byte oracles under the shadowed path
([latest append evidence](../evidence/postgres-enum-add-value-default-append-results-2026-10-05/manifest.json),
[cross-session position evidence](../evidence/postgres-enum-cross-session-add-after-results-2026-10-05/manifest.json),
[original evidence](../evidence/postgres-enum-cross-session-catalog-results-2026-10-05/manifest.json)).
Result metadata now also follows same-session enum type renames and schema
moves by catalog OID, including a zero-row projection under a shadowed
`search_path` ([migration evidence](../evidence/postgres-enum-type-rename-schema-move-results-2026-10-05/manifest.json)).
Separate reader/writer coverage now verifies the same type rename and schema
move after a warmed table projection; the populated/SQL NULL rows, zero-row
metadata, catalog order, `enum_send` and typed rebinding all match PostgreSQL
under a same-named shadow path
([cross-session evidence](../evidence/postgres-enum-cross-session-type-move-results-2026-10-05/manifest.json)).
Drop/recreate of a same-named enum now has a warm-cache regression across a
shadowed `search_path`. It exposed `XX000: cache lookup failed for type` on
pooled query, controlled session query and execute paths; non-transactional
paths now clear SQLx's cached statements and retry that specific pre-execution
error once. Replacement type/array OIDs, qualified metadata, new labels and
native array wire bytes match PostgreSQL
([evidence](../evidence/postgres-enum-type-recreate-cache-results-2026-10-06/manifest.json)).
These focused function cases do not close the broader PostgreSQL or B3 matrix.
See the [ANY evidence](../evidence/postgres-domain-enum-any-array-parameter-results-2026-10-04/manifest.json),
[operator evidence](../evidence/postgres-domain-enum-array-operators-results-2026-10-04/manifest.json),
and [shadowed-path evidence](../evidence/postgres-shadowed-enum-array-operator-results-2026-10-04/manifest.json).

The enum-array text parameter codec now has direct grammar tests for quoted and
escaped labels, empty text, SQL NULL, non-default lower bounds, nested arrays,
ragged shapes, inconsistent bounds and malformed tails. Native `ANY($1)` and
`ALL($1)` quantifier contracts pass with server type and wire-byte comparisons;
a same-named shadow type in `search_path` is also refused when its label is
bound ([codec evidence](../evidence/postgres-enum-array-codec-boundaries-results-2026-10-05/manifest.json),
[shadowed-path evidence](../evidence/postgres-enum-array-quantifier-shadowed-path-results-2026-10-05/manifest.json)).

An inferred enum-array parameter with domain elements is covered through 63
domain layers and explicitly refused at 64 for both text and SQL NULL. The
array type's own hierarchy is included in this boundary; see the [depth evidence](../evidence/postgres-inferred-enum-array-depth-results-2026-10-04/manifest.json).
At 63 layers PostgreSQL itself rejects scalar equality with `ANY(domain_array)`
as `42883`; the test keeps that native limitation distinct from containment
binding coverage.

MariaDB 11's `EMPTY_STRING_IS_NULL` mode converts empty-string parameters to
SQL NULL. MySQL/MariaDB CSV plans now reconstruct empty ENUM labels, empty SET
values, and empty CHAR/VARCHAR/TEXT destinations with `SPACE(0)`, keeping them
distinct from marker-bound SQL NULL; native mode contracts check ordinals,
masks, text bytes, NULL state, and a sibling row
([standalone mode](../evidence/mariadb-empty-enum-set-empty-string-is-null-results-2026-10-05/manifest.json)).
The same round trip also passes with `STRICT_TRANS_TABLES`, `ANSI_QUOTES`, and
`NO_BACKSLASH_ESCAPES` enabled alongside that mode, including native verification
that the pre-existing sibling is unchanged
([combined-mode evidence](../evidence/mariadb-empty-enum-set-combined-mode-results-2026-10-05/manifest.json)).

The MariaDB grid-edit contract now also covers both modes with parser input for
SQL NULL and explicit empty ENUM/SET values. Before the keyed-update fix, the
empty values became SQL NULL; the builder now uses `SPACE(0)` for empty MySQL
ENUM/SET edits while ordinary text remains parameter-bound. Native MySQL and
MariaDB checks pass across the existing mode matrix
([evidence](../evidence/mariadb-empty-enum-set-grid-empty-string-mode-results-2026-10-05/manifest.json)).
SQL-file replay had the same mode-sensitive loss for empty ENUM and SET
values. The shared MySQL literal writer now emits `SPACE(0)` for empty text; a
core builder test also pins that expression for ordinary text columns. Native
SQL-file and typed CSV restore contracts compare ordinals, masks, exact bytes,
NULL state, and sibling rows separately under the standalone and combined MariaDB modes
([evidence](../evidence/mariadb-empty-enum-set-sql-file-empty-string-mode-results-2026-10-05/manifest.json)).
The typed CSV contract also verifies empty VARCHAR through import and SQL-file
replay under both MariaDB mode combinations, against native bytes and NULL state
([evidence](../evidence/mariadb-empty-varchar-import-empty-string-mode-results-2026-10-05/manifest.json)).

MySQL identity copying now has two native consumer contracts: replaying a
SQL-file export and Copy-as-INSERT both retain explicit auto-increment IDs and
advance the next generated value (`mysql_sql_copy_export_preserves_auto_increment_ids_and_next_value`
and `mysql_copy_as_insert_preserves_auto_increment_id_and_next_value` in
`crates/drivers/mysql/tests/support/mysql_identity_copy_contract.rs`).

The non-UTC TIMESTAMP contract now runs on both MySQL and MariaDB. It proves
dedicated-session refusal, pooled UTC reads, transaction-local refusal,
session-local text and the native UTC epoch
(`session_non_utc_time_zone_refuses_mysql_timestamp_instant` and
`mariadb_session_non_utc_time_zone_refuses_timestamp_instant` in
`crates/drivers/mysql/tests/support/timezone_contract.rs`).

MySQL and MariaDB unsigned subtraction now have session-pinned contracts for
`NO_UNSIGNED_SUBTRACTION`: default unsigned underflow and signed overflow retain
native SQLSTATE `22003`, while the mode returns -1, 41 and `i64::MAX`. Native
expression metadata is retained per engine (MySQL reports `BIGINT`; MariaDB
reports `INT` for the low-magnitude expressions and `BIGINT` at `i64::MAX`)
(`mysql_unsigned_subtraction_obeys_session_mode_and_signed_boundaries` and
`mariadb_unsigned_subtraction_obeys_session_mode_and_signed_boundaries` in
`crates/drivers/mysql/tests/support/unsigned_subtraction.rs`).

| Owner / engine | Retain established contracts | Remaining scope to select one case from |
| --- | --- | --- |
| PostgreSQL | Wide NUMERIC exact text; scalar/array/temporal/interval cases; extended DATE/TIMESTAMP/TIMESTAMPTZ exact-text support, including year 1,000,000 DATE and upper finite bounds through result, literal, parameter, CSV and keyed-edit paths; ordinary custom-enum labels and SQL NULL have direct scalar/array results plus schema-aware keyed-edit, draft-insert, all-operator structured-filter and CSV-import coverage; keyed edits select the correct native enum when the same type name exists in two schemas and the active search_path points at the shadow type; the literal label `NULL` survives keyed writes, direct scalar/array projections, filters and CSV import distinctly from SQL NULL; PostgreSQL 16 scalar/array projections, all shared structured filters, JSON and replayed SQL files confirm domain-over-enum values retain labels, SQL NULL and native type; catalog enum metadata also supports domain-column keyed updates and draft inserts; explicitly cast text/SQL NULL parameters, assignment-inferred text/SQL NULL updates, and base-enum comparison query parameters preserve domain-over-enum values and native type; three- through ten-level plus 63-, 64-, 65-, 128-, 129-, 256-, 257-, 258-, 259-, 260-, 300-, 301-, 302-, 512- and 513-level chains cover enum-leaf metadata and selected inferred parameters, writes and filters; raw inferred text and SQL NULL are refused from 64 levels while COALESCE, CASE and GREATEST/LEAST text/NULL result parameters retain enum inference; NULLIF retains SQLSTATE 42883 and array_append refuses; schema-aware metadata, scalar, edit, insert, filter and array-result operations pass through 4,096 levels under shadowed search_path; domain-over-enum arrays decode through 1,024 layers, then refuse at 1,025, 2,048 and 4,096 with native value, wire-byte and type oracles; a 64-level enum-domain assignment matrix for bool, integer, float, byte, decimal, DATE/TIME/TIMESTAMP, UUID, and JSON parameters is refused with each native SQLSTATE and leaves the seeded enum value unchanged (`value_contract_deep_enum_domain_refuses_incompatible_typed_assignments`); ([301-layer evidence](../evidence/postgres-domain-301-level-results-2026-10-06/manifest.json), [300-layer evidence](../evidence/postgres-domain-300-level-results-2026-10-05/manifest.json), [260-layer evidence](../evidence/postgres-domain-260-level-results-2026-10-05/manifest.json), [259-layer evidence](../evidence/postgres-domain-259-level-results-2026-10-04/manifest.json), [258-layer evidence](../evidence/postgres-domain-258-level-results-2026-10-04/manifest.json), [257-layer evidence](../evidence/postgres-domain-257-level-results-2026-10-04/manifest.json), [deep-domain follow-up](../evidence/postgres-deep-domain-followup-results-2026-10-04/manifest.json)); raw PostgreSQL CSV export/import preserves domain-over-enum labels, empty text and SQL NULL with an explicit marker, while ambiguous default blanks are refused before writes; domain values also have native MCP `execute_query`, JSON/CSV `export_data` and CSV import proof; shared JSON rendering, core file-writer JSON/CSV/XML/HTML/Markdown and XLSX (non-empty enum strings remain text; empty enum labels are refused safely), SQL-file export replay, and MCP enum exports preserve the tested values; selected raw text/SQL NULL scalar query, update and transaction parameters adopt server-inferred enum types in covered contexts; inferred enum-array parameters also work for `ANY($1)`, containment, overlap, append/prepend, `array_remove`, `array_position`, `array_positions`, all six array comparison operators, and two-parameter `array_replace` ([ANY evidence](../evidence/postgres-domain-enum-any-array-parameter-results-2026-10-04/manifest.json), [array-function evidence](../evidence/postgres-domain-array-functions-results-2026-10-04/manifest.json), [array-remove evidence](../evidence/postgres-domain-enum-array-remove-results-2026-10-04/manifest.json), [array-position evidence](../evidence/postgres-domain-enum-array-position-results-2026-10-04/manifest.json), [array-replace evidence](../evidence/postgres-domain-enum-array-replace-results-2026-10-04/manifest.json), [array-cat evidence](../evidence/postgres-domain-enum-array-cat-results-2026-10-04/manifest.json), [array_positions evidence](../evidence/postgres-domain-enum-array-positions-results-2026-10-04/manifest.json), [array equality evidence](../evidence/postgres-domain-enum-array-equality-results-2026-10-04/manifest.json)); a same-named domain-over-enum collision preserves target metadata across 11 direct query-operator forms under shadowed transaction search paths | A raw domain-to-unknown comparison is explicitly refused by PostgreSQL with SQLSTATE 42883; casting the column to its base enum allows inferred text/NULL query parameters. Other session/search_path combinations, domain depths beyond the result-tested 4,096 levels, other parameter inference contexts at or beyond 64 levels, and other custom/native cases need proof |
| MySQL/MariaDB | Signed/unsigned bounds, `NO_UNSIGNED_SUBTRACTION` session behavior ([test](../../crates/drivers/mysql/tests/support/unsigned_subtraction.rs)), and `PAD_CHAR_TO_FULL_LENGTH` CHAR padding with unchanged VARCHAR, empty-value and NULL checks ([test](../../crates/drivers/mysql/tests/support/char_padding_mode.rs)); wide DECIMAL text, zero/extended temporals, BIT/spatial refusal, strict zero-date refusals, TIME/DATETIME/TIMESTAMP fractional mode behavior at FSP 0 through 6, exact-half boundaries for all three types at FSP 3, enum/set SQL-file, typed CSV, JSON, XML, HTML, Markdown and non-empty XLSX consumers across the established twelve-mode matrix; workbook tests compare native ENUM/SET labels with shared strings and distinguish SQL NULL's blank cells from the literal `NULL` label. XLSX still refuses empty SET text without replacing an existing file. MySQL and MariaDB binary-collation ENUM/SET results retain text under utf8mb4_bin while true BINARY and binary-charset values remain bytes ([ENUM evidence](../evidence/mysql-binary-enum-collation-results-2026-10-05/manifest.json), [SET evidence](../evidence/mysql-binary-set-collation-results-2026-10-05/manifest.json)); Latin-1 ENUM/SET collation preserves canonical text and native storage bytes ([evidence](../evidence/mysql-latin1-enum-set-collation-results-2026-10-05/manifest.json)); MariaDB SQL-file and typed CSV empty ENUM/SET values also survive `EMPTY_STRING_IS_NULL` alone and with strict, ANSI, and backslash modes, with native ordinal/mask, byte, and NULL-state oracles; MySQL and MariaDB app grid edits refuse undeclared ENUM/SET values and preserve valid apostrophe/backslash labels and SET masks across all twelve modes, including strict modes alone and combined with ANSI_QUOTES and NO_BACKSLASH_ESCAPES, with literal `NULL` enum labels distinct from SQL NULL; MySQL and MariaDB distinguish explicit `''` empty ENUM/SET values from blank SQL NULL/required-field behavior ([grid evidence](../evidence/mysql-enum-set-grid-edit-results-2026-10-04/manifest.json)); locally completed zero-row metadata/bounded query regressions, and an app parser-to-keyed-grid edit for all three temporal types plus MySQL CSV/JSON export and CSV import round-trip coverage with UTC TIMESTAMP instant and sibling-row checks ([strict-date evidence](../evidence/mysql-strict-zero-date-results-2026-10-04/manifest.json), [enum/set SQL-mode evidence](../evidence/mysql-enum-sql-mode-results-2026-10-04/manifest.json), [TIME mode evidence](../evidence/mysql-fractional-time-mode-results-2026-10-04/manifest.json), [TIME exact-half evidence](../evidence/mysql-fractional-time-tie-results-2026-10-04/manifest.json), [DATETIME/TIMESTAMP exact-half evidence](../evidence/mysql-fractional-half-boundary-matrix-results-2026-10-04/manifest.json), [TIME precision matrix](../evidence/mysql-time-precision-matrix-results-2026-10-04/manifest.json), [DATETIME/TIMESTAMP precision matrix](../evidence/mysql-datetime-timestamp-precision-matrix-results-2026-10-04/manifest.json), [app temporal grid edit](../evidence/mysql-temporal-grid-edit-results-2026-10-04/manifest.json), [fractional DATETIME evidence](../evidence/mysql-fractional-datetime-mode-results-2026-10-04/manifest.json), [fractional TIMESTAMP evidence](../evidence/mysql-fractional-timestamp-mode-results-2026-10-04/manifest.json), [native regressions](../evidence/mysql-atomic-results-2026-10-03/manifest.json)) | Other SQL mode/session configurations beyond the enum/SET matrix, `NO_UNSIGNED_SUBTRACTION` and `PAD_CHAR_TO_FULL_LENGTH`, additional file formats and installed typed edits; retain UTC pool versus dedicated-session distinctions |
| SQLite | Dynamic storage classes, exact bytes/NULL, typed affinity consumer cases, REAL float boundary refusal/preservation, and STRICT `ANY` edits that retain existing INTEGER/REAL/TEXT classes; clearing an existing TEXT cell stores empty TEXT, empty NULL/new cells stay NULL, nonempty NULL/new input stays TEXT, and BLOB runtime values are read-only with exact bytes preserved. SQLite INTEGER/REAL/NUMERIC grid edits retain nonnumeric TEXT and exactly representable numeric decimals, but reject overflow, underflow and excess precision before affinity can lose value; native grid and CSV writes verify storage classes and sibling preservation, and a CHECK-constrained nonnumeric edit is refused without mutation ([grid evidence](../evidence/sqlite-numeric-affinity-grid-results-2026-10-06/manifest.json), [constraint evidence](../evidence/sqlite-affinity-check-constraint-results-2026-10-06/manifest.json)). Direct table-column query results recover declared `ANY` metadata for query, bound-query and transaction consumers, including empty results; mixed `CASE`, `COALESCE`, `iif()`, compound `UNION`/CTE/derived, `NULLIF`, `MIN`, `MAX`, `group_concat()`, `SUM`, `TOTAL`, `AVG`, `json_group_array()`, `json_group_object()`, arithmetic, `json_extract()`, `json_quote()`, `substr()`, `abs()`, `printf()`, `quote()`, `instr()`, `length()`, `round()` and `CAST(... AS BLOB)` results keep fallback metadata and exact per-row storage classes ([CASE evidence](../evidence/sqlite-computed-any-results-2026-10-04/manifest.json), [COALESCE evidence](../evidence/sqlite-coalesce-any-results-2026-10-04/manifest.json), [compound-result evidence](../evidence/sqlite-union-any-results-2026-10-04/manifest.json), [NULLIF evidence](../evidence/sqlite-nullif-any-results-2026-10-04/manifest.json), [MIN evidence](../evidence/sqlite-min-any-results-2026-10-04/manifest.json), [GROUP_CONCAT evidence](../evidence/sqlite-group-concat-any-results-2026-10-04/manifest.json), [MAX evidence](../evidence/sqlite-max-any-results-2026-10-04/manifest.json), [SUM evidence](../evidence/sqlite-sum-any-results-2026-10-04/manifest.json), [TOTAL evidence](../evidence/sqlite-total-any-results-2026-10-04/manifest.json), [AVG evidence](../evidence/sqlite-avg-any-results-2026-10-04/manifest.json), [arithmetic evidence](../evidence/sqlite-arithmetic-any-results-2026-10-04/manifest.json), [json_extract evidence](../evidence/sqlite-json-extract-any-results-2026-10-04/manifest.json), [CAST-to-BLOB evidence](../evidence/sqlite-cast-blob-any-csv-results-2026-10-04/manifest.json), [abs evidence](../evidence/sqlite-abs-any-csv-results-2026-10-06/manifest.json), [round evidence](../evidence/sqlite-round-any-csv-results-2026-10-06/manifest.json), [quote evidence](../evidence/sqlite-quote-any-csv-results-2026-10-06/manifest.json), [instr evidence](../evidence/sqlite-instr-any-csv-results-2026-10-06/manifest.json), [length evidence](../evidence/sqlite-length-any-csv-results-2026-10-06/manifest.json)); `printf('%s', value)` text results also round-trip numeric values, literal `NULL`, formula-shaped and empty text, and SQLite SQL NULL's empty-text result through typed CSV ([run evidence](../evidence/local-gtk-duckdb-value-tier-results-2026-10-06-cfc99dd1/manifest.json)); compound-result and `json_extract()` JSON/XLSX cell kinds, plus compound-result CSV text ([export evidence](../evidence/sqlite-union-any-export-results-2026-10-04/manifest.json), [json_extract evidence](../evidence/sqlite-json-extract-any-results-2026-10-04/manifest.json)) and typed CSV storage-class round trips for `iif()`, compound, MIN, MAX, GROUP_CONCAT, SUM, TOTAL, AVG, `json_group_array()`, `json_group_object()`, `json_quote()`, arithmetic, `json_extract()`, `substr()`, `abs()`, `instr()`, `quote()`, `length()`, `round()` and CAST-to-BLOB results ([typed CSV evidence](../evidence/sqlite-union-any-csv-roundtrip-results-2026-10-04/manifest.json), [GROUP_CONCAT evidence](../evidence/sqlite-group-concat-any-results-2026-10-04/manifest.json), [MIN evidence](../evidence/sqlite-min-any-results-2026-10-04/manifest.json), [MAX evidence](../evidence/sqlite-max-any-results-2026-10-04/manifest.json), [SUM evidence](../evidence/sqlite-sum-any-results-2026-10-04/manifest.json), [TOTAL evidence](../evidence/sqlite-total-any-results-2026-10-04/manifest.json), [AVG evidence](../evidence/sqlite-avg-any-results-2026-10-04/manifest.json), [arithmetic evidence](../evidence/sqlite-arithmetic-any-results-2026-10-04/manifest.json), [json_extract evidence](../evidence/sqlite-json-extract-any-results-2026-10-04/manifest.json), [abs evidence](../evidence/sqlite-abs-any-csv-results-2026-10-06/manifest.json), [round evidence](../evidence/sqlite-round-any-csv-results-2026-10-06/manifest.json), [quote evidence](../evidence/sqlite-quote-any-csv-results-2026-10-06/manifest.json), [instr evidence](../evidence/sqlite-instr-any-csv-results-2026-10-06/manifest.json), [length evidence](../evidence/sqlite-length-any-csv-results-2026-10-06/manifest.json)); query-result CSV round-trips storage classes with native `typeof()` proof ([nonempty result evidence](../evidence/sqlite-strict-any-query-csv-results-2026-10-03/manifest.json), [empty result evidence](../evidence/sqlite-query-empty-metadata-results-2026-10-03/manifest.json), [attached-schema origins](../evidence/sqlite-attached-any-metadata-results-2026-10-03/manifest.json)); compound-result and direct table-projection workbooks both keep formula-shaped text as text through LibreOffice Calc ODS/XLSX re-save ([formula-text evidence](../evidence/sqlite-xlsx-calc-formula-text-results-2026-10-04/manifest.json)) | Other computed-expression shapes beyond CASE/COALESCE/iif()/compound/NULLIF/MIN/MAX/GROUP_CONCAT/SUM/TOTAL/AVG/json_group_array/json_group_object/arithmetic/json_extract/json_quote/CAST-to-BLOB/substr/abs/printf/quote/instr/length, other storage-class/affinity mixtures, spreadsheet-app re-import beyond the two tested Calc workbook shapes and installed editing | Declared BOOLEAN, DATE, TIME, DATETIME and TIMESTAMP result decoding is now pinned for true/false and SQL NULL; BLOB affinity also proves runtime TEXT, INTEGER, REAL, BLOB and NULL values retain their core types in a focused native SQLite contract test. Malformed text in declared DATE, TIME, DATETIME and TIMESTAMP columns also remains exact `Value::Text` when typed decoding rejects it.
| SQL Server | Decimal/offset/calendar contracts; native catalog assertions cover decimal(38,0), decimal(38,30), decimal(28,4), decimal(38,28) and decimal(38,38), with signed 1e-38 values checked through result, native text and CSV round trips, in sql_server_numeric_values_outside_rust_decimal_round_trip_as_exact_text; all 300 legacy `datetime` ticks use exact typed or style-126 text values checked against native text and parameter byte round trips; representative SQL-literal restores match bytes; app grid display/parser/keyed updates preserve representative exact and fallback legacy `datetime` ticks plus sibling rows ([tick evidence](../evidence/mssql-legacy-datetime-ticks-results-2026-10-04/manifest.json), [grid evidence](../evidence/mssql-legacy-datetime-grid-edit-results-2026-10-04/manifest.json)); `datetimeoffset` grid edits preserve local text, scale, offset and native bytes, with catalog scale and UTC-range refusal ([grid evidence](../evidence/mssql-datetimeoffset-grid-edit-results-2026-10-04/manifest.json)); `nvarchar(max)`, `varchar(max)` and `varbinary(max)` 64 KiB boundaries and 1 MiB values round-trip through ordinary/dedicated connections and CSV import, with native lengths/hashes; XLSX rejects values past its cell limit; O2/O3 tests cover byte/row caps, first-result selection, late-error draining, connection reuse and loss during a multi-result stream ([result-set tests](../../crates/drivers/mssql/tests/support/result_sets.rs), [stream-loss test](../../crates/drivers/mssql/tests/integration.rs)); money and `sql_variant` refuse lossy decoding (non-NULL variant cells remain undecodable); U1 server-owned columns cover metadata, grid editability, CSV import, Copy as SQL and SQL export replay in `value_contract_mssql_server_owned_columns_use_native_defaults_across_consumers`; U2 fresh identity generation is covered for PostgreSQL and SQL Server; MySQL SQL-file export and Copy-as-INSERT identity consumers are replayed against the native server | Other native/consumer gaps and metadata precision beyond these decimal declarations; installed grid interaction and multi-result-set UX |
| ClickHouse | Enum8/Enum16 preserve labels across native reads, parameter writes, CSV import and Copy as SQL, including signed endpoints, empty-string labels versus SQL NULL, undeclared-label refusal, and nullable NULL distinctions ([scalar contract](../../crates/drivers/clickhouse/tests/support/enum_values.rs)); nested arrays, maps and Enum8/Enum16 tuples use native JSON/export oracles and refuse type-less SQL, binding and grid writes ([nested contract](../../crates/drivers/clickhouse/tests/support/nested_values.rs)); quoted empty/literal-`NULL` grid input is parsed distinctly from blank SQL NULL, with Enum8/Enum16 keyed edits checked against native type/code and invalid-write preservation ([app contract](../../crates/app/tests/support/clickhouse_enum_contract.rs)); nullable Enum8 and Enum16 both have an installed GTK grid-edit scenario with native-code, null/empty distinctions and sibling-row assertions ([scenario](../../scripts/test-gtk-clickhouse.sh)); wide/nested exact representations and DateTime64 precision/bounds/zones | Other nested/type/consumer combinations and broader installed acceptance; no generic type-less JSON binding |
| Redis | RESP3 tagged nested values/binary kinds, caps and persistent-stream refusal; Docker contracts preserve arbitrary-byte keys and non-UTF-8 string values in key browsing, fill pages across partial SCAN batches, prove empty SCAN termination against native Redis oracles, and verify a committed Lua write whose lost reply is not replayed after `ConnectionManager` reconnects ([integration tests](../../crates/drivers/redis/tests/integration.rs), [lost-ack test](../../crates/drivers/redis/tests/support/disconnection.rs), [PR #345 evidence](https://github.com/cozyGarage/BookiE/pull/345#issuecomment-6053620744)) | Remaining protocol/native consumer coverage beyond binary keys/strings and paged SCAN; display conversion does not prove subscription support; other write paths still need lost-ack coverage |
| MongoDB | Canonical Extended JSON, BSON width/subtypes and typed keyed edits; 0.2 interactive table pages are per-cursor observations, not point-in-time snapshots, and distinct page requests may reflect different database states; each table page fetches its requested rows with stable `_id`-ordered server-side skip/limit, then merges them with a stable `_id`-ordered 128-document metadata sample; a native `serverStatus` regression verifies the two bounded finds, and a beyond-sample Decimal128 row becomes `mixed` when its page is read; query `run_find` uses the bounded sample before its filtered result cursor and merges result-page types; rows are converted using the merged type so sample/page mismatches retain canonical Extended JSON; CSV/JSON preserve materialized Extended JSON; explicit BSON null and missing sparse-document fields have distinct result markers; dotted-path filters distinguish equality-to-null, `$exists:false`, and `$type:"null"` in both JSON-filter and MQL forms against native query results ([test](../../crates/drivers/mongodb/tests/support/nested_filters.rs)); stale grid edits compare each edited field's original value; keyed deletes compare all materialized values and the exact top-level field set, with native tests for concurrent edits, untouched siblings, removed fields, BSON NULL becoming a NULL-containing array, and fields added after materialization; an ABA regression (`value_contract_mongodb_grid_value_comparison_does_not_detect_aba`) proves value-based edits/deletes proceed after the current BSON value returns to the materialized value ([edit evidence](../evidence/mongodb-stale-grid-edit-results-2026-10-04/manifest.json), [delete evidence](../evidence/mongodb-stale-grid-delete-results-2026-10-04/manifest.json), [new-field delete evidence](../evidence/mongodb-stale-grid-delete-new-field-results-2026-10-07/manifest.json)); the late-type test checks native marker and read-only mixed result ([test](../../crates/drivers/mongodb/tests/support/run_find_late_type_contract.rs)); native `find` and `aggregate` results also prove the 64 MiB budget sets `truncated` while preserving every admitted payload, and a following query succeeds ([test](../../crates/drivers/mongodb/tests/support/query_budget_contract.rs)); the local release-binary GTK scenario verifies cursor values remain visible until F5 refresh, then an approved post-refresh edit preserves its sibling field ([scenario](../../crates/app/tests/gtk_ux.py)) | The bounded sample plus 50-row page measured 2.029/2.140/2.333/2.253 ms at 1k/10k/100k/1m documents (five debug samples, MongoDB 7 in local Docker). Debug and release medians for the bounded 50-row page are 2.029/2.140/2.333/2.253 ms and 0.676/0.796/1.048/0.733 ms at 1k/10k/100k/1m documents. The provisional under-100-ms target is met locally; installed Arch/Wayland and Debian/GNOME acceptance and realistic network latency remain open (PERF-3, TEST-12). Heterogeneity outside both the sample and returned page remains unknown until a page returns it. Multi-page full export starts independent page requests and lacks the snapshot or fail-closed behavior required by [ADR 0014](../decisions/0014-full-table-export-snapshot.md) (UI-13b) |
| DuckDB (optional) | Exact `rust_decimal` mantissa/scale parameter and explicitly typed SQL-literal boundaries ([evidence](../evidence/duckdb-rust-decimal-boundaries-results-2026-10-06/manifest.json)); wide integers, intervals, DuckDB enum result/literal/bound labels, keyed edits and raw CSV export/import (empty text, literal `NULL`, Unicode, quotes, formula-shaped text and SQL NULL retain native ENUM and a sibling row); spreadsheet-safe CSV prefixes formulas, and its typed import plan shows a collision when labels overlap ([CSV evidence](../evidence/duckdb-enum-csv-roundtrip-results-2026-10-04/manifest.json)); extended DATE/TIMESTAMP/TIMESTAMPTZ text fallbacks; nested LIST/STRUCT/ARRAY/MAP/UNION results now refuse explicitly without panicking, including LIST<ENUM> ([case evidence](../evidence/duckdb-enum-list-result-refusal-results-2026-10-05/manifest.json)) | Remaining nested combinations, other native expression contexts, native sub-microsecond bindings and installed GTK editing; text transport is not native binding; LIST<ENUM> is safely refused and is not supported |

| Shared consumers | Named parameters, export/import, grid/filter, JSON/MCP and workbook cases; grid context-menu CSV uses a collision-free SQL NULL marker ([serializer evidence](../evidence/postgres-enum-clipboard-csv-results-2026-10-04/manifest.json)); GTK clipboard delivery/readback and CSV parser recovery cover literal `NULL`, empty text, SQL NULL, marker-shaped labels and formula-shaped text ([GTK clipboard evidence](../evidence/gtk-clipboard-csv-delivery-results-2026-10-05/manifest.json)); direct TSV paste in LibreOffice Calc preserves the marker, formula safety and quoted tabs/newlines ([Calc paste evidence](../evidence/gtk-calc-tsv-clipboard-paste-results-2026-10-05/manifest.json)); scalar enum and seventeen array XLSX shapes, including `text[]`, `uuid[]`, `date[]`, `timestamp[]`, `time[]`, `timetz[]`, `boolean[]`, `int8[]`, `smallint[]` and `integer[]`, survive Calc ODS/XLSX re-save ([text[] evidence](evidence/postgres-text-array-calc-reimport-results-2026-10-05/manifest.json), [uuid[] evidence](evidence/postgres-uuid-array-calc-reimport-results-2026-10-05/manifest.json), [date[] evidence](evidence/postgres-date-array-calc-reimport-results-2026-10-05/manifest.json), [timestamp[] evidence](evidence/postgres-timestamp-array-calc-reimport-results-2026-10-05/manifest.json), [time[] evidence](evidence/postgres-time-array-calc-reimport-results-2026-10-05/manifest.json), [timetz[] evidence](evidence/postgres-timetz-array-calc-reimport-results-2026-10-05/manifest.json), [boolean[] evidence](evidence/postgres-boolean-array-calc-reimport-results-2026-10-05/manifest.json), [int8[] evidence](evidence/postgres-int8-array-calc-reimport-results-2026-10-05/manifest.json), [integer arrays evidence](../evidence/postgres-integer-arrays-calc-reimport-results-2026-10-05/manifest.json)); 86,012 finite-f64 values round-trip through CSV and JSON with exact bits ([corpus evidence](../evidence/finite-float-consumer-results-2026-10-04/manifest.json)) | Remaining format/type/configuration boundaries, native kind after writes, paste/re-import in other spreadsheet applications, lossless restore of formula-shaped text, other spreadsheet shapes, exhaustive finite-f64 enumeration and refused-operation postconditions |
| Evidence / mutation | Registered fixtures, independent oracles and existing scoped mutation results; the October 6 strict GTK + DuckDB value tier passed 364 selected tests across all 11 suites on clean source at `cfc99dd1`, with no missing suites ([run evidence](../evidence/local-gtk-duckdb-value-tier-results-2026-10-06-cfc99dd1/manifest.json)); includes the earlier PostgreSQL float4[] Calc contract ([case evidence](../evidence/postgres-float4-array-calc-reimport-results-2026-10-05/manifest.json)); enum-array subscript and clipboard runs are retained ([subscript evidence](../evidence/postgres-enum-array-generate-subscripts-results-2026-10-05/manifest.json), [clipboard run evidence](../evidence/local-gtk-duckdb-value-tier-tsv-clipboard-results-2026-10-05/manifest.json)); the separate 315-test local integration result remains at `d783182f` ([run evidence](../evidence/local-integration-tier-results-2026-10-04/manifest.json)); the SQL scanner's 110-mutant report and follow-up checks are recorded ([mutation evidence](../evidence/sql-lex-mutation-results-2026-10-06/README.md)); the PostgreSQL array dimension parser scope caught 10 of 12 mutants, with 2 unviable and none missed or timed out ([PR #149 validation](https://github.com/cozyGarage/BookiE/pull/149#issuecomment-6032390503)); zero-length span consumers now make forward progress ([guard evidence](../evidence/sql-lex-zero-progress-guards-results-2026-10-06/manifest.json)) | A focused bounded-progress selector catches all ten tested cursor arithmetic variants ([evidence](../evidence/sql-lex-cursor-arithmetic-guard-results-2026-10-06/manifest.json)); wider engine/type/consumer/configuration and mutation coverage remains open |

The SQL statement scanner now has focused cases for exact byte spans across
comments, escaped strings, bracket identifiers and tagged dollar quotes, plus
MySQL's non-nested block-comment boundary, dollar text that is not a quoted
span, and empty/cursor-at-end inputs.
Targeted mutations for ClickHouse backtick escapes, invalid PostgreSQL
dollar-tag characters and MySQL dollar-text handling are now killed. A bounded
subprocess case checks nested and ordinary comments, quotes, bracket
identifiers, dollar quotes, separators and Unicode; it catches all 24 mutants
in the focused scanner recheck, including all 13 previously timed-out
mutations, with no missed or timed-out mutants. See the
[mutation report](../evidence/sql-lex-mutation-results-2026-10-06/README.md) and
[case packet](../evidence/sql-lex-mysql-dollar-boundary-results-2026-10-06/manifest.json).
The exact bounded-progress test selector also catches all ten generated
cursor-arithmetic variants; this is the focused check for the seven variants
that timed out when the whole `sql_lex::tests` module was selected
([mutation evidence](../evidence/sql-lex-cursor-arithmetic-guard-results-2026-10-06/manifest.json)).

The core JSON exporter was mutation-audited at source SHA-256
`88007bfbfb309030f2f080c2d48bb10012ab4e6e3ac383fa993c2cb1e30678d1`.
The initial 23-mutant run caught 20; two duplicate-name loop mutations timed
out because the broad `json` selector also runs a renderer test that invokes
the same loop directly. Running those three loop mutations against the bounded
`json_field_names_make_progress_when_duplicate_names_have_gaps` selector caught
all three in five seconds. Removing the explicit `Value::Null` arm is
behavior-equivalent: `value_to_text(Value::Null)` returns `None`, which the JSON
fallback also serializes as null. Final triage: 22 caught, one equivalent, no
missed or unresolved timed-out mutants.

Dialect-specific SQL string quoting was mutation-audited at source SHA-256
`589e831e5a7dc2be8b47a03243542559db7a4fa3eefe3750d81070d2ddb7868f`.
The MySQL, ClickHouse and PostgreSQL `string_literal`/`quote_literal` slice
generated ten mutants; the `backslash` regression selector caught all ten in
15 seconds.
On that same source fingerprint, the ClickHouse `DateTime64` precision and
range slice generated 27 mutants; the `clickhouse_datetime64` regression
selector caught all 27 in 46 seconds.

CSV cell formatting was mutation-audited at source SHA-256
`6db55d319ed07c6dc42248f5cacd3363350b6d79cf706cf0c8ea4e7037f444ca`.
The `csv` selector caught 16 of 19 mutations. The other three are equivalent:
TSV header presence is controlled by `with_headers`, its explicit NULL marker
takes precedence over `null_to_empty`, and the RFC 4180 header/row adapters
choose their output in separate functions.
The 68 matching core tests passed on the baseline; the scoped mutant run took
80 seconds and had no surviving behavior change.

XLSX cell encoding and coordinate validation were mutation-audited at source
SHA-256 `c8d853991ffdda28bef3e3753e8c28355e07140a533c36be391b56de31165fb2`.
The `workbook` selector caught all 31 generated mutations in 53 seconds,
including numeric precision, temporal range, and cell-coordinate boundaries.

XML escaping and element-name validation were audited at source SHA-256
`572bd45d6a3a095ce820a311b6434852d78082fb6a4071efb735c5a83fb511ea`.
The `xml` selector caught 38 of 39 generated mutations; one was build-unviable.
The run exposed an untested reserved-prefix boundary, so
`valid_names_with_only_one_reserved_prefix_letter_are_not_prefixed` now checks
valid names with `x`, `m`, or `l` outside the reserved `xml` prefix. The final
rerun had no misses or timeouts; all eight XML unit tests pass.

SQLite `substr()` over STRICT `ANY` now round-trips INTEGER/REAL-derived text,
ordinary and empty TEXT, UTF-8 and binary BLOBs, and SQL NULL through typed CSV.
Native `typeof()` and `hex()` check both the source expression and restored
values ([evidence](../evidence/sqlite-substr-any-csv-results-2026-10-05/manifest.json)).

SQL Server `datetimeoffset(7)` now has an XLSX consumer assertion alongside its
native-byte, CSV, SQL-literal and keyed-grid contracts. The workbook stores
positive/negative offsets and calendar-boundary values as exact text cells with
no formulas ([evidence](../evidence/mssql-datetimeoffset-xlsx-consumer-results-2026-10-05/manifest.json)).

SQL Server `decimal(38,0)` and `decimal(38,30)` results outside
`rust_decimal::Decimal` remain exact `Value::Text`; scale-28 values within its
mantissa range stay `Value::Decimal`, and SQL NULL stays distinct. Parameter rebinding and CSV
import using the destination column metadata preserve all three rows, checked
against native decimal text and row equality in
`sql_server_numeric_values_outside_rust_decimal_round_trip_as_exact_text`
(`crates/drivers/mssql/tests/support/wide_numeric.rs`). Positive zero at scale
30 remains positive exact text through the same consumers. The scale-28 boundary
is covered in both the codec unit test and native SQL Server fixture. The codec
mutation slice, run before that test-only addition on source SHA-256
`e892c28764ff3adf17d27bc9976ab46d9332fc5229302781785c188991d88beb`, tested 37
variants: 31 were caught, 6 were build-unviable, with no misses or timeouts.

PostgreSQL `date[]` result text stays canonical ISO when fetched under
`DateStyle = SQL, DMY`; CSV export, parameter rebinding and SQL replay under
`ISO, MDY` preserve the source array's native wire bytes
([evidence](../evidence/postgres-date-array-sql-dmy-results-2026-10-05/manifest.json)).

PostgreSQL `timestamp[]` now also stays canonical when fetched under
`DateStyle = SQL, DMY`; rebinding after the transaction changes to `ISO, MDY`
preserves the original `array_send` bytes for fractional, BC, extended-year,
infinite and SQL NULL elements
([evidence](../evidence/postgres-timestamp-array-datestyle-results-2026-10-05/manifest.json)).

PostgreSQL `interval[]` values also survive rebinding, CSV and SQL replay when
the transaction changes from `postgres_verbose` to `iso_8601` `IntervalStyle`;
native `array_send` bytes cover mixed-sign calendar/time components, zero and
SQL NULL ([evidence](../evidence/postgres-interval-array-style-transition-results-2026-10-05/manifest.json)).

The selected-row TSV clipboard path is also exercised in LibreOffice Calc 26.8.0.3:
literal `NULL`, empty text, SQL NULL's collision-free marker, marker-shaped labels,
formula-shaped text and quoted tab/newline text retain the asserted cell contents
after a real Ctrl+V and Text Import acceptance. GDK publication/readback is covered
separately by the GTK test; the [Calc evidence packet](../evidence/gtk-calc-tsv-clipboard-paste-results-2026-10-05/manifest.json)
records the pasted payload and UNO cell values. Other spreadsheet applications
and lossless re-import of the formula-safety prefix remain open.

DuckDB app keyed edits now have a native `TIME_NS`/`TIMESTAMP_NS` contract:
nanosecond edits preserve both declared types and all nine fractional digits,
and leave a sibling row unchanged ([evidence](../evidence/duckdb-nanosecond-keyed-grid-edit-results-2026-10-05/manifest.json)).
Parameterized INSERT and UPDATE also preserve nine-digit `TIME_NS` and
`TIMESTAMP_NS` values, SQL NULLs and sibling fields through the target column's
native type context ([evidence](../evidence/duckdb-nanosecond-parameter-dml-results-2026-10-06/manifest.json)).
Submicro values use exact text binding because the pinned DuckDB Rust value
binding truncates nanosecond temporal values to microseconds. Expressions that
cast that exact text to `TIMESTAMP_NS` are now checked with interval arithmetic:
DuckDB returns a `TIMESTAMP` rounded to microseconds, matching its native literal
expression. `epoch_ns()` on the same cast preserves the full pre-epoch value
(`-876543211`), independently proving the bound text retained nanoseconds
before arithmetic rounded. `TIME_NS` plus interval remains a native binder
refusal. These outcomes are asserted in
`value_contract_submicro_text_parameters_keep_precision_after_explicit_casts`
(`crates/drivers/duckdb/tests/support/submicro_parameter_expression.rs`; see the [PR validation comment](https://github.com/cozyGarage/BookiE/pull/128#issuecomment-6029090575)). Other
expression contexts and native sub-microsecond parameter bindings remain open;
the text fallback is not native typed binding.

DuckDB nested-result refusal now covers a `STRUCT` containing a `UHUGEINT` list
and a `MAP` containing a `UHUGEINT` struct. Native `typeof()` and JSON oracles
verify values and SQL NULL elements, while SQL literal rendering and parameter
rebinding both refuse the undecodable results
([evidence](../evidence/duckdb-nested-collection-refusal-results-2026-10-06/manifest.json)).

ClickHouse's nested consumer contract adds
`Map(UInt8, Array(Tuple(String, Nullable(UInt128))))`, including a UInt128 above
`u64::MAX`, a NULL tuple field and an empty nested array. Native type/JSON oracles
match JSON, CSV and XLSX output; XLSX stores the nested result as text matching
the native JSON oracle. Type-less SQL, parameter and grid-edit consumers refuse
without changing the stored row. The full ClickHouse Docker integration suite
passes 33 tests
([nested contract](../evidence/clickhouse-nested-map-array-tuple-results-2026-10-06/manifest.json),
[XLSX follow-up](../evidence/clickhouse-nested-xlsx-consumers-2026-10-06/manifest.json)).

SQLite STRICT `ANY` computed-result contracts now cover `CASE`, `COALESCE`,
`iif()`, `NULLIF`, `MIN`/`MAX`, `SUBSTR`, `ABS`, `ROUND`, `hex`, `quote`, `instr`,
`length`, `CAST(value AS BLOB)`, `json_group_array()` and
`json_group_object()`. The JSON aggregate cases
(`sqlite_json_group_array_any_csv_round_trip_preserves_json_null_and_text` and
`sqlite_json_group_object_any_csv_round_trip_preserves_native_text`,
[tests](../../crates/app/tests/support/sqlite_any_contract/aggregate_csv.rs)) check
numeric and text values, JSON null versus SQL NULL, empty arrays/objects,
duplicate object keys, NULL-label behavior, and typed CSV restore against
SQLite's native result and `typeof()`. The object test checks version-specific
NULL-label behavior: SQLite 3.50.0+ omits the entry, while older system
libraries' malformed native text is preserved exactly. JSON export retains
each aggregate's exact result text as a string, and XLSX keeps the duplicate-key
object text in string cells without formulas.
Typed CSV restore checks native storage classes and exact values or bytes; BLOB
casts also have JSON and XLSX text-cell assertions. The nested `iif()` case
checks integer, real, formula-shaped text, BLOB and SQL NULL through native
`typeof()` and typed CSV restore
([test](../../crates/app/tests/support/sqlite_any_contract/iif_csv.rs)).
The focused app test and quick-gate results are recorded in the
[PR #331 validation comment](https://github.com/cozyGarage/BookiE/pull/331#issuecomment-6053023990).
Representative evidence:
[CASE](../evidence/sqlite-case-any-csv-roundtrip-results-2026-10-04/manifest.json),
[SUBSTR](../evidence/sqlite-substr-any-csv-results-2026-10-05/manifest.json),
[ABS](../evidence/sqlite-abs-any-csv-results-2026-10-06/manifest.json),
[ROUND](../evidence/sqlite-round-any-csv-results-2026-10-06/manifest.json),
[BLOB cast](../evidence/sqlite-cast-blob-any-csv-results-2026-10-04/manifest.json).
Other computed functions and aggregate families, additional attached-origin
patterns, non-CSV consumer combinations and installed editing remain open. An
attached STRICT `ANY` source now has an app-level typed CSV restore contract
that checks native storage classes and exact values or bytes after import.

SQLite `hex(value)` over STRICT `ANY` now checks integer, real, UTF-8 and empty
text, BLOB, SQL NULL, formula-shaped text and tag-shaped text. SQLite's native
oracle reports TEXT for every result (including its empty-string result for
SQL NULL); typed CSV restore preserves those results as TEXT in another STRICT
`ANY` table ([evidence](../evidence/sqlite-hex-any-csv-results-2026-10-06/manifest.json)).
The `quote(value)` expression now also checks numeric, empty, Unicode,
escaped-apostrophe, BLOB, formula-shaped and SQL NULL inputs. Native
`typeof()`/`hex()` results and typed CSV restore confirm every generated SQL
literal remains TEXT, including the text `NULL` generated from SQL NULL
([evidence](../evidence/sqlite-quote-any-csv-results-2026-10-06/manifest.json)).
SQLite `instr(value, needle)` now covers numeric-to-text coercion, empty and
formula-shaped text, Unicode code-point positions, byte-oriented BLOB matches,
and SQL NULL. Native `typeof()`/`hex()` assertions verify integer/NULL result
kinds, and typed CSV restore keeps the integer results as INTEGER and SQL NULL
as NULL ([evidence](../evidence/sqlite-instr-any-csv-results-2026-10-06/manifest.json)).
SQLite `length(value)` over STRICT `ANY` now checks numeric coercion, Unicode
code-point counts, empty text, BLOB byte counts including embedded NUL, text
termination at embedded NUL, formula-shaped text and SQL NULL. Native
`typeof()`/`hex()` assertions and typed CSV restore preserve integer results
and SQL NULL as their distinct storage classes
([evidence](../evidence/sqlite-length-any-csv-results-2026-10-06/manifest.json)).

PostgreSQL scalar custom-enum XLSX values now survive LibreOffice Calc ODS/XLSX
re-save with formula-shaped labels retained as text and SQL NULL left blank
([Calc evidence](../evidence/postgres-enum-scalar-calc-reimport-results-2026-10-04/manifest.json)).
Gnumeric also re-saves the scalar-enum workbook with `=1+1` retained as a
string, SQL NULL blank, and no formula
([Gnumeric evidence](../evidence/postgres-enum-scalar-gnumeric-reimport-results-2026-10-05/manifest.json)).
Calc and Gnumeric also preserve enum-array labels with leading/trailing spaces
through XLSX/ODS/XLSX re-save; all five workbook stages retain exact text cells
without formulas ([whitespace evidence](../evidence/postgres-enum-array-whitespace-reimport-results-2026-10-06/manifest.json)).
Calc and Gnumeric preserve scalar labels with leading/trailing spaces through
XLSX/ODS/XLSX re-save; empty enum labels remain refused and SQL NULL stays
blank ([whitespace evidence](../evidence/postgres-enum-scalar-whitespace-reimport-results-2026-10-06/manifest.json)).
Calc and Gnumeric also preserve a 2×6 enum array with non-default lower bounds,
empty and literal-`NULL` labels, a SQL NULL element, and formula-shaped text
through XLSX/ODS/XLSX re-save. Native type, dimensions, JSON, wire bytes, typed
rebinding and SQL replay are checked ([Calc evidence](../evidence/postgres-enum-array-shapes-calc-results-2026-10-06/manifest.json),
[Gnumeric evidence](../evidence/postgres-enum-array-shapes-gnumeric-results-2026-10-06/manifest.json)).
Other spreadsheet applications and enum-array shape combinations remain open.

The PostgreSQL enum CSV importer now also has a round trip for double quotes,
an embedded line break, backslashes and formula-shaped text across four
delimiters and three record endings; auto-detection identifies each format,
and native UTF-8 byte/type assertions verify import ([evidence](../evidence/postgres-enum-csv-quoted-lines-results-2026-10-04/manifest.json)).

PostgreSQL enum SQL-file output also replays a backslash-bearing label with
all four `standard_conforming_strings` and `backslash_quote` combinations
(`on/safe_encoding`, `on/off`, `off/off`, `off/on`); backslashes use explicit
`E''` literals ([initial evidence](../evidence/postgres-enum-sql-literal-session-modes-results-2026-10-04/manifest.json),
[full setting matrix](../evidence/postgres-enum-sql-literal-session-modes-full-results-2026-10-05/manifest.json)).

PostgreSQL custom enum-array CSV import now has native round trips for NULL
arrays versus empty arrays and NULL elements, lower-bound-zero and
two-dimensional shapes, literal `NULL` and empty labels, Unicode, and sibling
row preservation ([shape evidence](../evidence/postgres-enum-array-csv-shapes-results-2026-10-04/manifest.json)).
The CSV import also selects the table's enum when an identically named type in
another schema shadows it through `search_path` ([evidence](../evidence/postgres-shadowed-enum-array-import-results-2026-10-04/manifest.json)).
Scalar-enum CSV restore has the same configuration check with a target-only
label, empty text, literal `NULL`, SQL NULL and an unchanged sibling row
([evidence](../evidence/postgres-enum-csv-shadow-search-path-results-2026-10-05/manifest.json)).
Scalar enum CSV export and typed restore also preserve leading and trailing
label spaces exactly; native text and enum type assertions cover both rows
([evidence](../evidence/postgres-enum-scalar-csv-whitespace-2026-10-06/manifest.json)).
The import plan also remains bound to its destination enum when a fresh
execution connection changes the role's `search_path` to put a different
same-named decoy enum first between planning and execution; native target type,
values and untouched shadow/sibling rows are checked
([evidence](../evidence/postgres-enum-csv-search-path-transition-results-2026-10-05/manifest.json)).
Custom enum-array grid edits now have app-parser and native keyed-write
coverage, including invalid-label refusal and sibling preservation ([evidence](../evidence/postgres-enum-array-grid-edit-results-2026-10-04/manifest.json)).
The grid parser and live write path distinguish blank SQL NULL from the empty
array literal `{}` ([evidence](../evidence/postgres-enum-array-grid-null-results-2026-10-04/manifest.json)).
Default CSV now likewise imports blank as a SQL NULL array and `{}` as an empty
array; scalar enum blank refusal remains in place ([evidence](../evidence/postgres-enum-array-default-null-results-2026-10-04/manifest.json)).
Arrays of domains over enums now import through their qualified domain-array
type, preserving domain checks and native array bytes ([evidence](../evidence/postgres-domain-enum-array-import-results-2026-10-04/manifest.json)).
That import also remains bound to the target schema when `search_path` starts
with an identically named shadow domain ([shadowed-path evidence](../evidence/postgres-domain-enum-array-shadowed-import-results-2026-10-04/manifest.json)).
The same type also has app-parser and live keyed-grid coverage with domain-check
refusal and rollback ([evidence](../evidence/postgres-domain-enum-array-grid-results-2026-10-04/manifest.json)).
Structured equality filtering is checked against native array JSON and wire
values ([evidence](../evidence/postgres-domain-enum-array-filter-results-2026-10-04/manifest.json)).
The same array now has JSON, CSV, XML, HTML, Markdown and XLSX file-writer
coverage plus typed SQL replay checked against native type, JSON and wire
oracles ([file-writer evidence](../evidence/postgres-domain-enum-array-filewriter-results-2026-10-04/manifest.json)).
Its XLSX string cell also survives Gnumeric's XLSX/ODS/XLSX re-save with the
full escaped array text and formula-shaped enum label unchanged
([Gnumeric evidence](../evidence/postgres-domain-enum-array-gnumeric-reimport-results-2026-10-05/manifest.json)).
A PostgreSQL custom `enum[]` with literal `NULL`, empty, Unicode, escaped,
formula-shaped and SQL NULL elements also survives Gnumeric's XLSX/ODS/XLSX
re-save with exact text and no formulas ([evidence](../evidence/postgres-enum-array-gnumeric-reimport-results-2026-10-06/manifest.json)).
The same custom `enum[]` shape survives LibreOffice Calc's XLSX/ODS/XLSX
re-save with its exact escaped array text and no formulas
([evidence](../evidence/postgres-enum-array-calc-reimport-results-2026-10-06/manifest.json)).
A UUID-domain array now decodes by its base OID, with a typed keyed edit, CHECK
refusal and sibling preservation ([evidence](../evidence/postgres-domain-uuid-array-results-2026-10-04/manifest.json)).
Text, numeric and timestamptz domain arrays also pass qualified binding and
native JSON/wire comparisons in a non-UTC session
([matrix evidence](../evidence/postgres-domain-array-family-results-2026-10-04/manifest.json)).
Domain arrays over `bytea` preserve non-UTF-8 bytes, empty elements and NULL
through qualified binding and keyed edits; domain CHECK refusal preserves the
row and its sibling, with native JSON/wire oracles
([evidence](../evidence/postgres-domain-bytea-array-results-2026-10-04/manifest.json)).
The keyed edit also succeeds with a stricter same-named domain first in
`search_path`, proving the generated cast resolves to the target schema
([shadowed-path evidence](../evidence/postgres-shadowed-domain-bytea-array-results-2026-10-04/manifest.json)).
The custom `enum[]` XLSX text cell also survives a LibreOffice Calc re-save as
ODS and then XLSX ([evidence](../evidence/postgres-enum-array-calc-reimport-results-2026-10-04/manifest.json)).
It now also survives Gnumeric's re-save with a formula-shaped label, Unicode,
quotes, backslashes, markup, empty text and SQL NULL preserved as escaped array
text, with no formula created
([evidence](../evidence/postgres-enum-array-gnumeric-reimport-results-2026-10-05/manifest.json)).
The formula-shaped enum label also survives the pinned LibreOffice Calc
XLSX/ODS/XLSX round trip as the same escaped text without a formula
([Calc evidence](../evidence/postgres-enum-array-formula-calc-reimport-results-2026-10-05/manifest.json)).
The `bytea[]` XLSX text cell now survives the same Calc re-import with its
binary, empty and SQL NULL elements intact
([evidence](../evidence/postgres-bytea-array-calc-reimport-results-2026-10-04/manifest.json)).
A `timestamptz[]` XLSX cell also preserves repeated-hour instants, a BC instant,
infinities and SQL NULL through Calc's ODS/XLSX re-save
([evidence](../evidence/postgres-timestamptz-array-calc-reimport-results-2026-10-04/manifest.json)).
A separate file-writer contract runs under `America/New_York`: PostgreSQL's
native array text and JSON show the two fall-back offsets, while BookiE's
decoded array text remains canonical UTC. Rebinding and SQL-file restore after
switching the transaction to `Asia/Kathmandu` preserve the original
`array_send` bytes ([session evidence](../evidence/postgres-timestamptz-array-non-utc-session-results-2026-10-05/manifest.json)).
The workbook from that same `America/New_York` transaction also survives Calc
and Gnumeric XLSX/ODS/XLSX re-saves as the identical canonical UTC string
([spreadsheet evidence](../evidence/postgres-timestamptz-array-non-utc-calc-results-2026-10-05/manifest.json)).
A separate Gnumeric XLSX/ODS/XLSX check preserves the boundary text in
PostgreSQL `date[]`, `timestamp[]`, `time[]` and `timetz[]` cells, including BC
and extended years, infinities, 24:00, maximum offsets and SQL NULL
([evidence](../evidence/postgres-temporal-arrays-gnumeric-reimport-results-2026-10-05/manifest.json)).
A PostgreSQL `interval[]` XLSX cell preserves mixed signs, microseconds, zero
intervals and SQL NULL through the same Calc re-save
([evidence](../evidence/postgres-interval-array-calc-reimport-results-2026-10-04/manifest.json)).
The app parser and keyed-update path also round-trip `date[]`, `time[]`,
`timestamp[]` and `timetz[]` boundary values against PostgreSQL type, JSON and
wire-byte oracles, preserving sibling rows and refusing malformed date-array
input ([evidence](../evidence/postgres-temporal-array-grid-edit-results-2026-10-05/manifest.json)).
The same app grid path now covers `smallint[]`, `integer[]` and `bigint[]`
signed endpoints, non-default lower bounds and the precision-risk integer
9007199254740993, with native type/JSON/wire oracles and overflow refusal
([evidence](../evidence/postgres-integer-array-grid-edit-results-2026-10-05/manifest.json)).
A `text[]` grid edit also preserves SQL NULL separately from literal `NULL` and
empty text, plus escaped punctuation, Unicode and formula-shaped text; a
malformed array is refused without mutation
([evidence](../evidence/postgres-text-array-grid-edit-results-2026-10-05/manifest.json)).
The app parser and keyed-update path also round-trip `interval[]` mixed-sign
month/day/time values, microseconds, zero intervals and SQL NULL against
PostgreSQL type, JSON and wire-byte oracles while preserving sibling bytes
([evidence](../evidence/postgres-interval-array-grid-edit-results-2026-10-05/manifest.json)).
The same path now round-trips `float4[]` adjacent values, negative zero, the
minimum subnormal, NaN, infinities and SQL NULL against PostgreSQL type, JSON and
wire-byte oracles, preserving the sibling row; a malformed element is refused
with SQLSTATE 22P02 and leaves both rows unchanged
([evidence](../evidence/postgres-float4-array-grid-edit-results-2026-10-05/manifest.json)).

SQLite computed `CASE` and `COALESCE` results now have native app CSV round
trips with storage-class assertions; see the [CASE evidence](../evidence/sqlite-case-any-csv-roundtrip-results-2026-10-04/manifest.json)
and [COALESCE evidence](../evidence/sqlite-coalesce-any-csv-roundtrip-results-2026-10-04/manifest.json).
The CASE path also verifies empty TEXT round-trips separately from NULL in CSV
and that XLSX refuses the ambiguous cell without replacing the destination;
see the [refusal evidence](../evidence/sqlite-case-any-xlsx-refusal-results-2026-10-04/manifest.json).
The COALESCE JSON output checks numeric versus string values, and the XLSX output
checks numeric versus shared-string cells and BLOB text encoding against its
computed runtime kinds; see the [consumer evidence](../evidence/sqlite-coalesce-any-xlsx-results-2026-10-04/manifest.json).

LibreOffice Calc now imports and re-saves one compound STRICT `ANY` workbook
while preserving numeric `42`, text `42` and blank SQL NULL as distinct cell
kinds ([re-import evidence](../evidence/sqlite-xlsx-calc-reimport-results-2026-10-04/manifest.json)).
Other workbook cases, spreadsheet applications and installed editing remain open.

One PostgreSQL `text[]` result now has XML, HTML, Markdown and XLSX file-writer
coverage plus a replayed SQL export, checked against native array JSON and wire
oracles; see the [array export evidence](../evidence/postgres-array-filewriter-results-2026-10-04/manifest.json).
PostgreSQL `numeric[]` now also preserves exact text through XML, HTML and
Markdown alongside its JSON, CSV, XLSX and native SQL replay checks
([evidence](../evidence/postgres-numeric-array-markup-export-results-2026-10-06/manifest.json)).
The custom `enum[]` file-writer case now also covers XML, HTML and Markdown
escaping alongside JSON, CSV, XLSX and replayed SQL, with native array JSON
and wire oracles ([evidence](../evidence/postgres-enum-array-markup-export-results-2026-10-06/manifest.json)).
Other array families remain open; spreadsheet-application re-import is covered
for `text[]`, `uuid[]`, `date[]`, `timestamp[]`, `time[]`, `timetz[]`, `boolean[]`, `int8[]`, `smallint[]`, `integer[]`, `enum[]`, domain-over-enum `[]`, `bytea[]`,
`timestamptz[]`, `interval[]`, `numeric[]`, `float8[]` and `float4[]` XLSX cells ([text[] Calc evidence](evidence/postgres-text-array-calc-reimport-results-2026-10-05/manifest.json), [uuid[] Calc evidence](evidence/postgres-uuid-array-calc-reimport-results-2026-10-05/manifest.json), [numeric[] Calc evidence](evidence/postgres-numeric-array-calc-reimport-results-2026-10-04/manifest.json), [float8[] Calc evidence](evidence/postgres-float8-array-calc-reimport-results-2026-10-04/manifest.json), [float4[] Calc evidence](evidence/postgres-float4-array-calc-reimport-results-2026-10-05/manifest.json)), with other shapes unverified (see the [enum[] evidence](evidence/postgres-enum-array-calc-reimport-results-2026-10-04/manifest.json),
[bytea[] evidence](evidence/postgres-bytea-array-calc-reimport-results-2026-10-04/manifest.json)
and [timestamptz[] evidence](evidence/postgres-timestamptz-array-calc-reimport-results-2026-10-04/manifest.json),
[interval[] evidence](evidence/postgres-interval-array-calc-reimport-results-2026-10-04/manifest.json)).
The numeric[] shape also survives Gnumeric XLSX/ODS/XLSX re-import with the
same wide precision, scale, special values and SQL NULL as text
([Gnumeric evidence](../evidence/postgres-numeric-array-gnumeric-reimport-results-2026-10-05/manifest.json)).
The `float8[]` string cell also survives Gnumeric's XLSX/ODS/XLSX re-save with
adjacent, negative-zero, subnormal, special and NULL values unchanged
([Gnumeric evidence](../evidence/postgres-float8-array-gnumeric-reimport-results-2026-10-05/manifest.json)).
The UUID[] file-writer case now covers JSON, CSV, XLSX string cells and SQL
replay with native type/value/JSON/wire checks and sibling preservation
([evidence](../evidence/postgres-uuid-array-filewriter-results-2026-10-05/manifest.json)).
The `float4[]` file-writer matrix now includes CSV text export, SQL-file replay
and Calc XLSX/ODS/XLSX re-import: native `float4send` checks adjacent,
negative-zero and minimum-subnormal elements; typed rebinding and SQL replay
match the native array bytes; Calc preserves the full shared-string cell
([evidence](../evidence/postgres-float4-array-calc-reimport-results-2026-10-05/manifest.json)).
The PostgreSQL `boolean[]` file-writer case now covers JSON, CSV, XML, HTML,
Markdown, XLSX and SQL replay for true, false and SQL NULL elements; the replay
matches native type, JSON and wire-byte oracles
([evidence](../evidence/postgres-boolean-array-filewriter-results-2026-10-06/manifest.json)).

The `float8[]` file-writer contract now checks JSON, CSV, XML, HTML, Markdown,
XLSX and SQL replay. Exports preserve the array as text with format escaping;
SQL replay retains the native array type, JSON semantics and wire bytes, while
`float8send` pins adjacent, negative-zero and minimum-subnormal bits
([evidence](../evidence/postgres-float8-array-filewriter-results-2026-10-06/manifest.json)).

A PostgreSQL `bytea[]` with non-UTF-8 bytes, an empty element and SQL NULL now
has JSON, CSV, XLSX and replayed SQL file-writer coverage against native element,
JSON and wire oracles ([evidence](../evidence/postgres-bytea-array-filewriter-results-2026-10-04/manifest.json)).
With `bytea_output = 'escape'`, the raw `bytea[]::text` projection now rebinds
under both escape and hex output settings while preserving each element and
native array bytes ([session evidence](../evidence/postgres-bytea-array-output-escape-results-2026-10-06/manifest.json)).
Custom enum-array SQL replay now also has a backslash label checked under all
four PostgreSQL string-setting combinations against native array text, JSON,
wire bytes and a preserved sibling
([evidence](../evidence/postgres-enum-array-sql-mode-results-2026-10-05/manifest.json)).

The ordinary custom-enum shadow-schema case checks structured `=`, `IN` and
`BETWEEN` filters on `enum_shadow_b.items` while `search_path` resolves the same
enum name in `enum_shadow_a`; native target type/value checks pass. See the
[initial equality evidence](../evidence/postgres-shadowed-enum-filter-results-2026-10-03/manifest.json)
and [list/range follow-up](../evidence/postgres-shadowed-enum-filter-matrix-results-2026-10-03/manifest.json).
A direct equality, `IN` and `BETWEEN` query with bound text values also resolve
against the qualified target enum and leave the shadow row untouched; see the
[query-parameter evidence](../evidence/postgres-shadowed-enum-parameter-results-2026-10-03/manifest.json).
The keyed-edit regression now changes ordinary session `search_path` twice
inside one transaction on the same backend, then verifies target-schema enum
metadata and write safety under the final shadowed path; see the
[session evidence](../evidence/postgres-enum-session-search-path-results-2026-10-04/manifest.json).

A quoted-identifier enum case verifies catalog metadata, keyed edit, draft
insert and typed filtering when both schema and type names contain spaces and
embedded quotes. PostgreSQL catalog values confirm the exact stored enum type
and values; see [quoted enum identifier evidence](../evidence/postgres-quoted-enum-identifiers-results-2026-10-04/manifest.json).
The same contract changes `search_path` with `SET LOCAL` and verifies that an
uncast `status = $1` query still infers the target table's enum type.
When `pg_typeof($1)` leaves an enum comparison parameter ambiguous, native
PostgreSQL preparation returns `42P08`; an explicit qualified enum cast makes
the parameter type unambiguous. The driver preserves native `42P08` if its
text-typed fallback conflicts with the enum operator. The regression pins both
errors and the explicit-cast success in that evidence packet.

The PostgreSQL 16 ordinary-enum and domain-over-enum structured filters now
cover every shared `FilterOp`, including range comparisons, text-pattern
filters, both NULL operators and both list operators, with exact rows/labels and
native type assertions; see the
[complete filter matrix](../evidence/postgres-enum-filter-matrix-results-2026-10-03/manifest.json).
For direct query parameters, base-enum-cast `=`, `<>`, `<`, `<=`, `>`, `>=`,
`IN`, `NOT IN`, `BETWEEN`, `IS DISTINCT FROM` and `IS NOT DISTINCT FROM`
preserve inferred parameter types; raw domain
`= $1` remains explicitly refused with SQLSTATE 42883. See the
[query-operator evidence](../evidence/postgres-domain-enum-query-operators-results-2026-10-03/manifest.json)
and the [ordering](../evidence/postgres-domain-enum-param-operator-results-2026-10-03/manifest.json)
and [list-operator evidence](../evidence/postgres-domain-enum-param-list-results-2026-10-03/manifest.json),
plus [NULL-safe distinctness evidence](../evidence/postgres-domain-enum-distinct-parameter-results-2026-10-03/manifest.json).
Other direct query-parameter contexts and session configurations remain open.
Selected schema-aware result, edit, insert and filter paths pass through 4,096
domain layers; raw inferred text/NULL contexts have explicit limits. Deep
domain-over-enum array results decode through 1,024 layers and refuse from
1,025; deep `COALESCE`, both `CASE` result branches, and `GREATEST`/`LEAST`
retain inferred enum values and types. Deep `NULLIF(status, $1)` retains
PostgreSQL's native SQLSTATE 42883 refusal, and `array_append` refuses at the
driver's resolvable-depth boundary. Other custom/native cases still need proof.

PostgreSQL 16 also infers text and SQL NULL as the custom enum in both argument
positions of `COALESCE` and in `array_append(ARRAY[enum_column], $1)`. Native
`pg_typeof`, exact values, NULL behavior, native `22P02` invalid-label refusals
and unchanged source rows are asserted
([evidence](../evidence/postgres-enum-expression-parameter-results-2026-10-04/manifest.json)).
A CASE result context now covers `$1` in both `THEN`/`ELSE` positions. The
literal `NULL` label, empty enum label and SQL NULL are compared with explicitly
typed native expressions; `pg_typeof` verifies parameter and result types, and
invalid labels retain native `22P02` behavior
([evidence](../evidence/postgres-enum-case-parameter-inference-results-2026-10-05/manifest.json)).
`GREATEST` and `LEAST` now cover the parameter in both argument positions,
including their NULL handling, against explicitly typed enum expressions and
`pg_typeof` results ([evidence](../evidence/postgres-enum-greatest-least-parameter-inference-results-2026-10-05/manifest.json)).
These `COALESCE`, `NULLIF`, `GREATEST` and `LEAST` contexts now also have a native
same-named-shadow `search_path` contract for ordinary custom enums, after
warming target type metadata and switching paths on the same backend, with
empty/literal-`NULL` labels, SQL NULL, type checks and shadow-only label refusal
([evidence](../evidence/postgres-shadowed-enum-parameter-context-results-2026-10-05/manifest.json)).
A follow-up also verifies `NULLIF(enum_column, $1)` infers both text and SQL
NULL parameters as the native enum, preserves exact results, and returns native
`22P02` for an invalid label
([evidence](../evidence/postgres-enum-nullif-parameter-results-2026-10-04/manifest.json)).
A shadow-schema domain-over-enum follow-up confirms raw `NULLIF(status, $1)`
retains PostgreSQL's `42883` refusal; casting the column to its qualified
base enum enables text/NULL inference without resolving to the shadow type.
It also checks literal `NULL`, invalid-label `22P02`, result types and unchanged
domain rows ([evidence](../evidence/postgres-domain-nullif-parameter-results-2026-10-04/manifest.json)).

A domain-over-enum `COALESCE` contract now covers text and SQL NULL in both
argument positions. PostgreSQL infers the parameter and expression as the base
enum while the source column remains the outer domain, verified with `pg_typeof`
and exact rows ([evidence](../evidence/postgres-domain-coalesce-results-2026-10-04/manifest.json)).
The same domain-over-enum path now covers both CASE result branches while a
same-named shadow enum leads `search_path`; the target base enum parameter and
CASE result types, outer domain type, empty/literal-NULL/SQL-NULL values and
invalid-label refusal are all checked against native expressions
([evidence](../evidence/postgres-domain-case-shadowed-parameter-results-2026-10-05/manifest.json)).
Both domain-over-enum `COALESCE` parameter positions now have the same shadowed
path checks against explicit native casts, including empty text, literal
`NULL`, SQL NULL and invalid shadow-only labels
([evidence](../evidence/postgres-domain-coalesce-shadowed-results-2026-10-05/manifest.json)).
The same text/NULL inference now covers `array_append` and `array_prepend`: the
input constructor retains `state_domain[]`, while the polymorphic function result
uses `state[]` ([array-function evidence](../evidence/postgres-domain-array-functions-results-2026-10-04/manifest.json)).

The three-level domain chain also covers directly inferred text and SQL NULL
parameters for both NULL-safe distinctness operators, with `pg_typeof` checks
for the leaf enum and outer domain. See the
[three-level query-parameter evidence](../evidence/postgres-three-level-enum-query-operator-results-2026-10-03/manifest.json).

A separate PostgreSQL 16 contract follows four nested domains to the enum leaf,
then verifies fetched enum metadata, a keyed update, a typed equality filter,
the stored outer-domain type and an untouched SQL NULL row. See the
[four-domain-layer evidence](../evidence/postgres-four-level-domain-results-2026-10-04/manifest.json).

A five-level contract also checks enum-leaf metadata, a schema-aware keyed
edit, inferred query/update parameters, a typed filter and invalid-label
refusal while preserving the outer domain and a SQL NULL sibling. See the
[five-domain-layer evidence](../evidence/postgres-five-level-domain-results-2026-10-04/manifest.json).

A contract at depths 6, 7, 8, 9, 10, 63, 64, 65, 128, 129, 256, 260 and 300
checks recursive enum-leaf metadata under a session `search_path` shadowed by a
same-named enum, schema-aware keyed and draft writes (including SQL NULL), typed
equality filters and exact outer-domain type/value while preserving a SQL NULL
sibling. Separate follow-ups cover 257, 258 and 259 layers. A same-backend
transaction changes `search_path` twice and repeats typed writes/filtering with
previously fetched metadata; rollback leaves the original rows intact. Raw
inferred SQL NULL updates preserve the outer domain type and invalid labels
reach PostgreSQL through 63 layers. At depths 64, 65 and 128, raw inferred text
(valid and invalid) and SQL NULL return an explicit unsupported result even
after schema-aware work in the same-backend transaction. Selected
schema-aware operations pass through 4,096 layers under a shadowed path, while
raw inferred text/NULL contexts remain refused at the tested deep boundary;
domain depths beyond 4,096 and other enum/session configurations remain open.
The 302- and 512-level cases extend the same source contract at
[deep_domains.rs](../../crates/drivers/postgres/tests/support/domain_contract_parts/deep_domains.rs). See the
[301-layer evidence](../evidence/postgres-domain-301-level-results-2026-10-06/manifest.json),
[300-layer evidence](../evidence/postgres-domain-300-level-results-2026-10-05/manifest.json),
[deep-domain boundary evidence](../evidence/postgres-deep-domain-results-2026-10-04/manifest.json),
[129/256-layer follow-up](../evidence/postgres-deep-domain-followup-results-2026-10-04/manifest.json),
[domain-over-enum array parameter evidence](../evidence/postgres-domain-enum-array-parameter-results-2026-10-04/manifest.json),
[domain-over-enum array bounds evidence](../evidence/postgres-domain-enum-array-bounds-results-2026-10-04/manifest.json),
[six/seven-domain evidence](../evidence/postgres-seven-domain-results-2026-10-04/manifest.json),
[eight-domain follow-up](../evidence/postgres-eight-domain-results-2026-10-04/manifest.json)
and the [nine-domain follow-up](../evidence/postgres-nine-domain-results-2026-10-04/manifest.json),
plus the [six-domain checkpoint](../evidence/postgres-six-level-domain-results-2026-10-04/manifest.json).

An October 6 follow-up extends the same schema-aware contract through 301
domain layers, one beyond the previous checkpoint. It preserves enum-leaf
metadata, keyed writes, draft inserts, typed filters, SQL NULL siblings,
invalid-label refusal and rollback with a same-named shadow enum in
`search_path` ([301-layer evidence](../evidence/postgres-domain-301-level-results-2026-10-06/manifest.json)).
This is a tested boundary case, not a maximum-depth claim; deeper chains remain
open.

An October 8 follow-up runs the same schema-aware read, direct enum-domain
projection, keyed-write, draft/filter, invalid-label, NULL, and rollback contract
at 302 and 512 domain layers. It also projects an array of each outer domain,
checking the exact array value and `pg_typeof` metadata. The 512 case
stress-checks recursive metadata handling; neither point is a maximum-depth
claim ([test source](../../crates/drivers/postgres/tests/support/domain_contract_parts/deep_domains.rs)).

Scalar enum parameter contexts now have a native comparison at the 63/64-domain
boundary: `COALESCE` and `CASE` preserve PostgreSQL's inferred enum result type
and value for text labels, the literal `NULL` label, empty text and SQL NULL,
while the source column retains its outer domain type. The test runs with the
target schema absent from a `search_path` led by a same-named shadow enum
([test](../../crates/drivers/postgres/tests/support/domain_depth_boundary_contract.rs)).

A restricted PostgreSQL session now verifies enum parameter inference after
`SET ROLE` with a same-named shadow enum first in `search_path`. The target-only
label and SQL NULL retain the qualified target enum type; a shadow-only label
matches PostgreSQL's native `22P02` refusal, and target/shadow siblings remain
unchanged ([evidence](../evidence/postgres-enum-set-role-shadow-results-2026-10-06/manifest.json)).
A separate login-role contract verifies the role's configured default
`search_path` on a fresh connection, with a same-named shadow enum first; bound
target-only and SQL NULL values retain the qualified target type and shadow-only
labels match native `22P02` refusal
([evidence](../evidence/postgres-enum-role-default-search-path-results-2026-10-06/manifest.json)).

PostgreSQL custom-enum results now cover accepted 63-byte ASCII and multibyte
UTF-8 scalar and array labels plus refusal of a 64-byte label without partial type creation; see
the [accepted boundary](../evidence/postgres-enum-label-byte-boundary-results-2026-10-04/manifest.json)
and [refusal evidence](../evidence/postgres-enum-overlength-refusal-results-2026-10-04/manifest.json).
An ordering contract checks non-lexical enum sorting against `pg_enum.enumsortorder`
and native enum types ([ordering evidence](../evidence/postgres-enum-order-results-2026-10-04/manifest.json)).
Schema/type/table identifiers with spaces and embedded quotes pass metadata
discovery, a keyed edit and structured equality filtering with exact native
type and sibling-row checks; CSV import now also emits the escaped,
schema-qualified enum cast under a same-named shadow path and preserves the
target type and shadow row ([spaces evidence](../evidence/postgres-enum-quoted-identifiers-results-2026-10-04/manifest.json),
[CSV import evidence](../evidence/postgres-enum-csv-quoted-identifiers-results-2026-10-05/manifest.json),
[quote-escaping evidence](../evidence/postgres-enum-identifier-escaping-results-2026-10-04/manifest.json));
Unicode schema and type names also pass metadata lookup, keyed edit, draft
insert and structured filtering with native catalog checks
([Unicode evidence](../evidence/postgres-enum-unicode-identifiers-results-2026-10-05/manifest.json));
typed CSV import preserves the same Unicode-named target enum and SQL NULL/empty/literal-`NULL` distinctions
([CSV evidence](../evidence/postgres-enum-unicode-csv-import-results-2026-10-05/manifest.json));
the same-name target/shadow type collision also passes keyed edit and filtering
with the role's default `search_path` aimed at the shadow schema ([shadow-path evidence](../evidence/postgres-enum-shadowed-quoted-search-path-results-2026-10-04/manifest.json));
quoted-identifier CSV import also preserves the target enum under a transaction-local shadowed `search_path`, distinguishes SQL NULL from the literal `NULL`, and leaves the same-named shadow table unchanged ([CSV evidence](../evidence/postgres-enum-quoted-csv-shadow-results-2026-10-06/manifest.json));
mixed-case quoted schema/type names now also survive metadata lookup, keyed edits and structured filtering when lowercase-folded schema/type collisions appear earlier in `search_path`, with native catalog and untouched shadow-row checks ([case-fold collision evidence](../evidence/postgres-enum-mixed-case-identifiers-results-2026-10-07/manifest.json)); the same collision survives transaction-local `SET LOCAL search_path`: metadata, keyed update and typed filtering still target the quoted enum; a shadow-only label is refused with native `22P02`, target and shadow rows are checked, and commit restores the original session path ([transaction-local evidence and validation logs on PR #108](https://github.com/cozyGarage/BookiE/pull/108#issuecomment-6027211913)). The transaction-local contract now also passes when the target schema is omitted from `search_path`, reusing metadata fetched beforehand ([validation on PR #112](https://github.com/cozyGarage/BookiE/pull/112#issuecomment-6027345843)). Restricted-role session and login-default paths also omit the target schema: inferred query parameters, keyed updates, and filters stay bound to the qualified target type while shadow-only labels are refused ([validation on PR #114](https://github.com/cozyGarage/BookiE/pull/114#issuecomment-6027426272)). The mixed-case quoted target also stays bound under a restricted `SET ROLE` session when a lowercase folded shadow leads `search_path` and the target schema is absent, with native row/type equality and `22P02` refusal ([latest validation on PR #117](https://github.com/cozyGarage/BookiE/pull/117#issuecomment-6027700412)). Further identifier and transaction/session `search_path` permutations remain open.

The restricted-role enum case now combines `SET ROLE` with transaction-local
`SET LOCAL search_path`, a same-named shadow enum first in path, and an omitted
target schema. Typed updates and filters retain the qualified target type, a
shadow-only label is refused with native `22P02`, and the tests cover savepoint
recovery, committed writes, and restoration of the session path. The same
contract now includes a mixed-case quoted schema/type and a real keyed grid edit,
with SQL NULL sibling preservation
([tests](../../crates/drivers/postgres/tests/support/enum_role_context_contract.rs)).

The mixed-case transaction-local enum contract now also verifies rollback: a
typed update and filter run with the lowercase shadow first in `search_path`,
then rollback must restore both target rows and the original session path. The
same contract still checks committed writes and native shadow/type identity
([validation comment on PR #127](https://github.com/cozyGarage/BookiE/pull/127#issuecomment-6029039984)).

A restricted role that has schema and table privileges but no `USAGE` on the
custom enum can still select enum values, bind matching and SQL NULL filters,
and update the enum column. Native type/value checks and `22P02` invalid-label
refusal confirm PostgreSQL's value-query privilege semantics.

The PostgreSQL identifier boundary now has a focused regression at the 63-byte
catalog limit: a maximum-length schema and a maximum-length type ending in a
two-byte UTF-8 character must survive metadata discovery and a keyed enum edit,
with the stored catalog identity and sibling value checked natively. The
contract is `value_contract_postgres_enum_identifiers_at_catalog_byte_limit_preserve_typed_edits`
in `crates/drivers/postgres/tests/support/quoted_enum_identifier_contract.rs`.
Its Docker and local CI results are recorded in the [PR validation comment](https://github.com/cozyGarage/BookiE/pull/125#issuecomment-6028822115).
This closes only that identifier boundary; other identifier forms and
transaction/session `search_path` permutations remain open.

SQLite columns declared `ENUM` follow SQLite's NUMERIC affinity rather than a
constrained enum type. The runtime contract keeps text labels, numeric
INTEGER/REAL values, BLOB bytes and SQL NULL distinct against native
`typeof()`/`quote()` output. Grid and typed CSV input parse numeric-looking
values through the same affinity safeguards as declared NUMERIC columns and
refuse values that SQLite would store imprecisely
([driver test](../../crates/drivers/sqlite/tests/runtime_typed_values.rs), [grid
test](../../crates/app/src/ui/browse_tab/tests.rs), [CSV
test](../../crates/core/src/import/cell/tests/sqlite_affinity.rs)). `ANY` remains
on its conservative text path because metadata does not distinguish STRICT and
ordinary tables.

SQLite STRICT `ANY` table and direct query-result CSV now tag INTEGER,
REAL, TEXT and BLOB cells so a native import can retain their runtime storage
classes; SQL NULL uses the export's explicit collision-free marker. Untagged
text stays text, while a blank without a marker and malformed reserved tags are
refused. Both app round trips have a native `typeof()`/value oracle. Empty query
results retain their column metadata and CSV header. The `json_quote()` case
checks exact JSON text, confirms shared JSON export keeps `null` and numeric-looking
`7` as strings, and round-trips through STRICT `ANY` CSV ([test](../../crates/app/tests/support/sqlite_any_contract/aggregate_csv.rs)). Other computed-expression shapes beyond the
matrix above, attached-origin patterns and formats, and installed editing remain open;
see the
[table CSV case](value-contract-history.md#sqlite-strict-any-csv-storage-class-round-trip-2026-10-03)
and [query-result case](value-contract-history.md#sqlite-strict-any-query-result-csv-round-trip-2026-10-03).
See the [computed-expression case](../evidence/sqlite-computed-any-results-2026-10-04/manifest.json)
and [attached-origin case](../evidence/sqlite-attached-any-metadata-results-2026-10-03/manifest.json) for the tested fallback behavior.

Direct attached-schema origins now recover declared metadata when SQLite's
database list and schema-qualified table metadata identify one source. If a
main-schema table name with a dot collides with that flattened origin, metadata
stays at the original fallback. See the
[attached-origin evidence](../evidence/sqlite-attached-any-metadata-results-2026-10-03/manifest.json).

SQLite transaction queries now use the same streaming row and byte budget as
ordinary queries. A regression crosses the 64 MiB decoded-result limit, checks
ordered exact rows and `truncated`, then verifies the transaction can query
again ([test](../../crates/drivers/sqlite/tests/integration.rs)).

Rows identify work areas, not completed engine support. State the four ADR 0007
outcomes per concrete case. The older detailed matrix remains useful for lookup;
do not re-import its long case descriptions into this board.

