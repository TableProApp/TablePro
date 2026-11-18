# 0036: The MCP server and the command line cross the FFI

- **Status**: Accepted
- **Date**: 2026-11-18

## Context

`tablepro-mcp` serves the tools and `tablepro-cli` parses, calls and prints ([0018](0018-command-line.md)). The Linux app hosts both from `linux/crates/app`: it finds a connection's session through its windows, asks the user about a client's write there, keeps the token in the keyring, and checks each peer's user in `/proc/net/tcp`. The Windows app reaches the core only through `crates/ffi`, which exposed neither, `ConnectionRecord` dropped the saved External Clients level, and off Linux the server served any local account.

## Decision

- `Core::mcp_server(host, listener)` gives an `McpService`. `apply(enabled, port)` starts, moves or stops the server, each change serialized with Linux's generation and lock so a stop frees the port before the next start binds it. `status()` is Off, Starting, Running or Failed with an `ErrorInfo` (`mcp.port_in_use`, `mcp.listen_failed`, `mcp.no_randomness`, `mcp.interrupted` or a `secret.*` code); `seen_clients()` lists the clients since the last start; `McpListener` only signals a change.
- `access_token()` reads the token, or makes and keeps one first, whether or not the server runs; `regenerate_token()` replaces it and the running server refuses the old one from the next request. Credential Manager keeps one token per data folder, `TablePro/mcp-token/<digest of the folder>`, so a packaged and a development build, each with its own server, never share one; a host's own store keeps `SecretItem::McpToken`.
- The server reaches the sessions `connect_saved` opened: the core keeps each by saved id and the database it was opened in, weakly, and skips one that has shut down. A file opened without saving has no External Clients level and stays out.
- `McpAppHost` is the app's side, called on a thread the core lets block: `open_connection` opens a connection as Connect does, and the core then waits up to 10 seconds for its session while `is_connecting` holds, as Linux does; `approve` asks about a write in the connection's window and `withdraw` takes the question down when the client goes. A client's statement goes into the core's history under the editor's rules.
- `ConnectionRecord.external_access` reads back the saved level; on a save, None keeps the stored one.
- Off Linux the server checks each connection's peer with `tablepro_net::loopback_peer_is_this_user`: on Windows the owning process from `GetExtendedTcpTable`, opened for a limited query, and the user SID in its token against the server's own. A process this user cannot open, or one gone before the check, is refused.
- `tablepro-cli`'s `Host` gains `places()`, the app's names for its MCP settings and token store. Linux keeps Preferences > MCP and the keyring; the messages read the same there.
- `completion powershell` writes clap_complete's PowerShell script.
- The ffi package builds a `tablepro-cli` program beside the library: `command_line::main` classifies the arguments, runs a command with a Windows host, and hands files and links to `TablePro.exe` beside it. The host reads the data folder as the app resolves it, `mcpServerEnabled` and `mcpServerPort` from its `settings.json` and the folder's token from Credential Manager under the core's own name. The app writes its process id into `runtime\app.lock` in the data folder and holds the file open for writing, shared for reading; the command reads the app as running while no second writer can open it, and sends the token only to a listener that process owns, by `GetExtendedTcpTable`, and that runs as this user.

## Rationale

- The server, the token store and the session lookup in the core keep the tools, the access checks and the write question the same on both apps; the Windows app only shows the question and opens a workspace.
- Registering sessions in `connect_saved` needs no call from the app to keep a list in step: every saved connection the Windows app connects is a workspace's, and a closed one shuts down.
- The server's user check matches Linux's boundary: the same user can read the token from Credential Manager anyway.
- The command checks the process as well as the user: a packaged and a development build keep different data folders, and on a shared port the command of one would otherwise reach the other's connections.
- A console program of its own, since a WinUI app is a GUI program: a terminal neither waits for one nor gives it its console. Built from the ffi package, it reads the token through the same Credential Manager code and ships through the same copy into the app's folder as the library.

## Consequences

- A client run as administrator while TablePro is not can be refused, since its process may not be opened for the check.
- The data folder rule and the two settings names now have a reader in Rust as well as in the app; `windows/tests/TablePro.App.Model.Tests` pins the names the program reads.
- Setting a client up from the catalog ([0023](0023-mcp-client-setup-from-one-catalog.md)) stays Linux's: the catalog has no Windows entries and the install code is in `linux/crates/app`.
