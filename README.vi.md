<p align="center">
  <img src=".github/assets/logo.png" width="128" height="128" alt="TablePro">
</p>

<h1 align="center">TablePro</h1>

<p align="center">
  Database client nhanh, native cho lập trình viên.<br>
  Miễn phí và mã nguồn mở.
</p>

<p align="center">
  <a href="https://tablepro.app">Website</a> ·
  <a href="https://docs.tablepro.app">Tài liệu</a> ·
  <a href="https://github.com/TableProApp/TablePro/releases">Tải xuống</a> ·
  <a href="https://discord.gg/hCNmUUbnD4">Discord</a>
</p>

<p align="center">
  <a href="https://github.com/TableProApp/TablePro/releases/latest"><img src="https://img.shields.io/github/v/release/TableProApp/TablePro" alt="Release"></a>
  <a href="https://www.gnu.org/licenses/agpl-3.0"><img src="https://img.shields.io/badge/License-AGPL_v3-blue.svg" alt="License: AGPL v3"></a>
</p>

<p align="center">
  <a href="README.md">English</a>
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
    <img alt="TablePro database client native với SQL editor và data grid" src=".github/assets/app-light.png" width="800">
  </picture>
</p>

## Giới thiệu

TablePro là TablePlus mà tôi luôn muốn có: native, nhanh, mã nguồn mở.

Viết bằng framework native cho từng nền tảng. Không Electron, không JDBC, không JavaScript runtime. Kết nối tới hầu hết các database SQL và NoSQL qua driver native.

AI tích hợp sẵn: chat, gợi ý inline, và MCP server để Cursor, Raycast hay Claude Desktop nói chuyện trực tiếp với database của bạn. API key bạn tự cấp, provider bạn tự chọn, hoặc chạy local với Ollama.

## Vì sao chọn TablePro

Database client native trên macOS hiện chia làm ba nhóm:

- **Một database, mã nguồn mở**: Sequel Ace (chỉ MySQL), Postico (chỉ PostgreSQL). Hợp nếu bạn chỉ làm một engine.
- **Đa database, đóng nguồn**: TablePlus. Mượt và native, nhưng proprietary.
- **Đa database, không native**: DBeaver (JVM), Beekeeper Studio và DBGate (Electron). Chạy được trên mọi OS, nhưng khởi động chậm và ngốn RAM.

TablePro là mảnh thứ tư còn thiếu: native, đa database, và mã nguồn mở.

## Nền tảng

| Nền tảng | Trạng thái |
|----------|-----------|
| macOS 13+ | Ổn định |
| iOS / iPadOS 18+ | Ổn định |
| Linux | Bản thử nghiệm, chưa có gì để cài |
| Windows | Không |

## Database hỗ trợ

- **Tích hợp sẵn**: MySQL, MariaDB, TiDB, OceanBase, Databend, PostgreSQL, Amazon Redshift, CockroachDB, PGlite, SQLite, ClickHouse, Redis
- **Plugin**: Microsoft SQL Server, MongoDB, Oracle Database, Snowflake, BigQuery, Spanner, DynamoDB, DuckDB, Cassandra, ScyllaDB, Elasticsearch, Kafka, Trino, Teradata, SAP HANA, Dameng DM8, SurrealDB, Typesense, Weaviate, etcd, Cloudflare D1, Cloudflare R2 SQL, libSQL, Turso, Beancount

