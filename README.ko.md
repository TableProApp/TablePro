<p align="center">
  <img src=".github/assets/logo.png" width="128" height="128" alt="TablePro">
</p>

<h1 align="center">TablePro</h1>

<p align="center">
  개발자를 위한 빠른 네이티브 데이터베이스 클라이언트입니다.<br>
  무료 오픈 소스입니다.
</p>

<p align="center">
  <a href="https://tablepro.app">웹사이트</a> ·
  <a href="https://docs.tablepro.app">문서</a> ·
  <a href="https://github.com/TableProApp/TablePro/releases">다운로드</a> ·
  <a href="https://discord.gg/hCNmUUbnD4">Discord</a>
</p>

<p align="center">
  <a href="https://github.com/TableProApp/TablePro/releases/latest"><img src="https://img.shields.io/github/v/release/TableProApp/TablePro" alt="릴리스"></a>
  <a href="https://www.gnu.org/licenses/agpl-3.0"><img src="https://img.shields.io/badge/License-AGPL_v3-blue.svg" alt="라이선스: AGPL v3"></a>
</p>

<p align="center">
  <a href="README.md">English</a>
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
    <img alt="SQL 편집기와 데이터 그리드를 갖춘 TablePro 데이터베이스 클라이언트" src=".github/assets/app-light.png" width="800">
  </picture>
</p>

## 소개

TablePro는 제가 바라던 TablePlus의 모습입니다. 네이티브이고 빠르며 오픈 소스입니다.

모든 플랫폼에서 네이티브 프레임워크로 제작되었습니다. Electron, JDBC, JavaScript 런타임을 사용하지 않습니다. 1초 이내에 실행되며 유휴 상태에서 약 80MB의 메모리를 사용합니다. 네이티브 드라이버로 주요 SQL 및 NoSQL 데이터베이스에 연결합니다.

AI 채팅, 인라인 제안, Cursor, Raycast 또는 Claude Desktop이 데이터베이스와 통신할 수 있는 MCP 서버가 내장되어 있습니다. 원하는 API 키와 제공자를 사용하거나 Ollama로 로컬에서 실행할 수 있습니다.

## TablePro를 선택하는 이유

현재 네이티브 macOS 데이터베이스 클라이언트는 세 가지 유형으로 나뉩니다.

- **단일 데이터베이스, 오픈 소스**: Sequel Ace(MySQL 전용), Postico(PostgreSQL 전용). 하나의 엔진만 사용한다면 훌륭한 선택입니다.
- **다중 데이터베이스, 비공개 소스**: TablePlus. 완성도 높은 네이티브 앱이지만 독점 소프트웨어입니다.
- **다중 데이터베이스, 비네이티브**: DBeaver(JVM), Beekeeper Studio와 DBGate(Electron). 여러 플랫폼에서 실행되지만 시작이 느리고 메모리를 많이 사용합니다.

TablePro는 네 번째 선택지입니다. 네이티브이고 여러 데이터베이스를 지원하며 오픈 소스입니다.

## 플랫폼

| 플랫폼 | 상태 |
|----------|--------|
| macOS 14+ | 안정 버전 |
| iOS / iPadOS 18+ | 안정 버전 |
| Linux | 프로토타입, 아직 설치할 수 없음 |
| Windows | 지원하지 않음 |

## 지원 데이터베이스

| 데이터베이스 | 배포 방식 |
|----------|--------------|
| MySQL | 내장 |
| MariaDB | 내장 |
| PostgreSQL | 내장 |
| Amazon Redshift | 내장 |
| CockroachDB | 내장 |
| SQLite | 내장 |
| ClickHouse | 내장 |
| Redis | 내장 |
| Microsoft SQL Server | 플러그인 |
| MongoDB | 플러그인 |
| Oracle Database | 플러그인 |
| Dameng DM8 | 플러그인 |
| DuckDB | 플러그인 |
| Beancount | 플러그인 |
| Cassandra / ScyllaDB | 플러그인 |
| Etcd | 플러그인 |
| Cloudflare D1 | 플러그인 |
| DynamoDB | 플러그인 |
| BigQuery | 플러그인 |
| libSQL / Turso | 플러그인 |

