<p align="center">
  <img src=".github/assets/logo.png" width="128" height="128" alt="TablePro">
</p>

<h1 align="center">TablePro</h1>

<p align="center">
  Ứng dụng cơ sở dữ liệu native cho macOS, iPhone, iPad và Linux.<br>
  Miễn phí và mã nguồn mở.
</p>

<p align="center">
  <a href="https://tablepro.app">Website</a> ·
  <a href="https://docs.tablepro.app">Tài liệu</a> ·
  <a href="https://github.com/TableProApp/TablePro/releases">Tải xuống</a> ·
  <a href="https://discord.gg/hCNmUUbnD4">Discord</a>
</p>

<p align="center">
  <a href="https://github.com/TableProApp/TablePro/releases"><img src="https://img.shields.io/github/v/release/TableProApp/TablePro" alt="Release"></a>
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
    <img alt="TablePro với trình soạn SQL và bảng dữ liệu" src=".github/assets/app-light.png" width="800">
  </picture>
</p>

## Giới thiệu

TablePro là ứng dụng quản lý cơ sở dữ liệu miễn phí, mã nguồn mở, với giao diện native riêng cho từng nền tảng. Duyệt dữ liệu, viết truy vấn và sửa hàng trong cơ sở dữ liệu SQL và NoSQL.

Ứng dụng Apple dùng Swift và framework native. Linux dùng Rust, GTK 4 và libadwaita. Windows dùng C# và WinUI 3, hiện đang phát triển. Linux và Windows dùng lõi Rust chung; ứng dụng Swift chưa dùng lõi này.

## Nền tảng và cài đặt