Driver tích hợp sẵn đi kèm app. Driver dạng plugin cài thêm khi cần từ [plugin registry](https://github.com/TableProApp/plugins). Danh sách hiện tại và những gì từng engine hỗ trợ có tại [tablepro.app/databases](https://tablepro.app/databases).

## Bên trong có gì

- SQL editor với autocomplete, multi-cursor, Vim mode, theme cú pháp
- Data grid sửa inline, sort, filter, undo/redo
- Tab native trong cửa sổ, đa cửa sổ, split pane
- SSH tunnel (password và key), SSL/TLS
- Lịch sử query tìm kiếm full-text
- AI chat, gợi ý inline, Explain/Optimize
- MCP server và URL scheme cho Raycast, Cursor, Claude Desktop
- Hệ thống plugin, tự viết driver database bằng Swift

## Miễn phí và trả phí

Mọi thứ ở trên đều miễn phí với mọi database, không phải bản dùng thử và không giới hạn thời gian. License bổ sung các tính năng sau cho app Mac:

| Gói | Bổ sung |
|-----|---------|
| Starter | iCloud Sync, Encrypted Export, Environment Variables, Linked Folders, Query Insights, Result Charts, Compare & Sync, Data Rewind |
| Team | Mọi thứ trong Starter, thêm Team Catalog và Team Library |

Các gói và giá có tại [tablepro.app/pricing](https://tablepro.app/pricing). App cho iPhone và iPad không cần license.

## Cài đặt

```bash
brew install --cask tablepro
```

Hoặc tải về từ [GitHub Releases](https://github.com/TableProApp/TablePro/releases).

## Tài liệu

Tài liệu đầy đủ tại [docs.tablepro.app](https://docs.tablepro.app).

## Ủng hộ phát triển

App miễn phí theo AGPLv3. Nếu bạn dùng TablePro cho công việc, hãy mua [license](https://tablepro.app/pricing). License bổ sung các tính năng trả phí, và mỗi giao dịch đều giúp duy trì bản release tiếp theo. Nếu chưa có điều kiện, cứ dùng bản miễn phí. Bản miễn phí có sẵn cho bạn.

## Nhà tài trợ

Cảm ơn những người tuyệt vời đã ủng hộ TablePro:

**[SimpleLocalize](https://simplelocalize.io?ref=tablepro)** · **[CodeRabbit](https://coderabbit.ai?ref=tablepro)** · **[Nimbus](https://getnimbus.io?ref=tablepro)** · **[Dwarves Foundation](https://dwarves.foundation/?ref=tablepro)**

## Người đóng góp

Cảm ơn tất cả những người đã đóng góp cho TablePro:

<a href="https://github.com/TableProApp/TablePro/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=TableProApp/TablePro" alt="Những người đóng góp cho TablePro" />
</a>

Muốn tham gia? Đọc [CONTRIBUTING.md](CONTRIBUTING.md).

## Star History

<a href="https://www.star-history.com/?repos=TableProApp%2FTablePro&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=TableProApp/TablePro&type=date&theme=dark&legend=top-left&sealed_token=rD14Ce48qCR6mXTi0zio-abLAcluGQrDOorFBPL8DAMnUeVFYI8giJJ8arDwTaB8BgpJfk3Y2y5hpIiAu4SBOg6e1_nW8xZ7OrTOFi7ykoGvxk30ycgvzwHW4E-skW0jp5QGttP1QvGgeu5xFrkVbvFa1OFSo_JwWr557R6RNg2hDXdFD7v7nwf_VnR1" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=TableProApp/TablePro&type=date&legend=top-left&sealed_token=rD14Ce48qCR6mXTi0zio-abLAcluGQrDOorFBPL8DAMnUeVFYI8giJJ8arDwTaB8BgpJfk3Y2y5hpIiAu4SBOg6e1_nW8xZ7OrTOFi7ykoGvxk30ycgvzwHW4E-skW0jp5QGttP1QvGgeu5xFrkVbvFa1OFSo_JwWr557R6RNg2hDXdFD7v7nwf_VnR1" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=TableProApp/TablePro&type=date&legend=top-left&sealed_token=rD14Ce48qCR6mXTi0zio-abLAcluGQrDOorFBPL8DAMnUeVFYI8giJJ8arDwTaB8BgpJfk3Y2y5hpIiAu4SBOg6e1_nW8xZ7OrTOFi7ykoGvxk30ycgvzwHW4E-skW0jp5QGttP1QvGgeu5xFrkVbvFa1OFSo_JwWr557R6RNg2hDXdFD7v7nwf_VnR1" />
 </picture>
</a>

## Bản quyền

Dự án này cấp phép theo [GNU Affero General Public License v3.0 (AGPLv3)](LICENSE).

