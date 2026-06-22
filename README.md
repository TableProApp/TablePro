<p align="center">
  <img src=".github/assets/logo.png" width="128" height="128" alt="TablePro">
</p>

<h1 align="center">TablePro</h1>

<p align="center">
  A fast, native database client for developers.<br>
  Free and open source.
</p>

<p align="center">
  <a href="https://tablepro.app">Website</a> ·
  <a href="https://docs.tablepro.app">Docs</a> ·
  <a href="https://github.com/TableProApp/TablePro/releases">Download</a> ·
  <a href="https://discord.gg/hCNmUUbnD4">Discord</a>
</p>

<p align="center">
  <a href="https://github.com/TableProApp/TablePro/releases/latest"><img src="https://img.shields.io/github/v/release/TableProApp/TablePro" alt="Release"></a>
  <a href="https://www.gnu.org/licenses/agpl-3.0"><img src="https://img.shields.io/badge/License-AGPL_v3-blue.svg" alt="License: AGPL v3"></a>
</p>

<p align="center">
  <a href="README.vi.md">Tiếng Việt</a>
  <a href="README.zh.md">简体中文</a>
</p>

<p align="center">
  <a href="https://trendshift.io/repositories/24114" target="_blank"><img src="https://trendshift.io/api/badge/repositories/24114" alt="TableProApp%2FTablePro | Trendshift" style="width: 250px; height: 55px;" width="250" height="55"/></a>
</p>

---

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/app-dark.png">
    <source media="(prefers-color-scheme: light)" srcset=".github/assets/app-light.png">
    <img alt="TablePro database client with SQL editor and data grid" src=".github/assets/app-light.png" width="800">
  </picture>
</p>

## About

TablePro is what I wanted TablePlus to be: native, fast, open source.

Built with native frameworks on every platform. No Electron, no JDBC, no JavaScript runtime. Cold start under 1 second, idle around 80 MB RAM. Connects to all major SQL and NoSQL databases through native drivers.

AI is built in: chat, inline suggestions, and an MCP server that lets Cursor, Raycast, or Claude Desktop talk to your databases. Bring your own API key, pick your own provider, or run local with Ollama.

## Why TablePro

Native macOS database clients today fall into three groups:

- **Single-database, open source**: Sequel Ace (MySQL only), Postico (PostgreSQL only). Great if you live in one engine.
- **Multi-database, closed source**: TablePlus. Polished and native, but proprietary.
- **Multi-database, not native**: DBeaver (JVM), Beekeeper Studio and DBGate (Electron). Cross-platform, but slow to start and heavy on memory.

TablePro is the missing fourth: native, multi-database, and open source.

## Platforms

| Platform | Status |
|----------|--------|
| macOS 14+ | Stable |
| iOS / iPadOS 18+ | Stable |
| Linux | In development |

## Supported Databases

| Database | Distribution |
|----------|--------------|
| MySQL | Built-in |
| MariaDB | Built-in |
| PostgreSQL | Built-in |
| Amazon Redshift | Built-in |
| CockroachDB | Built-in |
| SQLite | Built-in |
| ClickHouse | Built-in |
| Redis | Built-in |
| Microsoft SQL Server | Plugin |
| MongoDB | Plugin |
| Oracle Database | Plugin |
| DuckDB | Plugin |
| Cassandra / ScyllaDB | Plugin |
| Etcd | Plugin |
| Cloudflare D1 | Plugin |
| DynamoDB | Plugin |
| BigQuery | Plugin |
| libSQL / Turso | Plugin |

Built-in drivers ship with the app. Plugin drivers install on demand from the [plugin registry](https://github.com/TableProApp/plugins).

## What's inside

- SQL editor with autocomplete, multi-cursor, Vim mode, syntax themes
- Data grid with inline editing, sort, filter, undo/redo
- Native window tabs, multi-window, split panes
- SSH tunnels with password and key authentication, SSL/TLS
- Query history with full-text search
- iCloud sync for connections, groups, tags, settings, and SSH profiles
- AI chat, inline suggestions, and Explain/Optimize
- MCP server and URL scheme for Raycast, Cursor, Claude Desktop
- Plugin system, write your own database driver in Swift

## Install

```bash
brew install --cask tablepro
```

Or download from [GitHub Releases](https://github.com/TableProApp/TablePro/releases).

## How to Build

Building TablePro requires macOS 14 or later and Xcode 15 or later.

Run the first-time setup from the repository root:

```bash
scripts/download-libs.sh
touch Secrets.xcconfig
```

Build a Debug app without code signing:

```bash
xcodebuild \
  -project TablePro.xcodeproj \
  -scheme TablePro \
  -configuration Debug \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The app is written to `~/Library/Developer/Xcode/DerivedData/TablePro-*/Build/Products/Debug/TablePro.app`.

To build and run a signed app, configure your personal Apple team, a unique bundle identifier, and the Debug entitlements in Xcode. See [Building with a personal Apple team](CONTRIBUTING.md#building-with-a-personal-apple-team) for the required settings.

## Documentation

Full docs at [docs.tablepro.app](https://docs.tablepro.app).

## Support development

The app is free under AGPLv3. If you use TablePro at work, please buy a [license](https://tablepro.app). Every purchase funds the next release. If you can't afford one, just use the free version. That's why it's free.

## Sponsors

Thanks to these amazing people for supporting TablePro:

**[SimpleLocalize](https://simplelocalize.io?ref=tablepro)** · **[CodeRabbit](https://coderabbit.ai?ref=tablepro)** · **[Nimbus](https://getnimbus.io?ref=tablepro)** · **[Visnalize](https://visnalize.com?ref=tablepro)** · **[Dwarves Foundation](https://dwarves.foundation/?ref=tablepro)** · **[Huy TQ](https://github.com/imhuytq)** · **[Xermius](https://xermius.com?ref=tablepro)** · **[Unikorn](https://unikorn.vn?ref=tablepro)**

## Star History

<a href="https://www.star-history.com/?repos=TableProApp%2FTablePro&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/image?repos=TableProApp/TablePro&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/image?repos=TableProApp/TablePro&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/image?repos=TableProApp/TablePro&type=date&legend=top-left" />
 </picture>
</a>

## License

This project is licensed under the [GNU Affero General Public License v3.0 (AGPLv3)](LICENSE).

Contributions require signing a Contributor License Agreement (CLA). See [CLA.md](CLA.md) for details.
