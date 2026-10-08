<p align="center">
  <img src=".github/assets/logo.png" width="128" height="128" alt="TablePro">
</p>

<h1 align="center">TablePro</h1>

<p align="center">
  面向开发者的快速、原生数据库客户端。<br>
  免费开源。
</p>

<p align="center">
  <a href="https://tablepro.app">官网</a> ·
  <a href="https://docs.tablepro.app">文档</a> ·
  <a href="https://github.com/TableProApp/TablePro/releases">下载</a> ·
  <a href="https://discord.gg/hCNmUUbnD4">Discord</a>
</p>

<p align="center">
  <a href="https://github.com/TableProApp/TablePro/releases/latest"><img src="https://img.shields.io/github/v/release/TableProApp/TablePro" alt="Release"></a>
  <a href="https://www.gnu.org/licenses/agpl-3.0"><img src="https://img.shields.io/badge/License-AGPL_v3-blue.svg" alt="License: AGPL v3"></a>
</p>

<p align="center">
  <a href="README.md">English</a>
  <a href="README.vi.md">Tiếng Việt</a>
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
    <img alt="TablePro 原生数据库客户端,带 SQL 编辑器和数据网格" src=".github/assets/app-light.png" width="800">
  </picture>
</p>

## 关于

TablePro 是我心目中的 TablePlus:原生、快速、开源。

每个平台都用原生框架构建。没有 Electron,没有 JDBC,没有 JavaScript 运行时。通过原生驱动连接所有主流 SQL 和 NoSQL 数据库。

AI 内置:聊天、行内建议,以及 MCP 服务器,让 Cursor、Raycast 或 Claude Desktop 直接和你的数据库对话。使用你自己的 API key,选你喜欢的服务商,或本地跑 Ollama。

## 为什么选 TablePro

目前 macOS 原生数据库客户端可分三类:

- **单数据库,开源**:Sequel Ace(仅 MySQL)、Postico(仅 PostgreSQL)。只用一种引擎的话很合适。
- **多数据库,闭源**:TablePlus。流畅且原生,但是专有软件。
- **多数据库,非原生**:DBeaver(JVM)、Beekeeper Studio 和 DBGate(Electron)。跨平台,但启动慢且占内存。

TablePro 补上缺失的第四类:原生、多数据库、开源。

## 平台支持

| 平台 | 状态 |
|------|------|
| macOS 13+ | 稳定版 |
| iOS / iPadOS 18+ | 稳定版 |
| Linux | 原型阶段，暂无可安装版本 |
| Windows | 无 |

## 支持的数据库

- **内置**:MySQL、MariaDB、TiDB、OceanBase、Databend、PostgreSQL、Amazon Redshift、CockroachDB、PGlite、SQLite、ClickHouse、Redis
- **插件**:Microsoft SQL Server、MongoDB、Oracle Database、Snowflake、BigQuery、Spanner、DynamoDB、DuckDB、Cassandra、ScyllaDB、Elasticsearch、Kafka、Trino、Teradata、SAP HANA、达梦 DM8、SurrealDB、Typesense、Weaviate、etcd、Cloudflare D1、Cloudflare R2 SQL、libSQL、Turso、Beancount

内置驱动随应用一起发布。插件驱动按需从[插件仓库](https://github.com/TableProApp/plugins)安装。最新列表以及每个引擎支持的功能见 [tablepro.app/databases](https://tablepro.app/databases)。

## 主要功能

- SQL 编辑器:自动补全、多光标、Vim 模式、语法主题
- 数据网格:行内编辑、排序、过滤、撤销/重做
- 原生窗口标签、多窗口、分屏
- SSH 隧道(密码和密钥认证)、SSL/TLS
- 查询历史全文搜索
- AI 聊天、行内建议、Explain/Optimize
- MCP 服务器和 URL scheme:Raycast、Cursor、Claude Desktop
- 插件系统:用 Swift 自己写数据库驱动

## 免费与付费

以上功能全部免费,适用于所有数据库,没有试用期,也没有时间限制。许可证为 Mac 应用增加以下功能:

| 方案 | 增加的功能 |
|------|-----------|
| Starter | iCloud Sync、Encrypted Export、Environment Variables、Linked Folders、Query Insights、Result Charts、Compare & Sync、Data Rewind |
| Team | Starter 的全部功能,另加 Team Catalog 和 Team Library |

方案和价格见 [tablepro.app/pricing](https://tablepro.app/pricing)。iPhone 和 iPad 应用不需要许可证。

## 安装

```bash
brew install --cask tablepro
```

或从 [GitHub Releases](https://github.com/TableProApp/TablePro/releases) 下载。

## 文档

完整文档请见 [docs.tablepro.app](https://docs.tablepro.app)。

## 支持开发

应用在 AGPLv3 下免费。如果你在工作中使用 TablePro,请购买[许可证](https://tablepro.app/pricing)。许可证增加付费功能,每一份购买都资助下一个版本。如果买不起,就用免费版吧。这就是它免费的原因。

## 赞助者

感谢这些为 TablePro 提供支持的朋友们:

**[SimpleLocalize](https://simplelocalize.io?ref=tablepro)** · **[CodeRabbit](https://coderabbit.ai?ref=tablepro)** · **[Nimbus](https://getnimbus.io?ref=tablepro)** · **[Dwarves Foundation](https://dwarves.foundation/?ref=tablepro)**

## 贡献者

感谢每一位为 TablePro 做出贡献的人:

<a href="https://github.com/TableProApp/TablePro/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=TableProApp/TablePro" alt="TablePro 贡献者" />
</a>

想加入他们?请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

## Star History

<a href="https://www.star-history.com/?repos=TableProApp%2FTablePro&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=TableProApp/TablePro&type=date&theme=dark&legend=top-left&sealed_token=rD14Ce48qCR6mXTi0zio-abLAcluGQrDOorFBPL8DAMnUeVFYI8giJJ8arDwTaB8BgpJfk3Y2y5hpIiAu4SBOg6e1_nW8xZ7OrTOFi7ykoGvxk30ycgvzwHW4E-skW0jp5QGttP1QvGgeu5xFrkVbvFa1OFSo_JwWr557R6RNg2hDXdFD7v7nwf_VnR1" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=TableProApp/TablePro&type=date&legend=top-left&sealed_token=rD14Ce48qCR6mXTi0zio-abLAcluGQrDOorFBPL8DAMnUeVFYI8giJJ8arDwTaB8BgpJfk3Y2y5hpIiAu4SBOg6e1_nW8xZ7OrTOFi7ykoGvxk30ycgvzwHW4E-skW0jp5QGttP1QvGgeu5xFrkVbvFa1OFSo_JwWr557R6RNg2hDXdFD7v7nwf_VnR1" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=TableProApp/TablePro&type=date&legend=top-left&sealed_token=rD14Ce48qCR6mXTi0zio-abLAcluGQrDOorFBPL8DAMnUeVFYI8giJJ8arDwTaB8BgpJfk3Y2y5hpIiAu4SBOg6e1_nW8xZ7OrTOFi7ykoGvxk30ycgvzwHW4E-skW0jp5QGttP1QvGgeu5xFrkVbvFa1OFSo_JwWr557R6RNg2hDXdFD7v7nwf_VnR1" />
 </picture>
</a>

## 许可证

本项目采用 [GNU Affero General Public License v3.0 (AGPLv3)](LICENSE) 许可。

