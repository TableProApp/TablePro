# Value contract rules by type

The choices behind [ADR 0007](decisions/0007-type-and-value-preservation.md), grouped by the kind of value they protect. Each rule names the failure that produced it and where the record is. The [value evidence index](value-contracts.md) maps cases to tests; the dated history is in the [value contract history](archive/value-contract-history.md). A rule here binds a new driver or consumer the same way ADR 0007 does.

## Rules that apply to every engine

- **Typed first, exact text only past the carrier.** Keep the typed value while the carrier holds it. Fall back to exact text only when the value is real and the carrier cannot represent it, for example a decimal wider than Rust `Decimal`.
- **Refuse over a wrong value.** A cell the driver cannot decode exactly becomes `Undecodable`, not a rounded or guessed value. Refusal also covers the write side: a writer that cannot hold a value says so, naming the row and column, and leaves the destination untouched.
- **Never substitute a different literal.** An SQL export that writes `/* ... omitted */ NULL` for a value it cannot represent produces executable SQL with a different value. Refuse instead ([upstream movement review](archive/upstream-linux-movement-2026-10-18.md), section 7).
- **Absent is not null.** A missing source field stays distinguishable from an explicit NULL, and a distinguishable cell cannot be rebound as an explicit null.
- **Empty text follows the SQL mode.** Any path that restores a value (CSV import, keyed grid edit, SQL-file export) must write empty text as empty, not NULL, in every supported mode. MariaDB's `EMPTY_STRING_IS_NULL` mode needs `SPACE(0)` for empty ENUM, SET and character columns.
- **Display is never the source of truth.** A truncated or labelled display value is not read back for editing ([state management](state-management.md#anti-patterns-to-flag-in-review)).

## Temporal

- **Offset-bearing types are not normalized to UTC.** SQL Server `datetimeoffset` stays exact text in CSV import, because the shared UTC `TimestampTz` would discard the stored offset ([history, 2026-10-01](archive/value-contract-history.md#sql-server-datetimeoffset-csv-import-2026-10-01)).
- **Lossy carriers refuse first, then use exact text.** Legacy SQL Server `datetime` has 1/300-second ticks. Only ticks that are exact in nanoseconds stay typed. The others use the server's exact style-126 text. A regression must use inexact ticks (`.997`, `.003`), not `.990`, which is an exact tick.
- **A named time zone is resolved by rule, never guessed.** ClickHouse named-zone `DateTime64` returns a local wall clock with no offset. The decoder applies IANA rules and refuses a daylight-saving gap or fold.
- **Session state is part of the proof.** MySQL `TIMESTAMP` is exact only in a UTC session, because the server returns a session-local wall time and `sqlx` decodes it as UTC. Driver-owned pool connections set `+00:00` on creation and reset it at each checkout. If a dedicated session later changes zone, non-NULL cells are `Undecodable`, not a wrong instant.

- **Refuse out-of-range values before the server can clamp them.** ClickHouse 24.8 accepts `1899-12-31 23:59:59.999999999` for `DateTime64(9)` but clamps it to year 1900, and returns an error above `2262-04-11 23:47:16.854775807`. BookiE refuses both as parameters and SQL literals. A caller's raw SQL can still hit the server's clamp, which cannot be undone from the result ([history, 2026-09-29](archive/value-contract-history.md#clickhouse-datetime649-server-boundary-behavior-2026-09-29)).
- **Choose the coarsest exact scale.** The renderer picks the smallest `DateTime64` scale that keeps every supplied fractional digit and fits the server calendar and 64-bit ticks, so `DateTime64(0)` accepts year 2299. Forcing scale 9 wrongly refused it.
- **Nanosecond values bind as exact text where the driver binding truncates.** The pinned DuckDB crate returns only six fractional digits for native `TIME` and `TIMESTAMP` nanosecond parameters, so the adapter binds exact `VARCHAR`. The caller must cast it explicitly in a typed expression.

## Numeric

- **Never decode money through a float.** SQL Server `money` and `smallmoney` travel as `f64` in the TDS client and lose digits (`123456789012345.6789` read as `.67`). Non-NULL cells are `Undecodable`; NULL stays NULL.
- **Wide decimals use the declared metadata.** The typed CSV fallback accepts a plain numeric text only when the value fits the destination's declared precision and scale and `Decimal` cannot hold it. Over-precision input, malformed metadata and an unspecified `decimal` stay errors.
- **XLSX floats are numeric only when exact in Excel.** A finite float is a numeric cell only if its shortest decimal has at most 15 significant digits and is within Excel's range. Otherwise it is an exact text cell, which keeps the sign of negative zero. This trades spreadsheet arithmetic for exact retention ([history, 2026-10-02](archive/value-contract-history.md#xlsx-float-precision-and-excel-safe-cell-types-2026-10-02)).

## Text and export formats

- **XML keeps carriage returns.** CR is written as `&#13;` so standalone CR and CRLF survive. XML-illegal characters are refused, not replaced with U+FFFD.
- **Spreadsheet-safe CSV is not reversible.** The formula-protection prefix makes `=1+1` and `'=1+1` collide, so raw export is the lossless path and the dialog says so. The NULL marker starts at `\N` and grows until no value collides.

## SQLite

- **A STRICT `ANY` edit keeps the cell's runtime kind.** The grid parses an edit with the existing cell's kind: INTEGER stays integer, REAL stays real, TEXT stays text. A new or NULL cell stores nonempty input as TEXT, even when numeric-looking, because there is nothing to preserve and the grid must not guess a conversion. Clearing existing TEXT stores empty TEXT, not NULL.

## MongoDB

- **A missing field is `Undecodable("missing BSON field")`, not `Null`.** No general missing-value type was added ([history, October 3](archive/value-contract-history.md#mongodb-missing-fields-remain-distinct-from-bson-null-october-3)).

- **A sample is not a census.** MongoDB sampled metadata and type merging over fetched pages do not prove collection-wide export coverage. Verify late fields across export boundaries before claiming it ([upstream main review](archive/upstream-main-review-2026-10-03.md), U6).

## When you add a rule

Write the failing test first, take the expected value from the engine ([test design rules](test-design-rules.md)), and add the rule here with its source heading. A rule that only restates ADR 0007 does not belong here.
