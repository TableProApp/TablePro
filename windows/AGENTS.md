# TablePro for Windows

The native Windows app: C# on .NET 10, WinUI 3 on the Windows App SDK, Fluent Design. It shares no code with the macOS or Linux apps.

This is the guide for work under `windows/`. The root `AGENTS.md` holds the rules every app shares. Claude Code loads this file through `windows/CLAUDE.md` once a file under `windows/` is read; Codex reads it when started in `windows/`.

## Principles

1. **Tests define behavior**, as in the root `AGENTS.md`.
2. **Native only.** WinUI 3 controls and the Fluent theme resources before anything drawn by hand. No web views. The data grid and the editor are custom because no WinUI control meets their performance needs; ARCHITECTURE.md says why.
3. **One-directional projects.** `TablePro.Core` references no other project and no UI. A new engine is one `TablePro.Drivers.*` project and one `Register` call in `App.CreateDriverRegistry`.
4. **No database work on the UI thread.** Sessions yield to the thread pool before touching a provider; keep it that way in new code.
5. **Values are bound, never spliced.** SQL built from user input goes through `SqlDialect.QuoteIdentifier` for names and parameters for values.

## Map

- `src/TablePro.Core`: domain types, the driver contract, the SQL lexer, splitter, classifier, formatter and completion, the ADO.NET session base.
- `src/TablePro.Storage`, `src/TablePro.Ssh`, `src/TablePro.Ai`, `src/TablePro.Mcp`: persistence, OpenSSH tunnels, the AI assistant, the MCP server. None of them references the UI.
- `src/TablePro.Drivers.*`: one project per engine.
- `src/TablePro.App`: the WinUI app. `Services/AppHost.cs` owns windows and shared services, `Views/` holds windows and tabs, `ViewModels/` their state, `Controls/` the data grid, the SQL editor and the splitter.
- `tests/`: one xunit.v3 project per library. `tests/Directory.Build.props` holds what every test project shares.
- `ARCHITECTURE.md` and `ROADMAP.md` are the reference.

## Commands

From `windows/`:

```powershell
dotnet build TablePro.slnx
dotnet test TablePro.slnx
dotnet run --project src/TablePro.App
```

The XAML compiler fails on paths longer than 260 characters; build from a short checkout path.

## Live tests

Driver tests that need a server skip unless a variable names one. `tests/live/compose.yaml` starts the servers with throwaway passwords (`TablePro-test-1`), one profile at a time because several want gigabytes of memory; Oracle and SQL Server run alone:

```powershell
docker compose -f tests/live/compose.yaml --profile kv up -d --wait     # then set the variables below and dotnet test
docker compose -f tests/live/compose.yaml --profile kv down -v
```

| Profile | Variables |
|---|---|
| `kv` | `TABLEPRO_REDIS=localhost:6379`, `TABLEPRO_REDIS_PASSWORD=TablePro-test-1`, `TABLEPRO_REDIS_CLUSTER=localhost:7001,localhost:7002,localhost:7003`, `TABLEPRO_REDIS_SENTINEL=localhost:26379`, `TABLEPRO_MONGODB=localhost:27017`, `TABLEPRO_ETCD_ENDPOINT=localhost:2379`, `TABLEPRO_DYNAMODB=http://localhost:8000`, `TABLEPRO_KAFKA_BOOTSTRAP=localhost:9092`, `TABLEPRO_LIBSQL_URL=http://localhost:8080` |
| `wide` | `TABLEPRO_CASSANDRA=localhost:9042`, `TABLEPRO_CLICKHOUSE=host=localhost;port=8123;user=tablepro;password=TablePro-test-1;database=tablepro`, `TABLEPRO_TEST_TRINO=localhost:8081` |
| `search` | `TABLEPRO_TEST_ELASTICSEARCH_URL=http://localhost:9200` with `_USER=elastic` and `_PASSWORD`; `TABLEPRO_TEST_TYPESENSE_URL=http://localhost:8108` with `_PASSWORD`; `TABLEPRO_TEST_WEAVIATE_URL=http://localhost:8082`; `TABLEPRO_TEST_SURREALDB_URL=http://localhost:8001` with `_USER=root`, `_PASSWORD` and `_DATABASE=tablepro/tablepro`; `TABLEPRO_TEST_SPANNER_EMULATOR=localhost:9010` with `TABLEPRO_TEST_SPANNER_DATABASE` set to what `tests/live/spanner-setup.ps1` prints |
| `sql` | `TABLEPRO_POSTGRES=host=localhost;port=5432;user=postgres;password=TablePro-test-1;database=tablepro`, `TABLEPRO_MYSQL` the same with `port=3306;user=root`, `TABLEPRO_MARIADB` with `port=3307;user=root` |
| `oracle` | `TABLEPRO_ORACLE=host=localhost;port=1521;user=tablepro;password=TablePro-test-1;database=FREEPDB1`, and `TABLEPRO_ORACLE_ADMIN` the same with `user=system` |
| `sqlserver` | `TABLEPRO_SQLSERVER=host=localhost;port=1433;user=sa;password=TablePro-test-1;database=tablepro`, after `CREATE DATABASE tablepro` through `sqlcmd` in the container |

`tests/TablePro.Drivers.Tests/Live/RelationalServerTests.cs` is the suite every relational engine runs: catalog, paged and filtered browse, saves, structure edits, scripts, cancel, plans, activity, users and the multi-table change transaction. A new relational engine derives a class from it. Dameng, Teradata, SAP HANA and the cloud services have no local image, or need a vendor ODBC driver, so their variables point at a real server.

## Code style

`Directory.Build.props` and `.editorconfig` are the source of truth: warnings are errors, the latest recommended analyzers are on, nullable is on, namespaces are file-scoped and private fields are `_camelCase`. Package versions live only in `Directory.Packages.props`. Beyond them:

- Comments say why, never what, as in the root guide.
- Prefer `x:Bind` over `{Binding}`; a window-level `x:Bind` cannot use a converter, so bind through a typed adapter property instead.
- Code-built UI uses the Fluent theme brushes (`ThemeResources.Brush`), never literal colors, so light, dark and high contrast follow Windows.
- An icon-only button carries `AutomationProperties.Name`.
- User-facing text is never written in code or XAML. In the app it lives in `src/TablePro.App/Strings/<language>/<Area>.resw`: `x:Uid="/Area/Name"` in XAML, `Strings.Get`, `Strings.Format` and `Strings.Plural` in code. In the libraries it lives in `src/<Project>/Resources/<Area>.resx` plus one `<Area>.<language>.resx` per language, read through the project's accessor (`CoreStrings`, `StorageStrings`, `RedisStrings`...) with the same `Area/Name` keys; phrases drivers share go in Core's `Driver` area. A new English key needs a value in every language; `LocalizationTests` and `LibraryLocalizationTests` in `TablePro.Core.Tests` check keys, placeholders, leftover XAML literals and English left in library throws. SQL, engine names, file names, server text, log text, AI prompts and MCP output stay English. ARCHITECTURE.md, Localization, has the details.

## Every change

1. **Tests.** A unit test for testable behavior; a driver change gets a test against SQLite or DuckDB files, or a connection-string and DDL test for the network engines.
2. **Roadmap.** A feature that lands or a gap that is found updates `ROADMAP.md`.
3. **Commits and pull requests** follow the root rules: Conventional Commits with scope `windows` or `windows-<area>` (for example `windows-grid`, `windows-editor`), and the root `.github/pull_request_template.md`.
