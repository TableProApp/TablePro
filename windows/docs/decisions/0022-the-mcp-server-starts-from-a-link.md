# 0022: The MCP server starts from a link

- **Status**: Accepted
- **Date**: 2026-11-20

## Context

[0018](0018-links-files-notifications-type-editors-and-json.md) left `tablepro://integrations/start-mcp`, `integrations/pair` and `tablepro://import` opening nothing. The app now runs the MCP server ([0019](0019-mcp-server-and-command-line.md)). On macOS, the MCP bridge opens `start-mcp` when it finds no server running, and the app starts its server unless Settings has it off, with nothing on screen.

## Decision

- The core reads `tablepro://integrations/start-mcp` as `AppLink::StartMcpServer`, `AppLink.StartMcpServer` here, and ignores what follows the action, as macOS does. Any other `integrations` action is `link.malformed_path`.
- The link starts the server again when Settings has it on and its last start failed, as Try again does. A running server keeps its clients, and one that Settings has off stays off. The link shows nothing either way, as on macOS.
- A link handed to the running app that only starts the server does not bring the window forward. A launch it starts shows the window, as any launch does.

## Rationale

- macOS's `MCPServerManager.lazyStart` skips a running server and refuses one turned off; starting again on every link would drop the clients it serves.
- A WinUI app that opened no window would run with nothing on screen to quit it from.

## Consequences

- `integrations/pair` opens nothing: pairing a client needs the scoped tokens and the code exchange that the core's MCP server does not issue yet (roadmap A-09).
- `tablepro://import` still opens nothing. Keeping every field the macOS link carries (Verify CA, the six Safe Mode levels, an SF Symbol icon) changes `SavedConnection`, `TlsMode`, `SafeModeLevel` and `ConnectionIcon`, which `linux/crates/app` builds field by field and matches variant by variant, so it waits on the Linux app's 0.1.0 release.
