# 0021: Engines without SQL keep the driver contract and say what they hold

- **Status**: Accepted; amended by 0024
- **Date**: 2026-10-23

## Context

Every engine before Redis spoke SQL, and the contract assumed it: the sidebar listed schemas and tables, a table tab paged through `SqlDialect`, and the editor split, gated, completed and recorded text through `SqlGrammar`'s SQL lexer and sqlparser. Redis holds numbered databases of keys, each a typed value, and takes one command per line. MongoDB, next on the roadmap, holds collections of documents and takes neither SQL nor Redis commands.

## Decision

An engine without SQL implements the same `DatabaseDriver`, `Connection` and `EditorSession`, and says what it holds through `DriverCapabilities::data_model`; its keys come from `Connection::scan_keys` and `read_key`, its language is a `SqlGrammar` variant with its own rules beside the SQL ones, and a read-only connection it cannot hold at the server is held by the driver's check of each command (`ReadOnlyEnforcement::ClientGuard`).

## Rationale

- The contract's hard parts are the same for any engine: calls owned past their caller, a stop the server acts on, a link the session can watch, one connection per editor tab, backpressure into a sink, streams from the transport and TLS on aws-lc-rs. Keeping one contract keeps all of that, and its conformance cases, for the new engine.
- Keys are data, not a catalogue: a database can hold millions, they change with every write, and only the server can match a pattern over all of them. They are listed by a call of their own that stops at a limit and says so, rather than cached by the session's catalog as schemas and tables are.
- A grammar variant reaches every place the editor reads a language (the split, Safe Mode's gate, the history check) through the match the compiler already makes exhaustive, so nothing that reads SQL can miss the new language. The variant has no SQL rules and no sqlparser dialect, so nothing parses commands as SQL.
- `Connection::dialect()` still returns a dialect, because the editor reads the grammar and the history check from one; its SQL builders refuse, and the app never reaches them on a key-value connection.

## Consequences

- `DriverCapabilities` has `data_model` and `username_required`, `Connection` has `scan_keys` and `read_key` with defaults that return `Unsupported(Keys)`, and `ReadOnlyEnforcement` has `ClientGuard`. Every relational driver states `Relational`.
- The workspace reads `data_model` once: a key-value session's sidebar sends its search to the server, a key opens in a key tab, and the editor has no SQL highlighting, completion, formatter or comment toggle.
- `keyspace_conformance_suite!` is the key-value engines' contract test, beside the TLS suite; the SQL suites do not apply to them.
- `adding-drivers.md`, Engines without SQL, is the recipe. A document engine adds its own `DataModel` variant and listing, and reuses the grammar, dialect and read-only rules.

## Alternatives considered

- **Keys as tables.** Listing each key as a table and generating SQL for a page would have reused the browse tab, but every builder would need a fake SQL spelling for commands, a key's value has no columns until its type is known, and a pattern over millions of keys cannot be a catalogue read.
- **A second contract for non-SQL engines.** A separate trait set would have duplicated the call ownership, stops, liveness and editor rules, and every surface of the app would have needed two paths.
- **A separate editor language type beside `SqlGrammar`.** Cleaner in name, but every reader of `SqlGrammar` would have had to take a second type, and a reader that forgot would have parsed commands as SQL without the compiler saying so.
