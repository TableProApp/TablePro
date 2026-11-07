<p align="center">
  <img src=".github/assets/logo.png" width="128" height="128" alt="TablePro">
</p>

<h1 align="center">TablePro</h1>

<p align="center">
  macOS, iPhone, iPad, Linux용 네이티브 데이터베이스 앱.<br>
  무료 오픈 소스입니다.
</p>

<p align="center">
  <a href="https://tablepro.app">Website</a> ·
  <a href="https://docs.tablepro.app">문서</a> ·
  <a href="https://github.com/TableProApp/TablePro/releases">다운로드</a> ·
  <a href="https://discord.gg/hCNmUUbnD4">Discord</a>
</p>

<p align="center">
  <a href="https://github.com/TableProApp/TablePro/releases"><img src="https://img.shields.io/github/v/release/TableProApp/TablePro" alt="Release"></a>
  <a href="https://www.gnu.org/licenses/agpl-3.0"><img src="https://img.shields.io/badge/License-AGPL_v3-blue.svg" alt="License: AGPL v3"></a>
</p>

<p align="center">
  <a href="README.vi.md">Tiếng Việt</a>
  <a href="README.zh.md">简体中文</a>
  <a href="README.md">English</a>
</p>

<p align="center">
  <a href="https://trendshift.io/repositories/24114" target="_blank"><img src="https://trendshift.io/api/badge/repositories/24114" alt="TableProApp%2FTablePro | Trendshift" style="width: 250px; height: 55px;" width="250" height="55"/></a>
</p>

---

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/app-dark.png">
    <source media="(prefers-color-scheme: light)" srcset=".github/assets/app-light.png">
    <img alt="SQL 편집기와 데이터 그리드를 갖춘 TablePro 데이터베이스 클라이언트" src=".github/assets/app-light.png" width="800">
  </picture>
</p>

## 소개

TablePro는 제가 바라던 TablePlus의 모습입니다. 네이티브이고 빠르며 오픈 소스입니다.

TablePro는 플랫폼마다 네이티브 앱을 제공하는 무료 오픈 소스 데이터베이스 클라이언트입니다. SQL과 NoSQL 데이터베이스에서 데이터를 탐색하고, 쿼리를 작성하고, 행을 편집할 수 있습니다.

Apple 앱은 Swift와 네이티브 프레임워크를 사용합니다. Linux는 Rust, GTK 4, libadwaita를 사용합니다. Windows는 C#과 WinUI 3를 사용하며 개발 중입니다. Linux와 Windows는 공유 Rust 코어를 기반으로 하며, Swift 앱은 아직 이 코어를 사용하지 않습니다.

## TablePro를 선택하는 이유

현재 데이터베이스 클라이언트는 세 가지 유형으로 나뉩니다.

- **단일 데이터베이스, 오픈 소스**: Sequel Ace(MySQL 전용), Postico(PostgreSQL 전용). 하나의 엔진만 사용한다면 훌륭한 선택입니다.
- **다중 데이터베이스, 비공개 소스**: TablePlus. 완성도 높은 네이티브 앱이지만 독점 소프트웨어입니다.
- **다중 데이터베이스, 비네이티브**: DBeaver(JVM), Beekeeper Studio와 DBGate(Electron). 여러 플랫폼에서 실행되지만 시작이 느리고 메모리를 많이 사용합니다.

TablePro는 네 번째 선택지입니다. 모든 플랫폼에서 네이티브이고 여러 데이터베이스를 지원하며 오픈 소스입니다.

## 플랫폼과 설치

