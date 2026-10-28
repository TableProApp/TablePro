# TablePro Windows

Native Windows database client, the Windows sibling of the macOS TablePro app. It is written in C# on .NET 10 with WinUI 3 (Windows App SDK 2.6) and follows Fluent Design: acrylic or Mica window material, the system theme brushes, Segoe Fluent Icons and the Windows type ramp. It shares no code with the macOS or Linux apps.

## Status

In development. Nothing is released yet: no `windows-v*` tag exists. [ROADMAP.md](ROADMAP.md) compares it with the macOS app feature by feature and lists what is not built.

It connects to 34 engines across the relational, analytical, cloud warehouse, document, key-value, wide-column, search, streaming and coordination families, from PostgreSQL, MySQL, SQL Server, SQLite and DuckDB to Redis, MongoDB, ClickHouse, Oracle, Cassandra, Snowflake, BigQuery, Elasticsearch and Kafka. ROADMAP.md lists each engine and its limits.

## Requirements

- Windows 10 version 2004 (build 19041) or later, x64 or Arm64. Acrylic and Mica need Windows 11; Windows 10 shows a solid window.
- To build: the .NET 10 SDK (`global.json` pins 10.0.100 with `latestFeature` roll-forward) and the Windows 10 SDK 10.0.26100. Visual Studio is not needed.

## Build and run

From `windows/`:

```powershell
dotnet build TablePro.slnx
dotnet run --project src/TablePro.App
```

The app is unpackaged and self-contained: `src/TablePro.App/bin/Debug/net10.0-windows10.0.26100.0/win-x64/TablePro.exe` runs from its folder with no installer and no separate runtime.

A Release build for distribution:

```powershell
dotnet publish src/TablePro.App -c Release -r win-x64
```

The XAML compiler is a .NET Framework tool and fails on paths longer than 260 characters. Clone to a short path such as `C:\src\TablePro` if the build reports "XamlCompiler output file was not created".

## Test

```powershell
dotnet test TablePro.slnx
```

The suites run without a database server: Core, Storage, SSH, AI and MCP are unit tests, and the SQLite and DuckDB driver suites run against real temporary database files. The network drivers have unit tests for their connection settings, DDL, request building and result mapping, the HTTP ones against a fake handler. Each driver suite also holds integration tests that run only when an environment variable names a live server, such as `TABLEPRO_REDIS=host:port`; the test files list them.

## Where things are kept

| What | Where |
|---|---|
| Saved connections and groups | `%LOCALAPPDATA%\TablePro\connections.json` |
| Passwords, SSH secrets, AI keys, the MCP token | Windows Credential Manager, under `TablePro/...` |
| Settings | `%LOCALAPPDATA%\TablePro\settings.json` |
| Query history | `%LOCALAPPDATA%\TablePro\history.db` (SQLite with full-text search) |
| Favorites | `%LOCALAPPDATA%\TablePro\favorites.json` |

Connections export to, and import from, the macOS app's portable file. Exports never contain passwords.

## SSH tunnels

TablePro runs the OpenSSH client that ships with Windows (`ssh.exe`), as the Linux app runs the system one. Your `~/.ssh/config`, `known_hosts` and the OpenSSH agent apply. Password and passphrase logins go through a small helper, `TablePro.SshAskPass.exe`, that ssh calls; the secret reaches it in an environment variable set for that one child process. Every ssh process is placed in a Job Object, so it ends with the app even after a crash.

## Privacy

TablePro makes no network requests of its own: no telemetry and no update check. It connects to the database servers and SSH hosts you set up. With an AI provider chosen in Settings, it sends that provider what the assistant needs: your question, the SQL it acts on and the structure of the tables involved, and only from connections whose AI setting allows it. It never sends rows. With the MCP server on, it listens on `127.0.0.1` for MCP clients on this computer.

## MCP server

Turn on **Settings > MCP > Enable MCP server**, then add it to a client. With Claude Code:

```bash
claude mcp add --transport http tablepro http://127.0.0.1:23508/mcp --header "Authorization: Bearer <access token>"
```

The settings page shows the address and the token and copies the whole command. Each connection's **External clients** level decides what a client may do: Blocked hides the connection, Read only allows reads, Read and write asks you to approve each write in the connection's window.

## Documentation

| Topic | File |
|---|---|
| Projects, dependency rules, threading, the data grid and the editor | [ARCHITECTURE.md](ARCHITECTURE.md) |
| Feature parity with the macOS app | [ROADMAP.md](ROADMAP.md) |
| Rules for working in this folder | [AGENTS.md](AGENTS.md) |

## License

AGPL-3.0-or-later, as the parent TablePro project: see [LICENSE](../LICENSE).
