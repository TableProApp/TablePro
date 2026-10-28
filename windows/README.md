# TablePro Windows

Native Windows database client, the Windows sibling of the macOS TablePro app. It is written in C# on .NET 10 with WinUI 3 (Windows App SDK 2.6) and follows Fluent Design: acrylic or Mica window material, the system theme brushes, Segoe Fluent Icons and the Windows type ramp. It shares no code with the macOS or Linux apps.

## Status

In development. Nothing is released yet: no `windows-v*` tag exists. [ROADMAP.md](ROADMAP.md) compares it with the macOS app feature by feature and lists what is not built.

It connects to all 37 engines of the macOS app, across the relational, analytical, cloud warehouse, document, key-value, wide-column, search, streaming, coordination and file families, from PostgreSQL, MySQL, SQL Server, SQLite and DuckDB to Redis, MongoDB, ClickHouse, Oracle, Cassandra, Snowflake, BigQuery, Elasticsearch and Kafka. ROADMAP.md lists each engine and its limits.

## Requirements

- Windows 10 version 2004 (build 19041) or later, x64 or Arm64. Acrylic and Mica need Windows 11; Windows 10 shows a solid window.
- To build: the .NET 10 SDK (`global.json` pins 10.0.100 with `latestFeature` roll-forward) and the Windows 10 SDK 10.0.26100. Visual Studio is not needed.

## Install

