# 0018: One command line for the apps on the core

- **Status**: Accepted
- **Date**: 2026-11-08

## Context

The macOS app has a Swift command that uses its MCP server. Linux needs the same
shell commands, and Windows will need them too. Parsing, output and exit codes
should not depend on a GUI toolkit. Finding the running app and reading its token
still depend on the platform.

## Decision

Put the command line in `core/crates/cli` (`tablepro-cli`). It owns argument
classification and parsing, help, completion scripts, the MCP client, connection
lookup, request deadlines, output and exit codes. It has no GUI or platform crate
dependency. Database work stays in the app's MCP server, under its access checks,
write approval and row limits.

Each app calls `classify` before GUI startup. It passes commands to `run`, with a
`Host` and output streams. Files, URLs and GUI options return to the app, with a
leading `open` removed. Unknown targets return an error. Linux startup, URL
handling and packaging are decided in [Linux 0045](../../../linux/docs/decisions/0045-command-line-and-connection-urls.md).

The `Host` supplies the app version, whether the app is running, the MCP setting
and port, a token read, peer verification and terminal flags for all three standard
streams. Linux supplies these through its session bus, settings, keyring and
socket owner check. macOS keeps its Swift command and pairing flow. Windows must
supply its own host when it adopts the crate.

### Command contract

Keep the command surface and output formats aligned with the macOS command.
Authentication and opening connections remain platform choices.

| Command | Work |
| --- | --- |
| `[URL\|FILE]...`, `open` | Hand targets to the app |
| `query -c <name\|id>` | Run SQL from an argument, `--file` or standard input |
| `connections` | List connections visible to the client |
| `databases`, `schemas`, `tables` | List objects for a connection |
| `describe <table> [--ddl]` | Show structure or the CREATE statement |
| `export <table>... --format csv\|json\|sql` | Export through the server |
| `status` | Report readiness and try the MCP handshake when possible |
| `completion bash\|zsh\|fish`, `help`, `-h`, `--help`, `--version` | Work without contacting the app |

Rows use CSV, TSV, JSON, JSONL or a text table. The default is a table when standard
output is a terminal, CSV otherwise. Writers preserve numeric text, distinguish
NULL from an empty string in CSV, and nest multiple JSON result sets in one
document. Notes go to standard error. Table cells escape control characters;
terminal diagnostics keep line breaks and tabs but escape other controls.

The exit numbers match macOS. The crate maps failures as follows:

| Status | Meaning |
| --- | --- |
| 0 | Success, including a broken output pipe |
| 1 | Database, transport, host or output failure; missing token; connection not open |
| 2 | Usage error, unknown or ambiguous connection, or `invalid_argument` |
| 3 | Server disabled, token refused, `denied` or `user_cancelled` |
| 4 | Request deadline or tool `timeout` |

The five-minute wait for a connection to open returns 1 if it expires. Request
deadlines return 4. A query retries after `not_connected` only with `--read-only`,
since a write may already have run.

### Parser and authentication

Use clap's derive parser for help, usage errors and suggestions. Generate bash,
zsh and fish completions from that same definition with clap_complete. This keeps
parsing, help and completion together without maintaining each by hand.

Linux reads the server's existing token and has no pairing step. Programs running
as that user can already read it from the keyring. Pairing would grant access the
command already has. Creating a token in the command would not update the running
server. A stopped app or disabled server is reported before reading the token,
including for `status`.

Use rmcp's Streamable HTTP client at `127.0.0.1:<port>/mcp`, with proxies and
redirects disabled. A reqwest connector layer calls `Host::verify_peer` on every
new TCP connection before HTTP can send the bearer token. Missing socket
addresses or a failed check close that connection. A separate probe would leave
a gap in which another process could take the port. Verified connections can be
reused. The later MCP handshake must also name the server `tablepro`. rmcp reads
at most 16 MiB of one answer; a larger one fails with a message to ask for fewer
rows.

On Linux, verification checks the peer socket's owner against the current user.
It does not prove the process is TablePro. That user is the boundary because the
same user can read the token.

Keep help and diagnostics written by the crate in English. The core has no
translation catalog, and shell output should not change with the desktop locale.
Host and command errors retain their `code()` values.

## Consequences

- Linux and Windows can share command behavior without sharing a GUI. macOS keeps
  a separate Swift implementation, including `pair` and `unpair`.
- Windows needs an MCP server, argument dispatch and a `Host` for app state,
  settings, Credential Manager, terminal detection and peer verification. The
  existing Windows socket helper accepts only the current process. It cannot
  verify a separate app process as written. PowerShell completion also remains
  to be added.
- Messages currently name Linux settings such as Preferences > MCP. Another app
  must account for its own settings names when adopting the crate.
- Commands remain subject to server limits. Query and export report truncation;
  they do not fetch the rest of a result automatically.
- Connection lookup uses only the server's visible list, even for IDs. Optional
  tool fields are omitted when unset, so older servers need not know them.

## Alternatives considered

- **A parser in each app on the core.** It repeats the command contract and its
  tests. Platform differences fit in `Host` and the GUI handoff.
- **A hand-written Rust parser.** Help, suggestions and completions would need
  separate code and could drift from the accepted arguments.
- **Direct database access or another IPC interface.** It duplicates work and
  authorization already provided by MCP.
- **Verify the port once before connecting.** It checks a different socket from
  the one that sends the token and misses later connections.
- **Generic output writers.** The command needs the macOS format, including CSV
  empty-string quoting, table layout and one JSON document for multiple results.
