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

Viết bằng framework native cho từng nền tảng. Không Electron, không JDBC, không JavaScript runtime. Khởi động dưới 1 giây, chạy nền khoảng 80 MB RAM. Kết nối tới hầu hết các database SQL và NoSQL qua driver native.

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
| macOS 14+ | Ổn định |
| iOS / iPadOS 18+ | Ổn định |
| Linux | Đang phát triển |

## Database hỗ trợ

| Database | Phân phối |
|----------|-----------|
| MySQL | Tích hợp sẵn |
| MariaDB | Tích hợp sẵn |
| PostgreSQL | Tích hợp sẵn |
| Amazon Redshift | Tích hợp sẵn |
| CockroachDB | Tích hợp sẵn |
| SQLite | Tích hợp sẵn |
| ClickHouse | Tích hợp sẵn |
| Redis | Tích hợp sẵn |
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

Driver tích hợp sẵn đi kèm app. Driver dạng plugin cài thêm khi cần từ [plugin registry](https://github.com/TableProApp/plugins).

## Bên trong có gì

- SQL editor với autocomplete, multi-cursor, Vim mode, theme cú pháp
- Data grid sửa inline, sort, filter, undo/redo
- Tab native trong cửa sổ, đa cửa sổ, split pane
- SSH tunnel (password và key), SSL/TLS
- Lịch sử query tìm kiếm full-text
- iCloud sync cho connection, group, tag, cài đặt, SSH profile
- AI chat, gợi ý inline, Explain/Optimize
- MCP server và URL scheme cho Raycast, Cursor, Claude Desktop
- Hệ thống plugin, tự viết driver database bằng Swift

## Cài đặt

```bash
brew install --cask tablepro
```

Hoặc tải về từ [GitHub Releases](https://github.com/TableProApp/TablePro/releases).

## Tài liệu

Tài liệu đầy đủ tại [docs.tablepro.app](https://docs.tablepro.app).

## Ủng hộ phát triển

App miễn phí theo AGPLv3. Nếu bạn dùng TablePro cho công việc, hãy mua [license](https://tablepro.app). Mỗi giao dịch đều giúp duy trì bản release tiếp theo. Nếu chưa có điều kiện, cứ dùng bản miễn phí. Bản miễn phí có sẵn cho bạn.

## Nhà tài trợ

Cảm ơn những người tuyệt vời đã ủng hộ TablePro:

**[SimpleLocalize](https://simplelocalize.io?ref=tablepro)** · **[CodeRabbit](https://coderabbit.ai?ref=tablepro)** · **[Nimbus](https://getnimbus.io?ref=tablepro)** · **[Visnalize](https://visnalize.com?ref=tablepro)** · **[Dwarves Foundation](https://dwarves.foundation/?ref=tablepro)** · **[Huy TQ](https://github.com/imhuytq)** · **[Xermius](https://xermius.com?ref=tablepro)** · **[Unikorn](https://unikorn.vn?ref=tablepro)**

## Star History

<a href="https://www.star-history.com/?repos=TableProApp%2FTablePro&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/image?repos=TableProApp/TablePro&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/image?repos=TableProApp/TablePro&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/image?repos=TableProApp/TablePro&type=date&legend=top-left" />
 </picture>
</a>

## Bản quyền

Dự án này cấp phép theo [GNU Affero General Public License v3.0 (AGPLv3)](LICENSE).

Đóng góp cần ký Contributor License Agreement (CLA). Xem [CLA.md](CLA.md) để biết chi tiết.
