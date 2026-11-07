<p align="center">
  <img src=".github/assets/logo.png" width="128" height="128" alt="TablePro">
</p>

<h1 align="center">TablePro</h1>

<p align="center">
  适用于 macOS、iPhone、iPad 和 Linux 的原生数据库应用。<br>
  免费且开源。
</p>

<p align="center">
  <a href="https://tablepro.app">Website</a> ·
  <a href="https://docs.tablepro.app">文档</a> ·
  <a href="https://github.com/TableProApp/TablePro/releases">下载</a> ·
  <a href="https://discord.gg/hCNmUUbnD4">Discord</a>
</p>

<p align="center">
  <a href="https://github.com/TableProApp/TablePro/releases"><img src="https://img.shields.io/github/v/release/TableProApp/TablePro" alt="Release"></a>
  <a href="https://www.gnu.org/licenses/agpl-3.0"><img src="https://img.shields.io/badge/License-AGPL_v3-blue.svg" alt="License: AGPL v3"></a>
</p>

<p align="center">
  <a href="README.vi.md">Tiếng Việt</a>
  <a href="README.md">English</a>
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
    <img alt="TablePro 数据库客户端的 SQL 编辑器和数据表格" src=".github/assets/app-light.png" width="800">
  </picture>
</p>

## 关于

TablePro 是我心目中的 TablePlus:原生、快速、开源。

TablePro 是免费的开源数据库客户端，每个平台都有原生应用。可以浏览数据、编写查询，以及编辑 SQL 和 NoSQL 数据库中的行。

Apple 应用使用 Swift 和原生框架。Linux 使用 Rust、GTK 4 和 libadwaita。Windows 使用 C# 和 WinUI 3，目前正在开发。Linux 和 Windows 基于共享的 Rust 核心；Swift 应用尚未使用该核心。

## 为什么选 TablePro

目前数据库客户端可分三类:

- **单数据库,开源**:Sequel Ace(仅 MySQL)、Postico(仅 PostgreSQL)。只用一种引擎的话很合适。
- **多数据库,闭源**:TablePlus。流畅且原生,但是专有软件。
- **多数据库,非原生**:DBeaver(JVM)、Beekeeper Studio 和 DBGate(Electron)。跨平台,但启动慢且占内存。

TablePro 补上缺失的第四类:每个平台都原生、多数据库、开源。

## 平台与安装

