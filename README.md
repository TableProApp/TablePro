<p align="center">
  <img src=".github/assets/logo.png" width="128" height="128" alt="TablePro">
</p>

<h1 align="center">TablePro</h1>

<p align="center">
  Native database apps for macOS, iPhone, iPad and Linux.<br>
  Free and open source.
</p>

<p align="center">
  <a href="https://tablepro.app">Website</a> ·
  <a href="https://docs.tablepro.app">Docs</a> ·
  <a href="https://github.com/TableProApp/TablePro/releases">Download</a> ·
  <a href="https://discord.gg/hCNmUUbnD4">Discord</a>
</p>

<p align="center">
  <a href="https://github.com/TableProApp/TablePro/releases"><img src="https://img.shields.io/github/v/release/TableProApp/TablePro" alt="Release"></a>
  <a href="https://www.gnu.org/licenses/agpl-3.0"><img src="https://img.shields.io/badge/License-AGPL_v3-blue.svg" alt="License: AGPL v3"></a>
</p>

<p align="center">
  <a href="README.vi.md">Tiếng Việt</a>
  <a href="README.zh.md">简体中文</a>
  <a href="README.ko.md">한국어</a>
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

TablePro is a free, open-source database client with a native app for each platform. Browse data, write queries and edit rows in SQL and NoSQL databases.

Apple apps use Swift and native frameworks. Linux uses Rust, GTK 4 and libadwaita. Windows uses C# and WinUI 3 and is in development. Linux and Windows build on the shared Rust core; the Swift app does not use it yet.

## Why TablePro

Database clients today fall into three groups:

- **Single-database, open source**: Sequel Ace (MySQL only), Postico (PostgreSQL only). Great if you live in one engine.
- **Multi-database, closed source**: TablePlus. Polished and native, but proprietary.
- **Multi-database, not native**: DBeaver (JVM), Beekeeper Studio and DBGate (Electron). Cross-platform, but slow to start and heavy on memory.

TablePro is the missing fourth: native on every platform, multi-database, and open source.

## Platforms and installation

