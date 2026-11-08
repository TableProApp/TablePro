# 0017: One command line for the apps on the core

- **Status**: Accepted
- **Date**: 2026-11-08

## Context

The macOS app ships a `tablepro` command: Swift, a hand-written parser, `query` and `connections` over the app's MCP server, and a pairing step for its token. The Linux app had none; `tablepro` was only the GTK application. The maintainer asked for one command surface on macOS and Linux, with Windows next. The macOS command stays Swift; Linux and Windows build on the core.

## Decision

`core/crates/cli` (`tablepro-cli`) is the command line of every app on the core: the parser, help, completion scripts, the MCP client, the output formats and the exit status. It depends on no GUI and no platform crate. The app passes a `Host` (its version, whether it runs, whether its MCP server is on, the port, whether the port's listener is its own, the token, which streams are terminals), asks `classify` whether argv is the command line's, and calls `run`.

| Command | Tool |
| --- | --- |
| `tablepro [URL\|FILE]...`, `open` | none: `classify` hands them to the app |
| `query -c <name\|id> [SQL]`, `-f`, `--database`, `--format`, `--limit`, `--timeout`, `--read-only` | `execute_query` |
| `connections` | `list_connections` |
| `databases`, `schemas`, `tables` | `list_databases`, `list_schemas`, `list_tables` |
| `describe <table> [--ddl]` | `describe_table`, `get_table_ddl` |
| `export <table>... --format csv\|json\|sql` | `export_data` |
| `status` | none, or `initialize` once the rest holds |
| `completion bash\|zsh\|fish`, `help`, `--version`, `-h` | none |

Exit status, as the macOS command documents it: 0 done; 1 the database failed, TablePro is not running or does not answer, another program holds the port, or the output could not be written; 2 usage, an unknown or hidden connection, `invalid_argument`; 3 the MCP server is off, the token is refused, `denied`, `user_cancelled`; 4 `timeout`, or no answer within the command's deadline.

## How it works

- **Dispatch.** `classify` gives the command line argv whose first word is a subcommand other than `open`, `help`, `-h`, `--help` or `--version`, and `open` with `-h` or `--help`. Everything else goes back to the app with a leading `open` taken off. A bare word that is neither a URL with a scheme nor an existing path is refused with exit 2, so a mistyped or future command never opens as a file (clig.dev, "Don't have a catch-all subcommand").
- **Reaching TablePro.** Nothing is sent until the app runs, its server is on, the host confirms the port's listener belongs to this user, and a token exists. Another user can bind the port before TablePro does, and the app still holds its bus name and the setting stays on, so naming the server after the handshake is too late. On Linux a probe connection's peer is looked up in `/proc/net/tcp`; this user is the boundary, since this user can read the token from the keyring anyway. The token is read last, so a refusal never asks the keyring to unlock, and `status` reads it only where a command would. The client is rmcp's over Streamable HTTP to `127.0.0.1:<port>/mcp`, with the bearer token, no proxy, and `clientInfo` `tablepro-cli`, titled Command Line. A server that does not name itself `tablepro` is refused.
- **Deadlines.** The handshake waits 15 s, a tool call 60 s, an export 60 s for each table, and `execute_query` its timeout (the server's 30 s by default) plus 120 s for the write question TablePro may ask first. Past a deadline the command tells the server to drop the call and exits 4, so a stalled server or app never holds a script. The wait for `connect` is bounded as a whole.
- **One connection lookup.** `list_connections`, then the id, the exact name, the name in any case. A connection hidden from clients is unknown by name and by id alike; two that match list their ids.
- **A closed connection.** `connect` opens a window in the app, so the command calls it only when standard error is a terminal, says so on one line, and polls for five minutes. A script gets exit 1. A tool that answers `not_connected` for a connection listed as open gets one `connect` and one retry, then its message and exit 1, since a database the window does not hold answers the same after `connect`. A statement is retried only with `--read-only`: the connection can drop after the server ran a write.
- **Output.** csv, tsv, json, jsonl and table, written as the macOS command writes them (`CLIRowWriter.swift`), `table` on a terminal and `csv` otherwise. A number keeps the digits the server sent. Table columns line up by terminal cell. A control character is escaped in a table cell and in every line written to a terminal's standard error. The server's notes (a rolled-back transaction, values written as null, result sets left out) go to standard error; its row-limit note is said in the command's own words, naming `--limit`.
- **Arguments.** An option the user left out is not sent, since the tools refuse a field they do not know.

## Rationale

- **clap.** A maintained crate does the job ([Linux 0005](../../../linux/docs/decisions/0005-supply-chain-policy.md)); clap 4.6 was already in the lock through uniffi. Its derive gives help, `help <command>`, suggestions and exit 2 for a usage error, the code GNU tools, Python's argparse and the macOS command use. clap_complete writes static bash, zsh and fish scripts; its runtime completion is still behind an unstable feature. `--version` alone prints `tablepro <app version>`, as swift-argument-parser does on macOS.
- **No pairing outside macOS.** On Linux the server's one token sits in the user's Secret Service, which any program of that user can read, and a Flatpak command runs as the same app with the same portal secret ([Linux 0022](../../../linux/docs/decisions/0022-ai-assistant-and-mcp-server.md), [Linux 0044](../../../linux/docs/decisions/0044-command-line-and-connection-urls.md)). Pairing would hand the command a token as wide as the one it can already read. The command reads it and never makes one: a token it made would be one the running server never accepts.
- **English only.** The core holds no catalog (`core/AGENTS.md`, Principles 5). Scripts match on this text, the docs quote it, and the macOS command prints the same English. Each error still has a `code()`.
- **Writers of our own.** The csv crate leaves an empty field bare in a record of several fields, where the documented format quotes it to keep it apart from NULL, and comfy-table draws other borders than the macOS table. Each writer is a few lines, pinned by tests against the macOS output.

## Consequences

- The Linux binary dispatches before any GUI setup, and its `--help` is the command line's, in English (Linux 0044).
- Windows passes a `Host` over its Credential Manager once it has an MCP server, and adds PowerShell completion then. Its `verify_server` needs an owner check of its own: the core's Windows answer compares the listener's process with the caller's.
- The macOS command keeps its own Swift code with the same surface, plus `pair` and `unpair`; a later slice can move it here.
- `export` and `query` stop at the server's row cap, 1,000 per result on Linux, and say so on standard error.
- The messages name the Linux menus, such as Preferences > MCP, until another app uses the crate.

## Alternatives considered

- **A hand-written parser, as macOS had.** No help, completion or suggestions without writing each, and Linux 0005 asks for a crate.
- **A second binary for the commands.** Flatpak exports one command per app, and packages would put a second name on `PATH`.
- **The app's own D-Bus interface instead of MCP.** A second copy of the tools the server already has.
- **One JSON array per result set, one after another, as sqlite3 and DuckDB print them.** The macOS command nests several sets in one array, and the formats stay the same on both.
