# TablePro

Open and search your TablePro database connections from Raycast. Browse schema, run queries, and let Raycast AI use TablePro tools.

TablePro is a native macOS database client. This extension talks to a running TablePro app over a local MCP server. No credentials are passed through Raycast.

## Setup

1. Install TablePro 0.6 or later from [tablepro.app](https://tablepro.app).
2. Run the **Pair with TablePro** command in Raycast.
3. TablePro shows an approval sheet. Choose the scope (read-only by default), pick which connections this token can reach, and approve.
4. The token lands in this extension's preferences. You're done.

The MCP server starts on demand. You don't need to enable it manually.

## Commands

- **Search Connections** — list saved connections, open one in TablePro, copy a deep link.
- **Open Connection** — `Open Connection prod` from the Raycast root.
- **TablePro Menu Bar** — show recent connections and quick actions in the menu bar.
- **Search Schema** — drill into databases and schemas across connections.
- **Search Tables** — pick a connection, list tables, copy DDL, open a table tab.
- **Recent Tabs** — show tabs currently open in TablePro and reopen one.
- **Run Query** — paste SQL, pick a connection, see the first 50 rows in Raycast or open the full grid in TablePro. Mutating queries ask before running.
- **Search Query History** — full-text search across the TablePro query history.
- **Pair with TablePro** — issue or refresh the API token.

## AI tools

The extension exposes 10 tools to Raycast AI:

- `list-connections`, `list-databases`, `list-schemas`, `list-tables`, `describe-table`, `get-table-ddl`
- `run-query` — mutating SQL goes through `Tool.Confirmation` with the connection name and SQL preview
- `explain-query`, `open-connection-window`, `search-history`

Try `@tablepro show me users in prod` or `@tablepro how big is the orders table on staging`.

## Permissions and access control

Each TablePro connection has an external-access setting (Blocked, Read-only, Read & Write). Tokens are issued with their own scope. The actual permission is the minimum of the two. A full-access token against a read-only connection cannot mutate.

If TablePro returns 403 for a write query, the extension surfaces the error verbatim. Change the connection's external access in TablePro under the connection editor.

## Pairing flow

The pairing flow uses PKCE so the local TablePro app and the extension agree on a token without ever sharing it through a URL.

1. Raycast generates a verifier (32 random bytes) and a SHA-256 challenge.
2. Raycast opens `tablepro://integrations/pair?...` with the challenge and a `raycast://` callback.
3. TablePro shows the approval sheet. On approve, TablePro mints a one-time code and opens the callback.
4. The extension exchanges code plus verifier for the token at `POST http://127.0.0.1:<port>/v1/integrations/exchange`.
5. The token is stored in the extension's preferences (Keychain-backed).

The exchange endpoint takes no auth. The single-use code is the auth.

## Privacy

- Connection metadata (`name`, `host`, `port`, `type`) is read from `~/Library/Application Support/com.TablePro/connections.json`.
- Passwords are never read by the extension. They live in the TablePro Keychain.
- Query results are fetched on demand from the local MCP server. Nothing leaves your machine.

## Troubleshooting

- **TablePro is not installed** — install from tablepro.app or set the path in extension preferences.
- **TablePro is not running** — open TablePro. The MCP server starts on first request.
- **API token was revoked** — run Pair with TablePro again.
- **Pairing got stuck** — close the Pair window and start the command again. The pending verifier is cleared each run.
