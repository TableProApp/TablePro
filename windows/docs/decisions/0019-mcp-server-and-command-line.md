# 0019: The MCP server, External clients and the tablepro command

- **Status**: Accepted
- **Date**: 2026-11-18

## Context

The macOS and Linux apps run an MCP server that AI clients on the same computer reach, with an External Clients level per connection, a question in the app before a client's write, and a `tablepro` command over the same server. The core now carries the server, its token and its session lookup across the FFI, and builds the command as a program of its own ([core 0036](../../../core/docs/decisions/0036-mcp-and-the-command-line-through-the-ffi.md)).

## Decision

- Settings has an MCP server section after the AI assistant: Enable MCP server, off on a new install as on the other apps; Status, Off, Starting..., Running on port N or why it did not start, with Try again; Port, 23508 by default, 1024 to 65535; Address with Copy address; Authorization header with Copy header, which reads the token from Credential Manager only to copy it, and Regenerate token..., which asks first with Cancel the default; Clients, each one that connected since the server started.
- The server runs from launch while the setting is on and stops as the app gives up its data folder, before the next launch takes it over.
- The connection form's Options has External clients: Blocked, Read only or Read and write, each with what it lets clients do. A new connection starts at Read only, and a save that leaves it alone keeps the stored one.
- A client's write brings the window of the connection forward and asks in a ContentDialog over its workspace, "Run statement from MCP client?", with the statement and Cancel the default, whatever the Safe Mode level. The question waits for any other dialog, and comes down unanswered when the client goes.
- A client that asks to connect opens the connection as Connect on the Connections page does, in the primary window; one whose connect failed is brought forward and the client is told it did not open.
- The package's `tablepro.exe` alias names a second, console Application over `tablepro-cli.exe`, hidden from Start. A command runs there and prints; files and links start `TablePro.exe` with them, which hands over to a running app. The app holds `runtime\app.lock` in its data folder while it runs, which the command reads as the app running.

## Rationale

- Stock controls: SettingsCard, SettingsExpander, ToggleSwitch, NumberBox, ComboBox and ContentDialog, as the AI section uses them.
- The token is shown nowhere, so a screenshot or a screen share of Settings never carries it; the header is what a client's configuration takes.
- A console program for the command, since a terminal neither waits for a WinUI program nor gives it its console.

## Consequences

- Client setup from the shared catalog, as Linux offers it, waits on the catalog's Windows entries and on its install code moving into the core.
- An unpackaged build has no alias: `tablepro-cli.exe` beside `TablePro.exe` is run by its path.
- A launch that takes over the data folder right as the last one quits can find the port still held; Try again starts it.
