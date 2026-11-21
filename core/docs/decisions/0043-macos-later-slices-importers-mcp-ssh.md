# 0043: Importers, the MCP server and SSH move with the macOS app's later slices

- **Status**: Accepted; amends 0010
- **Date**: 2026-11-21

## Context

[0010](0010-macos-on-the-core.md) moves the macOS app to the core in five slices: the library, the connections, history and saved queries, the script reader, then engines. Three pieces exist in Swift and in the core, and none of the five covers them:

- **Importers from other apps.** The Mac's own under `apple/TablePro/Core/Services/Export/ForeignApp/`, with their review in `TableProImport`; the core's `tablepro-foreign-import` ([0008](0008-importers-from-other-apps.md)), which the FFI exposes ([0033](0033-foreign-import-and-result-editing-through-the-ffi.md)) and which reads DBX's key ([0039](0039-dbx-passwords-from-its-key.md)). The core already fixes defects the Swift copy keeps (0008, Consequences).
- **The MCP server.** The Mac's `Core/MCP` and `TableProMCP`; the core's `tablepro-mcp` behind `Core::mcp_server` ([0036](0036-mcp-and-the-command-line-through-the-ffi.md)).
- **SSH.** The Mac's libssh2 stack in `Core/SSH`, a second one in the iOS app, and the core's `tablepro-ssh` ([0009](0009-in-process-ssh-on-windows.md)). Both Apple apps keep the host keys a user trusted in a `known_hosts` file of their own, one `[host]:port type base64` line each, through one `HostKeyStore` in `TableProSSHTransport`.

## Decision

Each moves in a slice of its own, after the slice that holds what it works on:

6. **Importers, after slices 2 and 3.** `apply()` writes connections into the core's library and saved queries into the history's store (0033), so the Mac takes the review once both live there. It reads through `Core::foreign_sources`, `read_foreign` and `ForeignImportReview`, with a host whose `keychain()` reads another app's keychain items after the user allows it, DBX's key among them (0039).
7. **The MCP server, after slice 5.** `Core::mcp_server` reaches only sessions that `connect_saved` opened (0036), so its tools see a Mac connection once that engine runs in the core, and the slice waits for the last engine: one port cannot serve two servers. The Mac passes an `McpAppHost` that opens a connection as Connect does and asks about a write in the connection's window, and keeps the token in the Keychain through `HostSecrets`. Its stdio bridge and client setup stay as [0023](0023-mcp-client-setup-from-one-catalog.md) has them.
8. **SSH, with each engine in slice 5.** An engine that moves opens its tunnel through `tablepro-ssh`'s in-process transport, which the iOS app can use too since it cannot start a process (0009). The host passes the app's own `known_hosts` as the file the transport reads and adds trusted keys to, so a host trusted before the move stays trusted and the previous release still reads what the core wrote. The libssh2 stacks go with the last Swift engine.

As each slice ships, its Swift copy and that copy's tests are deleted in the same change.

## Rationale

- Each piece follows its data: an import writes library rows and saved queries, the MCP tools act on sessions, and a tunnel belongs to the driver that dials through it.
- Moving a piece before its data would bridge the core to a Swift store and back, one more seam to keep in step.
- One known-hosts file per app keeps the trust a user already gave; `HostKeyStore` made it one Swift type, so the core has one format and two paths to read.

## Consequences

- Until a slice ships, a fix to its piece lands twice: in Rust for Linux and Windows, in Swift for the Mac.
- The Mac has no DBX importer until slice 6 (0039, Consequences).
- Every MCP change before slice 7 is Swift's alone, since the Mac's tools cannot reach a core session before slice 5.
- `tablepro-ssh` gains a known-hosts path the host names, beside `~/.ssh/known_hosts`, when slice 8 starts.

## Alternatives considered

- **Importers first, writing through a bridge into the Swift library.** The review's duplicate handling and its write lock live in the core library (0008); a Swift library would need both again.
- **The core's MCP server for the engines already moved, the Swift one for the rest.** Two servers on one port, or two ports for one app.
- **Trusting `~/.ssh/known_hosts` alone after the move.** Every host a user trusted in the app would prompt again, and the iOS app has no such file.
