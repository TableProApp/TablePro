# 0023: Both apps set up MCP clients from one catalog

- **Status**: Accepted
- **Date**: 2026-11-12

## Context

Both apps run a local MCP server, and each AI client needs an entry that points at it. The macOS app printed a snippet for four clients from two hand-written lists and read nothing back; the Linux app offered the address and the token to copy ([#4196](https://github.com/TableProApp/TablePro/issues/4196)). Each client keeps its servers its own way: a JSON, JSON with comments, TOML or YAML file, a command of its own, or a deeplink. Paths differ by OS, and some clients run on one OS only.

## Decision

Both apps read one catalog, `core/crates/mcp/clients.json`, and set a client up through the first method it offers: its deeplink, its CLI, a merge into its config file, else a copy to paste.

### The catalog

- Bundled with each app, never fetched. The Rust crates take it through `include_str!` in `tablepro_mcp::clients`; the macOS app ships it as a resource and decodes it in `TableProMCPClients`.
- Each client has an id, its brand name, an icon slug, the `clientInfo` names it connects with, and per OS its detect rules, entry template, install methods in priority order and when the change applies. A client with no entry for an OS is not listed there.
- No sentences: a status or a reason is a code, which each app words in its own catalog.

### Install order

1. **Deeplink**, offered only when an app handles its scheme. The Linux app offers none.
2. **The client's CLI**, such as `claude mcp add`, run argument by argument, never through a shell, and never inside the Flatpak, which cannot start host programs. On Linux the token goes through argv only for Claude Code, which takes a header no other non-interactive way.
3. **A merge into the client's config file**: a text splice that keeps comments, key order and indentation and touches only TablePro's entry; Codex's TOML only as a `[mcp_servers.tablepro]` table. In an entry already there it writes over only what reaches TablePro: the members whose catalog value holds a placeholder at any depth, such as `headers.Authorization`, plus `type` and `args`. Any other member the catalog names, such as `tools` or `disabled`, is written only where the entry lacks it, so an update never widens a restriction the user set. An entry for the other transport, a `command` where a `url` goes or the reverse, is replaced whole. A symlink is written through and stays a link. The file as it was is kept as `<file>.tablepro-backup`, replaced on each write. A new file is created 0600. Refused when the file cannot be read or parsed, names a key twice, or the catalog marks it not writable, as for YAML and the files a client's own CLI manages.
4. **Copy**, always offered: the command or the fragment, with the token where the entry needs one.

### What counts as set up

- The entry at the catalog's key path, or at an `alternateKeyPaths` one, an older layout of the same file, compared with what TablePro would write: the bridge on macOS, the port and the token on Linux.
- An entry the client turned off, with `"disabled": true`, `"enabled": false` or TOML `enabled = false`, is set up but off whatever its command, address or token, and offers no install or update.
- An entry where an HTTP one goes that still names a `command` is stale, since the client may start that program and never read the address.
- A stale entry in an `otherScopes` scope, such as a Claude Code project's own, makes the client stale even when the user's entry is current, since the client uses it there first.

### What the entry holds

- macOS: every entry starts the app's stdio bridge, so no token is written anywhere.
- Linux: there is no bridge ([Linux 0022](../../../linux/docs/decisions/0022-ai-assistant-and-mcp-server.md)), so the entry holds the URL and an `Authorization` header with the token, in a file only the user can read. TablePro narrows `~/.claude.json` to the user too after `claude mcp add` writes it.
- The Linux server serves a connection only when the socket at its other end belongs to the user TablePro runs as, read from `/proc/net/tcp` and `/proc/net/tcp6`, and refuses it with 403 when it belongs to another account or cannot be found. So a token another account reads, from a file or from a command line, does not work from that account.

### Brand marks

- Simple Icons files, published under CC0, or, where it has none, the brand's own published file, used as shipped and never redrawn.
- They stay their owners' trademarks and only name the client. A file under another license is listed with its notice in the app's third-party notices.

## Consequences

- A new client or a moved path is one edit to the catalog, and each app's tests render every entry for its OS.
- TablePro writes other apps' files. A file it cannot edit without losing something is left alone, and the copy still works.
- A client that changes its file layout or its CLI breaks the install until the catalog follows.
- On Linux the token is in the client's file, as it was when pasted by hand, and in Claude Code's argv while `claude mcp add` runs, where another account can read it. It works only from the user's own account. Regenerate leaves every written copy stale; while the server runs, the page offers Update.
- Where `/proc/net/tcp` cannot be read, the Linux server refuses every client, and logs it once.
- A client the server cannot reach, such as Claude Desktop on Linux, which starts only stdio servers, is listed with the reason and no action.

## Alternatives considered

- **A list in each app.** The paths and the entries are the same facts on both, and two lists drift.
- **A catalog fetched from the network.** What TablePro writes into another app's file would change without a release.
- **Parsing and rewriting the file with a JSON or TOML library.** It drops comments and reorders keys in a file the user owns.
- **Running the CLI through a login shell to find it.** The user's profile runs on every install and every argument needs quoting; the macOS process launcher refuses an app-authored shell.
- **Writing `~/.claude.json` for Claude Code on Linux.** The CLI owns that file and rewrites it while it runs.