Each release on [GitHub Releases](https://github.com/TableProApp/TablePro/releases), tagged `windows-v*`, has three ways in. All of them keep your data in `%LOCALAPPDATA%\TablePro`, so you can move from one to another.

- **MSIX.** Open `TablePro-<version>.msixbundle`, or install from the App Installer link `https://updates.tablepro.app/windows/TablePro.appinstaller` (beta: `TablePro-beta.appinstaller`). Windows keeps it up to date.
- **winget.** `winget install TableProApp.TablePro`. Add `--installer-type zip` on a PC that cannot install MSIX packages.
- **Zip.** Unzip `TablePro-<version>-x64.zip` (or `-arm64`) and double-click `Install.cmd`. It installs for your account only, with no administrator rights, into `%LOCALAPPDATA%\Programs\TablePro`, adds TablePro to the Start menu and to Settings > Apps > Installed apps. You can also run `TablePro.exe` straight from the unzipped folder.

## Updates

TablePro checks `https://updates.tablepro.app/windows/feed.json` a few seconds after launch and then once a day, and on **Check for Updates**. It works like the macOS app's updater:

- Two channels. Stable gets stable releases. Beta gets betas and the stables after them.
- A stable reaches everyone within 36 hours, in 7 groups 6 hours apart. Checking by hand skips the wait.
- **Skip This Version** silences one release until a newer one ships. A critical release, a security or data-loss fix, ignores both the wait and the skip.

How it installs depends on how you installed:

| Installed with | Update |
|---|---|
| Zip and `Install.cmd` | Downloads the new zip, checks its size and SHA-256 against the feed, then runs its `install.ps1`, which waits for TablePro to close, swaps the folder and starts the new version. |
| Zip, run from the folder | Opens the download page. TablePro never rewrites a folder it did not install. |
| MSIX file | Downloads the new MSIX, checks it the same way, and opens it in App Installer. |
| App Installer link or winget MSIX | Windows checks on every launch and in the background. TablePro shows what is waiting and restarts to apply it. The link you installed from sets the channel. |

Debug builds never update. Setting `TABLEPRO_UPDATE_FEED` to an HTTPS URL points a build at a test feed and turns updates on in a Debug build. An administrator turns updates off with the registry value `DisableUpdates` = 1 (DWORD) under `HKLM\Software\Policies\TablePro` or `HKCU\Software\Policies\TablePro`.

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

An unsigned MSIX package, written to `src/TablePro.App/bin/msix/`:

```powershell
dotnet publish src/TablePro.App -c Release -r win-x64 -p:TableProPackage=msix
```

On Windows 11, `Add-AppxPackage -AllowUnsigned <file>.msix` installs it for testing. Without the property every build stays unpackaged.

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
| Update channel, last check, skipped version | `%LOCALAPPDATA%\TablePro\updates.json` |
| A downloaded update, until the next launch | `%LOCALAPPDATA%\TablePro\updates\` |

Connections export to, and import from, the macOS app's portable file. Exports never contain passwords.

## SSH tunnels

TablePro runs the OpenSSH client that ships with Windows (`ssh.exe`), as the Linux app runs the system one. Your `~/.ssh/config`, `known_hosts` and the OpenSSH agent apply. Password and passphrase logins go through a small helper, `TablePro.SshAskPass.exe`, that ssh calls; the secret reaches it in an environment variable set for that one child process. Every ssh process is placed in a Job Object, so it ends with the app even after a crash.

## Privacy

TablePro sends no telemetry. Its one request of its own is the update check: it reads the feed from `updates.tablepro.app` and, when you install an update, downloads it from GitHub. The request carries the app version and architecture in its User-Agent and nothing else. Turn automatic checks off in Settings, or with the policy under Updates. Otherwise it connects to the database servers and SSH hosts you set up. With an AI provider chosen in Settings, it sends that provider what the assistant needs: your question, the SQL it acts on and the structure of the tables involved, and only from connections whose AI setting allows it. It never sends rows. With the MCP server on, it listens on `127.0.0.1` for MCP clients on this computer.

## MCP server

Turn on **Settings > MCP > Enable MCP server**, then add it to a client. With Claude Code:

```bash
claude mcp add --transport http tablepro http://127.0.0.1:23508/mcp --header "Authorization: Bearer <access token>"
```

The settings page shows the address and the token and copies the whole command. Each connection's **External clients** level decides what a client may do: Blocked hides the connection, Read only allows reads, Read and write asks you to approve each write in the connection's window.

## Releasing

A tag on a `main` commit with a green CI run publishes a release. Tags never move, so check the version before the tag leaves the machine.

- A stable is `windows-vX.Y.Z`, a beta `windows-vX.Y.Z-beta.N` with N from 1 to 98. There is no `-rc`.
- The MSIX version is `X.Y.Z.N` for a beta and `X.Y.Z.99` for a stable, so Windows orders packages as the app orders versions.
- `Directory.Build.props` keeps `0.1.0` for local builds; the tag sets the version of a release.

```bash
git fetch origin --tags
gh run list --workflow ci.yml --branch main --event push --commit <commit>
git tag -s windows-v0.2.0-beta.1 -m windows-v0.2.0-beta.1 <commit>
git push origin windows-v0.2.0-beta.1
gh run watch "$(gh run list --workflow release-windows.yml --limit 1 --json databaseId -q '.[0].databaseId')" --exit-status
```

`release-windows.yml` then:

1. Checks the tag and that its commit is on `main`.
2. Builds x64 and arm64 with `windows/packaging/build-release.ps1`: the zip with `install.ps1`, `uninstall.ps1` and `Install.cmd`, and the MSIX.
3. Signs the executables, the scripts, the MSIX packages and the bundle when the signing certificate is set, and says in the log when it is not.
4. Creates the GitHub release with the zips, the MSIX packages, the bundle and `SHA256SUMS`. A beta is a prerelease, and the repository's latest release stays the macOS one.
5. For a stable, fills the winget manifests from `windows/packaging/winget/` into the `winget-manifests` artifact. Submitting them is a manual step: [packaging/winget/README.md](packaging/winget/README.md).
6. Adds the release to `windows/feed.json` on `gh-pages`, rewrites the `.appinstaller` files and deploys the site to `updates.tablepro.app`.

To build the same files locally, unsigned:

```powershell
./packaging/build-release.ps1 -Version 0.2.0-beta.1 -Architecture x64
./packaging/build-release.ps1 -Version 0.2.0-beta.1 -Architecture arm64
./packaging/bundle-msix.ps1 -Version 0.2.0-beta.1 -Directory artifacts/release
```

### Setup

Once, by a repository admin:

- An environment `windows-release`, limited to `windows-v*` tags, with the secrets `WINDOWS_CERTIFICATE` (the code signing `.pfx` in base64) and `WINDOWS_CERTIFICATE_PASSWORD`. The variable `WINDOWS_PUBLISHER` is needed only when the MSIX Publisher must differ from the certificate subject as .NET prints it.
- `windows-v*` added to the tags the `github-pages` environment allows, and to the tag ruleset only admins may create.

### When a run fails

Nothing reaches users before the `publish` job. An infrastructure failure is `gh run rerun <run id> --failed`. A code failure is fixed on `main` and ships as the next number. If `publish` created the release and a later job failed, re-run the failed jobs: `update-feed.ps1` replaces the release's own entry, so a second run is safe.

## Documentation

| Topic | File |
|---|---|
| Projects, dependency rules, threading, the data grid and the editor | [ARCHITECTURE.md](ARCHITECTURE.md) |
| Feature parity with the macOS app | [ROADMAP.md](ROADMAP.md) |
| Rules for working in this folder | [AGENTS.md](AGENTS.md) |
| winget manifests and how a release fills them | [packaging/winget/README.md](packaging/winget/README.md) |

## License

AGPL-3.0-or-later, as the parent TablePro project: see [LICENSE](../LICENSE).