| 플랫폼 | 상태 | 설치 |
|---|---|---|
| macOS 13+ | 안정 버전 | `brew install --cask tablepro` 또는 [GitHub Releases](https://github.com/TableProApp/TablePro/releases) |
| iPhone / iPad, iOS / iPadOS 18+ | 안정 버전 | [iPhone 및 iPad 가이드](https://docs.tablepro.app/ios) |
| Linux, amd64 / arm64 | 공개 베타 | [Ubuntu 베타 PPA, Fedora 베타 COPR 또는 베타 Flatpak 저장소](https://docs.tablepro.app/linux/install) |
| Windows | 개발 중 | [소스 및 빌드 가이드](windows/AGENTS.md#commands) |

Linux 네이티브 패키지에는 GNOME 50 라이브러리가 필요합니다. Ubuntu 26.04 / 26.10은 `ppa:tablepro/tablepro-beta`를, Fedora 44 / 45는 `@tablepro/tablepro-beta`를 사용합니다. 다른 배포판은 베타 Flatpak 저장소를 사용합니다. 설치와 업데이트는 [Linux 설치 가이드](https://docs.tablepro.app/linux/install)를 따르세요. 패키지는 [GitHub Releases](https://github.com/TableProApp/TablePro/releases)에서도 받을 수 있습니다.

## 지원 데이터베이스

지원 범위는 플랫폼마다 다릅니다. 전체 목록과 제한 사항은 각 가이드에 있습니다.

| 플랫폼 | 데이터베이스 |
|---|---|
| macOS | PostgreSQL, MySQL, MariaDB, SQLite, Redis, MongoDB, SQL Server 등. 내장 드라이버와 서명된 플러그인을 사용합니다. [데이터베이스 목록](https://tablepro.app/databases)과 [플러그인 가이드](https://docs.tablepro.app/features/plugins)를 참고하세요. |
| iPhone / iPad | PostgreSQL, MySQL, MariaDB, SQLite, DuckDB, Redis, MongoDB, SQL Server 등을 지원합니다. 드라이버는 앱에 포함됩니다. [모바일 데이터베이스 지원](https://docs.tablepro.app/ios#supported-databases)을 참고하세요. |
| Linux | 11개 엔진: PostgreSQL, MySQL, MariaDB, SQL Server, ClickHouse, Cassandra, ScyllaDB, SQLite, DuckDB, Redis, MongoDB. [지원 서버와 버전](linux/README.md#supported-servers)을 참고하세요. |
| Windows | [공유 코어의 드라이버](core/ARCHITECTURE.md#crate-layout)를 기반으로 개발 중입니다. 아직 출시된 앱은 없습니다. |

## 기능

- 쿼리 편집기, 데이터 탐색, 행 편집.
- SSH 터널과 SSL/TLS 연결.
- 쿼리 저장과 쿼리 기록.
- Mac 및 Linux: 자동 완성, 다중 커서 편집, Vim 모드.
- Mac: 분할 창, 드라이버 플러그인.
- Mac과 Linux: 원하는 제공업체 또는 Ollama를 사용하는 AI 도우미와 로컬 클라이언트용 MCP 서버.
- iPhone과 iPad: 데이터 탐색과 편집, 연결 및 저장된 쿼리의 선택적 iCloud 동기화.

각 앱의 지원 기능은 [Mac 기능 가이드](https://docs.tablepro.app/features/overview), [Linux 가이드](linux/README.md), [iPhone 및 iPad 가이드](https://docs.tablepro.app/ios)를 참고하세요.

## 무료와 유료

위 데이터베이스 도구는 지원하는 모든 데이터베이스에서 무료이며, 체험 기간이나 시간 제한이 없습니다. Pro와 Team은 Mac에 유료 기능을 추가합니다. Linux도 같은 요금제와 계정을 사용하며, 라이선스 하나로 Mac 또는 Linux 컴퓨터를 최대 3대까지 사용할 수 있습니다. 기능은 플랫폼마다 다릅니다. [요금제와 가격](https://tablepro.app/pricing), [Linux 계정](linux/README.md#tablepro-account)을 참고하세요. iPhone과 iPad 앱에는 라이선스가 필요하지 않습니다.

## 빌드와 기여

각 플랫폼의 환경 설정, 빌드, 테스트 안내는 소스와 함께 있습니다.

- [macOS 및 iOS](apple/CONTRIBUTING.md).
- [Linux](linux/README.md#quickstart).
- [Windows](windows/AGENTS.md#commands), [패키징 및 릴리스 안내](windows/RELEASING.md).
- [공유 Rust 코어](core/AGENTS.md#commands)와 [아키텍처](core/ARCHITECTURE.md).

Pull request를 열기 전에 [CONTRIBUTING.md](CONTRIBUTING.md)를 읽어 주세요.

## 문서와 커뮤니티

- [문서](https://docs.tablepro.app): 설정과 일상적인 사용 방법.
- [GitHub Discussions](https://github.com/TableProApp/TablePro/discussions) 또는 [Discord](https://discord.gg/hCNmUUbnD4): 질문과 아이디어 공유.
- [Issues](https://github.com/TableProApp/TablePro/issues): 버그 보고. 플랫폼, 앱 버전, 해당하는 경우 Linux 설치 출처를 적어 주세요.
- [보안 정책](SECURITY.md): 비공개 취약점 보고. [행동 강령](CODE_OF_CONDUCT.md): 커뮤니티 규칙.

## 개발 후원

[라이선스 구매](https://tablepro.app/pricing)나 [프로젝트 후원](https://tablepro.app/sponsors)은 개발에 쓰입니다. 구매나 후원 없이 무료 버전을 계속 사용해도 됩니다.

## 후원자

TablePro는 사용자와 다음 후원자들의 지원으로 개발됩니다. [후원하기](https://tablepro.app/sponsors).

<p>
  <a href="https://coderabbit.link/tablepro"><img src=".github/assets/sponsors/coderabbit.svg" height="44" alt="CodeRabbit"></a>
  <a href="https://simplelocalize.io?ref=tablepro"><img src=".github/assets/sponsors/simplelocalize.svg" height="44" alt="SimpleLocalize"></a>
  <a href="https://getnimbus.io?ref=tablepro"><img src=".github/assets/sponsors/nimbus.svg" height="44" alt="Nimbus"></a>
  <a href="https://dwarves.foundation?ref=tablepro"><img src=".github/assets/sponsors/dwarves-foundation.svg" height="44" alt="Dwarves Foundation"></a>
  <a href="https://pyto.com?ref=tablepro"><img src=".github/assets/sponsors/pyto.svg" height="44" alt="Pyto"></a>
</p>

개인 후원자: [朱文锦](https://github.com/zhuwjin)

## 기여자

TablePro에 기여해 주신 모든 분께 감사드립니다:

<a href="https://github.com/TableProApp/TablePro/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=TableProApp/TablePro" alt="TablePro contributors" />
</a>

참여하려면 다음 문서를 읽어 주세요: [CONTRIBUTING.md](CONTRIBUTING.md).

## 스타 히스토리

<a href="https://www.star-history.com/?repos=TableProApp%2FTablePro&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=TableProApp/TablePro&type=date&theme=dark&legend=top-left&sealed_token=rD14Ce48qCR6mXTi0zio-abLAcluGQrDOorFBPL8DAMnUeVFYI8giJJ8arDwTaB8BgpJfk3Y2y5hpIiAu4SBOg6e1_nW8xZ7OrTOFi7ykoGvxk30ycgvzwHW4E-skW0jp5QGttP1QvGgeu5xFrkVbvFa1OFSo_JwWr557R6RNg2hDXdFD7v7nwf_VnR1" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=TableProApp/TablePro&type=date&legend=top-left&sealed_token=rD14Ce48qCR6mXTi0zio-abLAcluGQrDOorFBPL8DAMnUeVFYI8giJJ8arDwTaB8BgpJfk3Y2y5hpIiAu4SBOg6e1_nW8xZ7OrTOFi7ykoGvxk30ycgvzwHW4E-skW0jp5QGttP1QvGgeu5xFrkVbvFa1OFSo_JwWr557R6RNg2hDXdFD7v7nwf_VnR1" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=TableProApp/TablePro&type=date&legend=top-left&sealed_token=rD14Ce48qCR6mXTi0zio-abLAcluGQrDOorFBPL8DAMnUeVFYI8giJJ8arDwTaB8BgpJfk3Y2y5hpIiAu4SBOg6e1_nW8xZ7OrTOFi7ykoGvxk30ycgvzwHW4E-skW0jp5QGttP1QvGgeu5xFrkVbvFa1OFSo_JwWr557R6RNg2hDXdFD7v7nwf_VnR1" />
 </picture>
</a>

## 라이선스

이 프로젝트는 [GNU Affero General Public License v3.0 이상 (AGPL-3.0-or-later)](LICENSE)에 따라 배포됩니다. TablePro 이름과 아이콘의 사용 규칙은 [TRADEMARKS.md](TRADEMARKS.md)에 별도로 명시되어 있습니다.