| Platform | Status | Install |
|---|---|---|
| macOS 13+ | Stable | `brew install --cask tablepro` or [GitHub Releases](https://github.com/TableProApp/TablePro/releases) |
| iPhone / iPad, iOS / iPadOS 18+ | Stable | [iPhone and iPad guide](https://docs.tablepro.app/ios) |
| Linux, amd64 / arm64 | Public beta | [Ubuntu beta PPA, Fedora beta COPR or beta Flatpak repository](https://docs.tablepro.app/linux/install) |
| Windows | In development | [Source and build guide](windows/AGENTS.md#commands) |

Linux native packages need GNOME 50 libraries: Ubuntu 26.04 / 26.10 uses `ppa:tablepro/tablepro-beta`, and Fedora 44 / 45 uses `@tablepro/tablepro-beta`. Other distributions use the beta Flatpak repository. Follow the [Linux install guide](https://docs.tablepro.app/linux/install) for setup and updates. Packages are also on [GitHub Releases](https://github.com/TableProApp/TablePro/releases).

## Supported databases

Support differs by platform. The linked guides own the full lists and limits.

| Platform | Databases |
|---|---|
| macOS | PostgreSQL, MySQL, MariaDB, SQLite, Redis, MongoDB, SQL Server and more. Built-in drivers and signed plugins; see the [database catalog](https://tablepro.app/databases) and [plugin guide](https://docs.tablepro.app/features/plugins). |
| iPhone / iPad | Includes PostgreSQL, MySQL, MariaDB, SQLite, DuckDB, Redis, MongoDB and SQL Server. Drivers ship with the app; see [mobile database support](https://docs.tablepro.app/ios#supported-databases). |
| Linux | 11 engines: PostgreSQL, MySQL, MariaDB, SQL Server, ClickHouse, Cassandra, ScyllaDB, SQLite, DuckDB, Redis and MongoDB. See [supported servers and versions](linux/README.md#supported-servers). |
| Windows | In development over the [shared core's drivers](core/ARCHITECTURE.md#crate-layout). No released app yet. |

## Features

- Query editors, data browsing and row editing.
- SSH tunnels and SSL/TLS connections.
- Saved queries and query history.
- On Mac and Linux: autocomplete, multi-cursor editing and Vim mode.
- On Mac: split panes and driver plugins.
- On Mac and Linux: AI assistance with your own provider or Ollama, and an MCP server for local clients.
- On iPhone and iPad: browse and edit data, with optional iCloud sync for connections and saved queries.

See the [Mac feature guide](https://docs.tablepro.app/features/overview), [Linux guide](linux/README.md) and [iPhone and iPad guide](https://docs.tablepro.app/ios) for what each app supports.

## Free and paid

The database tools above are free on every supported database, with no trial period or time limit. Pro and Team add paid features on the Mac. Linux uses the same plans and account; a license covers up to 3 computers, Mac or Linux. Features differ by platform: see [plans and prices](https://tablepro.app/pricing) and [Linux accounts](linux/README.md#tablepro-account). The iPhone and iPad app needs no license.

## Build and contribute

Each platform keeps its setup, build and test instructions beside its source:

- [macOS and iOS](apple/CONTRIBUTING.md).
- [Linux](linux/README.md#quickstart).
- [Windows](windows/AGENTS.md#commands), with [packaging and release instructions](windows/RELEASING.md).
- [Shared Rust core](core/AGENTS.md#commands) and [architecture](core/ARCHITECTURE.md).

Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## Docs and community

- [Documentation](https://docs.tablepro.app) for setup and daily use.
- [GitHub Discussions](https://github.com/TableProApp/TablePro/discussions) or [Discord](https://discord.gg/hCNmUUbnD4) for questions and ideas.
- [Issues](https://github.com/TableProApp/TablePro/issues) for bugs. Include the platform, app version and Linux install source when relevant.
- [Security policy](SECURITY.md) for private vulnerability reports, and [Code of Conduct](CODE_OF_CONDUCT.md) for community standards.

## Support development

Buying a [license](https://tablepro.app/pricing) or [sponsoring the project](https://tablepro.app/sponsors) funds development. You can keep using the free version without buying either.

## Sponsors

TablePro is funded by its users and these sponsors. [Become a sponsor](https://tablepro.app/sponsors).

<p>
  <a href="https://coderabbit.link/tablepro"><img src=".github/assets/sponsors/coderabbit.svg" height="44" alt="CodeRabbit"></a>
  <a href="https://simplelocalize.io?ref=tablepro"><img src=".github/assets/sponsors/simplelocalize.svg" height="44" alt="SimpleLocalize"></a>
  <a href="https://getnimbus.io?ref=tablepro"><img src=".github/assets/sponsors/nimbus.svg" height="44" alt="Nimbus"></a>
  <a href="https://dwarves.foundation?ref=tablepro"><img src=".github/assets/sponsors/dwarves-foundation.svg" height="44" alt="Dwarves Foundation"></a>
  <a href="https://pyto.com?ref=tablepro"><img src=".github/assets/sponsors/pyto.svg" height="44" alt="Pyto"></a>
</p>

Individual sponsors: [朱文锦](https://github.com/zhuwjin)

## Contributors

Thanks to everyone who has contributed to TablePro:

<a href="https://github.com/TableProApp/TablePro/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=TableProApp/TablePro" alt="TablePro contributors" />
</a>

Want to join them? Read [CONTRIBUTING.md](CONTRIBUTING.md).

## Star History

<a href="https://www.star-history.com/?repos=TableProApp%2FTablePro&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=TableProApp/TablePro&type=date&theme=dark&legend=top-left&sealed_token=rD14Ce48qCR6mXTi0zio-abLAcluGQrDOorFBPL8DAMnUeVFYI8giJJ8arDwTaB8BgpJfk3Y2y5hpIiAu4SBOg6e1_nW8xZ7OrTOFi7ykoGvxk30ycgvzwHW4E-skW0jp5QGttP1QvGgeu5xFrkVbvFa1OFSo_JwWr557R6RNg2hDXdFD7v7nwf_VnR1" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=TableProApp/TablePro&type=date&legend=top-left&sealed_token=rD14Ce48qCR6mXTi0zio-abLAcluGQrDOorFBPL8DAMnUeVFYI8giJJ8arDwTaB8BgpJfk3Y2y5hpIiAu4SBOg6e1_nW8xZ7OrTOFi7ykoGvxk30ycgvzwHW4E-skW0jp5QGttP1QvGgeu5xFrkVbvFa1OFSo_JwWr557R6RNg2hDXdFD7v7nwf_VnR1" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=TableProApp/TablePro&type=date&legend=top-left&sealed_token=rD14Ce48qCR6mXTi0zio-abLAcluGQrDOorFBPL8DAMnUeVFYI8giJJ8arDwTaB8BgpJfk3Y2y5hpIiAu4SBOg6e1_nW8xZ7OrTOFi7ykoGvxk30ycgvzwHW4E-skW0jp5QGttP1QvGgeu5xFrkVbvFa1OFSo_JwWr557R6RNg2hDXdFD7v7nwf_VnR1" />
 </picture>
</a>

## License

This project is licensed under the [GNU Affero General Public License v3.0 or later (AGPL-3.0-or-later)](LICENSE). The TablePro name and icon are covered separately by [TRADEMARKS.md](TRADEMARKS.md).