| 平台 | 状态 | 安装 |
|---|---|---|
| macOS 13+ | 稳定版 | `brew install --cask tablepro` 或 [GitHub Releases](https://github.com/TableProApp/TablePro/releases) |
| iPhone / iPad，iOS / iPadOS 18+ | 稳定版 | [iPhone 和 iPad 指南](https://docs.tablepro.app/ios) |
| Linux，amd64 / arm64 | 公开测试版 | [Ubuntu 测试版 PPA、Fedora 测试版 COPR 或测试版 Flatpak 仓库](https://docs.tablepro.app/linux/install) |
| Windows | 开发中 | [源码与构建指南](windows/AGENTS.md#commands) |

Linux 原生安装包需要 GNOME 50 库：Ubuntu 26.04 / 26.10 使用 `ppa:tablepro/tablepro-beta`，Fedora 44 / 45 使用 `@tablepro/tablepro-beta`。其他发行版使用测试版 Flatpak 仓库。安装和更新步骤见 [Linux 安装指南](https://docs.tablepro.app/linux/install)。安装包也可从 [GitHub Releases](https://github.com/TableProApp/TablePro/releases) 获取。

## 支持的数据库

各平台的支持范围不同。完整列表和限制见对应指南。

| 平台 | 数据库 |
|---|---|
| macOS | PostgreSQL、MySQL、MariaDB、SQLite、Redis、MongoDB、SQL Server 等。使用内置驱动和已签名插件；见[数据库目录](https://tablepro.app/databases)和[插件指南](https://docs.tablepro.app/features/plugins)。 |
| iPhone / iPad | 包括 PostgreSQL、MySQL、MariaDB、SQLite、DuckDB、Redis、MongoDB 和 SQL Server。驱动随应用提供；见[移动端数据库支持](https://docs.tablepro.app/ios#supported-databases)。 |
| Linux | 11 种引擎：PostgreSQL、MySQL、MariaDB、SQL Server、ClickHouse、Cassandra、ScyllaDB、SQLite、DuckDB、Redis 和 MongoDB。见[支持的服务器及版本](linux/README.md#supported-servers)。 |
| Windows | 基于[共享核心的驱动](core/ARCHITECTURE.md#crate-layout)开发中。尚未发布应用。 |

## 功能

- 查询编辑器、数据浏览和行编辑。
- SSH 隧道和 SSL/TLS 连接。
- 保存查询和查询历史。
- Mac 和 Linux：自动补全、多光标编辑和 Vim 模式。
- Mac：分栏和驱动插件。
- Mac 和 Linux：使用自选服务商或 Ollama 的 AI 助手，以及供本机客户端使用的 MCP 服务器。
- iPhone 和 iPad：浏览和编辑数据，可选用 iCloud 同步连接和已保存的查询。

各应用的功能见 [Mac 功能指南](https://docs.tablepro.app/features/overview)、[Linux 指南](linux/README.md)和 [iPhone 与 iPad 指南](https://docs.tablepro.app/ios)。

## 免费与付费

上述数据库工具对所有支持的数据库免费，没有试用期或时间限制。Pro 和 Team 为 Mac 增加付费功能。Linux 使用相同的套餐和账户；一份许可可用于最多 3 台 Mac 或 Linux 电脑。功能因平台而异：见[套餐与价格](https://tablepro.app/pricing)及 [Linux 账户](linux/README.md#tablepro-account)。iPhone 和 iPad 应用无需许可。

## 构建与贡献

各平台的环境配置、构建和测试说明与源码放在一起：

- [macOS 和 iOS](apple/CONTRIBUTING.md)。
- [Linux](linux/README.md#quickstart)。
- [Windows](windows/AGENTS.md#commands)，以及[打包和发布说明](windows/RELEASING.md)。
- [共享 Rust 核心](core/AGENTS.md#commands)与[架构](core/ARCHITECTURE.md)。

提交 pull request 前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 文档与社区

- [文档](https://docs.tablepro.app)：配置和日常使用。
- [GitHub Discussions](https://github.com/TableProApp/TablePro/discussions) 或 [Discord](https://discord.gg/hCNmUUbnD4)：提问和分享想法。
- [Issues](https://github.com/TableProApp/TablePro/issues)：报告缺陷。请注明平台、应用版本，以及适用时的 Linux 安装来源。
- [安全政策](SECURITY.md)：私下报告漏洞；[行为准则](CODE_OF_CONDUCT.md)：社区规范。

## 支持开发

购买[许可](https://tablepro.app/pricing)或[赞助项目](https://tablepro.app/sponsors)可资助开发。你也可以继续使用免费版，无需购买或赞助。

## 赞助者

TablePro 由用户及以下赞助者资助。 [成为赞助者](https://tablepro.app/sponsors).

<p>
  <a href="https://coderabbit.link/tablepro"><img src=".github/assets/sponsors/coderabbit.svg" height="44" alt="CodeRabbit"></a>
  <a href="https://simplelocalize.io?ref=tablepro"><img src=".github/assets/sponsors/simplelocalize.svg" height="44" alt="SimpleLocalize"></a>
  <a href="https://getnimbus.io?ref=tablepro"><img src=".github/assets/sponsors/nimbus.svg" height="44" alt="Nimbus"></a>
  <a href="https://dwarves.foundation?ref=tablepro"><img src=".github/assets/sponsors/dwarves-foundation.svg" height="44" alt="Dwarves Foundation"></a>
  <a href="https://pyto.com?ref=tablepro"><img src=".github/assets/sponsors/pyto.svg" height="44" alt="Pyto"></a>
</p>

个人赞助者： [朱文锦](https://github.com/zhuwjin)

## 贡献者

感谢所有为 TablePro 做出贡献的人：

<a href="https://github.com/TableProApp/TablePro/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=TableProApp/TablePro" alt="TablePro contributors" />
</a>

想加入？请阅读 [CONTRIBUTING.md](CONTRIBUTING.md).

## Star History

<a href="https://www.star-history.com/?repos=TableProApp%2FTablePro&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=TableProApp/TablePro&type=date&theme=dark&legend=top-left&sealed_token=rD14Ce48qCR6mXTi0zio-abLAcluGQrDOorFBPL8DAMnUeVFYI8giJJ8arDwTaB8BgpJfk3Y2y5hpIiAu4SBOg6e1_nW8xZ7OrTOFi7ykoGvxk30ycgvzwHW4E-skW0jp5QGttP1QvGgeu5xFrkVbvFa1OFSo_JwWr557R6RNg2hDXdFD7v7nwf_VnR1" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=TableProApp/TablePro&type=date&legend=top-left&sealed_token=rD14Ce48qCR6mXTi0zio-abLAcluGQrDOorFBPL8DAMnUeVFYI8giJJ8arDwTaB8BgpJfk3Y2y5hpIiAu4SBOg6e1_nW8xZ7OrTOFi7ykoGvxk30ycgvzwHW4E-skW0jp5QGttP1QvGgeu5xFrkVbvFa1OFSo_JwWr557R6RNg2hDXdFD7v7nwf_VnR1" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=TableProApp/TablePro&type=date&legend=top-left&sealed_token=rD14Ce48qCR6mXTi0zio-abLAcluGQrDOorFBPL8DAMnUeVFYI8giJJ8arDwTaB8BgpJfk3Y2y5hpIiAu4SBOg6e1_nW8xZ7OrTOFi7ykoGvxk30ycgvzwHW4E-skW0jp5QGttP1QvGgeu5xFrkVbvFa1OFSo_JwWr557R6RNg2hDXdFD7v7nwf_VnR1" />
 </picture>
</a>

## 许可证

本项目采用 [GNU Affero General Public License v3.0 或更高版本 (AGPL-3.0-or-later)](LICENSE)。TablePro 名称和图标的使用另见 [TRADEMARKS.md](TRADEMARKS.md)。