| Nền tảng | Trạng thái | Cài đặt |
|---|---|---|
| macOS 13+ | Ổn định | `brew install --cask tablepro` hoặc [GitHub Releases](https://github.com/TableProApp/TablePro/releases) |
| iPhone / iPad, iOS / iPadOS 18+ | Ổn định | [Hướng dẫn iPhone và iPad](https://docs.tablepro.app/ios) |
| Linux, amd64 / arm64 | Beta công khai | [PPA beta cho Ubuntu, COPR beta cho Fedora hoặc kho Flatpak beta](https://docs.tablepro.app/linux/install) |
| Windows | Đang phát triển | [Mã nguồn và hướng dẫn build](windows/AGENTS.md#commands) |

Gói native trên Linux cần thư viện GNOME 50: Ubuntu 26.04 / 26.10 dùng `ppa:tablepro/tablepro-beta`, Fedora 44 / 45 dùng `@tablepro/tablepro-beta`. Các bản phân phối khác dùng kho Flatpak beta. Xem [hướng dẫn cài Linux](https://docs.tablepro.app/linux/install) để cài đặt và cập nhật. Các gói cũng có trên [GitHub Releases](https://github.com/TableProApp/TablePro/releases).

## Cơ sở dữ liệu hỗ trợ

Mỗi nền tảng hỗ trợ khác nhau. Danh sách đầy đủ và giới hạn nằm trong các hướng dẫn được liên kết.

| Nền tảng | Cơ sở dữ liệu |
|---|---|
| macOS | PostgreSQL, MySQL, MariaDB, SQLite, Redis, MongoDB, SQL Server và nhiều loại khác. Driver tích hợp và plugin có chữ ký; xem [danh sách cơ sở dữ liệu](https://tablepro.app/databases) và [hướng dẫn plugin](https://docs.tablepro.app/features/plugins). |
| iPhone / iPad | Có PostgreSQL, MySQL, MariaDB, SQLite, DuckDB, Redis, MongoDB và SQL Server. Driver đi kèm ứng dụng; xem [hỗ trợ trên di động](https://docs.tablepro.app/ios#supported-databases). |
| Linux | 11 hệ quản trị: PostgreSQL, MySQL, MariaDB, SQL Server, ClickHouse, Cassandra, ScyllaDB, SQLite, DuckDB, Redis và MongoDB. Xem [máy chủ và phiên bản được hỗ trợ](linux/README.md#supported-servers). |
| Windows | Đang phát triển trên [driver của lõi chung](core/ARCHITECTURE.md#crate-layout). Chưa phát hành ứng dụng. |

## Tính năng

- Trình soạn truy vấn, duyệt dữ liệu và sửa hàng.
- SSH tunnel và kết nối SSL/TLS.
- Truy vấn đã lưu và lịch sử truy vấn.
- Trên Mac và Linux: tự hoàn thành, sửa với nhiều con trỏ và chế độ Vim.
- Trên Mac: chia khung và plugin driver.
- Trên Mac và Linux: trợ lý AI dùng nhà cung cấp bạn chọn hoặc Ollama, và MCP server cho ứng dụng trên máy.
- Trên iPhone và iPad: duyệt và sửa dữ liệu, tùy chọn đồng bộ kết nối và truy vấn đã lưu qua iCloud.

Xem [tính năng trên Mac](https://docs.tablepro.app/features/overview), [hướng dẫn Linux](linux/README.md) và [hướng dẫn iPhone và iPad](https://docs.tablepro.app/ios) để biết từng ứng dụng hỗ trợ gì.

## Miễn phí và trả phí

Các công cụ cơ sở dữ liệu ở trên miễn phí với mọi cơ sở dữ liệu được hỗ trợ, không có thời hạn dùng thử hay giới hạn thời gian. Pro và Team thêm tính năng trả phí trên Mac. Linux dùng cùng gói và tài khoản; một giấy phép dùng được trên tối đa 3 máy tính, Mac hoặc Linux. Tính năng khác nhau theo nền tảng: xem [gói và giá](https://tablepro.app/pricing) và [tài khoản trên Linux](linux/README.md#tablepro-account). Ứng dụng iPhone và iPad không cần giấy phép.

## Build và đóng góp

Mỗi nền tảng giữ hướng dẫn thiết lập, build và kiểm thử cạnh mã nguồn:

- [macOS và iOS](apple/CONTRIBUTING.md).
- [Linux](linux/README.md#quickstart).
- [Windows](windows/AGENTS.md#commands), cùng [hướng dẫn đóng gói và phát hành](windows/RELEASING.md).
- [Lõi Rust chung](core/AGENTS.md#commands) và [kiến trúc](core/ARCHITECTURE.md).

Đọc [CONTRIBUTING.md](CONTRIBUTING.md) trước khi mở pull request.

## Tài liệu và cộng đồng

- [Tài liệu](https://docs.tablepro.app) về thiết lập và sử dụng hằng ngày.
- [GitHub Discussions](https://github.com/TableProApp/TablePro/discussions) hoặc [Discord](https://discord.gg/hCNmUUbnD4) để hỏi và chia sẻ ý tưởng.
- [Issues](https://github.com/TableProApp/TablePro/issues) để báo lỗi. Ghi nền tảng, phiên bản ứng dụng và nguồn cài Linux nếu có.
- [Chính sách bảo mật](SECURITY.md) để báo lỗ hổng riêng tư, và [quy tắc ứng xử](CODE_OF_CONDUCT.md) cho cộng đồng.

## Ủng hộ phát triển

Mua [giấy phép](https://tablepro.app/pricing) hoặc [tài trợ dự án](https://tablepro.app/sponsors) giúp duy trì phát triển. Bạn vẫn có thể dùng bản miễn phí mà không cần mua hay tài trợ.

## Nhà tài trợ

TablePro được người dùng và các nhà tài trợ sau hỗ trợ kinh phí. [Trở thành nhà tài trợ](https://tablepro.app/sponsors).

<p>
  <a href="https://coderabbit.link/tablepro"><img src=".github/assets/sponsors/coderabbit.svg" height="44" alt="CodeRabbit"></a>
  <a href="https://simplelocalize.io?ref=tablepro"><img src=".github/assets/sponsors/simplelocalize.svg" height="44" alt="SimpleLocalize"></a>
  <a href="https://getnimbus.io?ref=tablepro"><img src=".github/assets/sponsors/nimbus.svg" height="44" alt="Nimbus"></a>
  <a href="https://dwarves.foundation?ref=tablepro"><img src=".github/assets/sponsors/dwarves-foundation.svg" height="44" alt="Dwarves Foundation"></a>
  <a href="https://pyto.com?ref=tablepro"><img src=".github/assets/sponsors/pyto.svg" height="44" alt="Pyto"></a>
</p>

Nhà tài trợ cá nhân: [朱文锦](https://github.com/zhuwjin)

## Người đóng góp

Cảm ơn tất cả những người đã đóng góp cho TablePro:

<a href="https://github.com/TableProApp/TablePro/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=TableProApp/TablePro" alt="TablePro contributors" />
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

## Giấy phép

Dự án được cấp phép theo [GNU Affero General Public License v3.0 hoặc mới hơn (AGPL-3.0-or-later)](LICENSE). Tên và biểu tượng TablePro có quy định riêng tại [TRADEMARKS.md](TRADEMARKS.md).