내장 드라이버는 앱에 포함되어 있습니다. 플러그인 드라이버는 [플러그인 레지스트리](https://github.com/TableProApp/plugins)에서 필요할 때 설치됩니다.

## 주요 기능

- 자동 완성, 다중 커서, Vim 모드와 구문 테마를 지원하는 SQL 편집기
- 인라인 편집, 정렬, 필터, 실행 취소와 다시 실행을 지원하는 데이터 그리드
- 네이티브 윈도우 탭, 다중 윈도우와 분할 패널
- 비밀번호 및 키 인증과 SSL/TLS를 지원하는 SSH 터널
- 전체 텍스트 검색을 지원하는 쿼리 기록
- 연결, 그룹, 태그, 설정과 SSH 프로필의 iCloud 동기화
- AI 채팅, 인라인 제안, Explain/Optimize
- Raycast, Cursor, Claude Desktop을 위한 MCP 서버와 URL 스킴
- Swift로 직접 데이터베이스 드라이버를 만들 수 있는 플러그인 시스템

## 설치

```bash
brew install --cask tablepro
```

또는 [GitHub Releases](https://github.com/TableProApp/TablePro/releases)에서 다운로드하세요.

## 빌드 방법

TablePro를 빌드하려면 macOS 14 이상, Xcode 26 이상과 [XcodeGen](https://github.com/yonaskolb/XcodeGen)이 필요합니다.

저장소 루트에서 최초 설정을 실행하세요.

```bash
brew install xcodegen
scripts/download-libs.sh
scripts/generate-project.sh
```

`TablePro.xcodeproj`는 `project.yml`에서 생성되며 Git에 포함되지 않습니다. `project.yml`이나 `Configs/`를 변경하거나 소스 파일을 추가한 뒤에는 `scripts/generate-project.sh`를 다시 실행하세요.

코드 서명 없이 Debug 앱을 빌드하세요.

```bash
xcodebuild \
  -project TablePro.xcodeproj \
  -scheme TablePro \
  -configuration Debug \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO \
  build
```

앱은 `~/Library/Developer/Xcode/DerivedData/TablePro-*/Build/Products/Debug/TablePro.app`에 생성됩니다.

서명된 앱을 빌드하고 실행하려면 Apple 개발 팀과 고유한 번들 식별자를 `Configs/Secrets.xcconfig`에 입력하세요. [개인 Apple 팀으로 빌드하기](CONTRIBUTING.md#building-with-a-personal-apple-team)를 참고하세요.

## 문서

전체 문서는 [docs.tablepro.app](https://docs.tablepro.app)에서 확인할 수 있습니다.

## 개발 후원

TablePro는 AGPLv3에 따라 무료로 제공됩니다. 업무에 사용한다면 [라이선스](https://tablepro.app)를 구매해 주세요. 모든 구매는 다음 릴리스 개발에 사용됩니다. 라이선스를 구매하기 어렵다면 무료 버전을 그대로 사용하세요. 그래서 TablePro는 무료입니다.

## 후원자

TablePro를 후원해 주신 모든 분께 감사드립니다.

**[getapps.cafe](https://getapps.cafe/?ref=SJO7-TgA)** · **[SimpleLocalize](https://simplelocalize.io?ref=tablepro)** · **[CodeRabbit](https://coderabbit.ai?ref=tablepro)** · **[Nimbus](https://getnimbus.io?ref=tablepro)** · **[Visnalize](https://visnalize.com?ref=tablepro)** · **[Dwarves Foundation](https://dwarves.foundation/?ref=tablepro)** · **[Huy TQ](https://github.com/imhuytq)** · **[Xermius](https://xermius.com?ref=tablepro)** · **[Unikorn](https://unikorn.vn?ref=tablepro)**

## 스타 히스토리

<a href="https://www.star-history.com/?repos=TableProApp%2FTablePro&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=TableProApp/TablePro&type=date&theme=dark&legend=top-left&sealed_token=rD14Ce48qCR6mXTi0zio-abLAcluGQrDOorFBPL8DAMnUeVFYI8giJJ8arDwTaB8BgpJfk3Y2y5hpIiAu4SBOg6e1_nW8xZ7OrTOFi7ykoGvxk30ycgvzwHW4E-skW0jp5QGttP1QvGgeu5xFrkVbvFa1OFSo_JwWr557R6RNg2hDXdFD7v7nwf_VnR1" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=TableProApp/TablePro&type=date&legend=top-left&sealed_token=rD14Ce48qCR6mXTi0zio-abLAcluGQrDOorFBPL8DAMnUeVFYI8giJJ8arDwTaB8BgpJfk3Y2y5hpIiAu4SBOg6e1_nW8xZ7OrTOFi7ykoGvxk30ycgvzwHW4E-skW0jp5QGttP1QvGgeu5xFrkVbvFa1OFSo_JwWr557R6RNg2hDXdFD7v7nwf_VnR1" />
   <img alt="스타 히스토리 차트" src="https://api.star-history.com/chart?repos=TableProApp/TablePro&type=date&legend=top-left&sealed_token=rD14Ce48qCR6mXTi0zio-abLAcluGQrDOorFBPL8DAMnUeVFYI8giJJ8arDwTaB8BgpJfk3Y2y5hpIiAu4SBOg6e1_nW8xZ7OrTOFi7ykoGvxk30ycgvzwHW4E-skW0jp5QGttP1QvGgeu5xFrkVbvFa1OFSo_JwWr557R6RNg2hDXdFD7v7nwf_VnR1" />
 </picture>
</a>

## 라이선스

이 프로젝트는 [GNU Affero General Public License v3.0(AGPLv3)](LICENSE)에 따라 라이선스가 부여됩니다.
