# Architecture

TablePro Windows is a .NET solution of small projects with one-directional references. The shape follows the Linux app's: adding a database engine touches one project, replacing the UI would touch one project, and the domain layer imports neither.

## Projects

```
windows/
├── TablePro.slnx                  solution
├── global.json                    .NET SDK pin
├── Directory.Build.props          language version, nullable, analyzers, warnings as errors
├── Directory.Packages.props       every NuGet version, in one place
├── src/
│   ├── TablePro.Core/             domain types, the driver contract, SQL lexing and generation, no UI and no I/O
│   ├── TablePro.Storage/          connections, settings, history, favorites, workspace state, Credential Manager
│   ├── TablePro.Ssh/              OpenSSH tunnels and the Job Object that ends them
│   ├── TablePro.SshAskPass/       the askpass helper ssh runs for password logins
│   ├── TablePro.Ai/               AI providers, prompts and the assistant's access policy
│   ├── TablePro.Mcp/              the MCP server: transport, token, tools
│   ├── TablePro.Drivers.PostgreSql/   Npgsql
│   ├── TablePro.Drivers.MySql/        MySqlConnector, MySQL and MariaDB
│   ├── TablePro.Drivers.SqlServer/    Microsoft.Data.SqlClient
│   ├── TablePro.Drivers.Sqlite/       Microsoft.Data.Sqlite
│   ├── TablePro.Drivers.DuckDb/       DuckDB.NET
│   └── TablePro.App/              WinUI 3 application: windows, views, view models, controls
└── tests/                         one xunit.v3 project per library
```

## Dependency rules

| Project | References |
|---|---|
| `Core` | no project |
| `Storage`, `Ssh`, `Ai`, `Mcp` | `Core` |
| `Drivers.*` | `Core` only. Drivers never reference each other |
| `App` | every project above |

- `Core` holds the domain types and contracts and does no I/O beyond the ADO.NET base class drivers derive from. It targets plain `net10.0` and is marked AOT compatible.
- `App` is the only project that names every driver. `App.CreateDriverRegistry` is the composition root, as `build_registry` is on Linux: an engine is one project plus one `Register` call. There is no plugin loading.
- `Mcp` reaches the windows and the user through `IMcpHost`, which `AppHost` implements; it never references the UI.

## The driver contract

`IDatabaseDriver` opens an `IDatabaseSession` from a `ConnectionRequest`. The request carries the profile and where to dial, so an SSH tunnel replaces the host and port without the driver knowing.

An `IDatabaseSession` serves the sidebar, table tabs and saves from the provider's connection pool. Each editor tab asks it for an `IQueryChannel`, a dedicated connection, so a transaction, a `SET` or a temporary table stays with the tab that made it.

`AdoNetSession` in `Core/Data` implements the session once over ADO.NET. An engine supplies how to open a connection and how to read its catalog: databases, schemas, objects, columns, indexes, foreign keys, triggers and definitions. Paging, filtering, counting, saving and running scripts are shared. Optional features are interfaces a session may also implement, found with a type test: `ISchemaDdlProvider`, `ITableDetailsProvider`, `IServerActivityProvider`, `IServerVariablesProvider`, `IUserListProvider`, `IUserAdministration`, `IDatabaseAdministration`, `IKeySearchProvider`, `IChangePreviewProvider` and `IRoutineDebugger`. `TablePro.Ssh` also holds the proxy forwarder, the helper-program tunnels (Cloud SQL, cloudflared, a tunnel command) and cloud sign-in tokens.

Every public session method yields to the thread pool before it touches the provider, because SQLite and DuckDB complete their "async" methods synchronously and the UI thread must never wait on a database.

## SQL handling

One lexer, `SqlLexer`, reads SQL for every purpose: splitting scripts, highlighting, completion, formatting, Safe Mode classification and parameter substitution in previews. It is a `ref struct` over a `ReadOnlySpan<char>` and allocates nothing. Each `SqlDialect` names its lexical features (backtick or bracket names, dollar quotes, hash comments, backslash escapes, nested comments) and how its scripts split:

| Dialect | Splits at | Kept whole |
|---|---|---|
| PostgreSQL, DuckDB | `;` | dollar-quoted bodies |
| MySQL, MariaDB | `;`, or the delimiter a `DELIMITER` line sets | |
| SQL Server | a `GO` line, with an optional count | the whole batch |
| SQLite | `;` | a `CREATE TRIGGER ... BEGIN ... END` body |

`StatementClassifier` decides what a statement does for Safe Mode and history. A write hidden behind a read counts as a write: `EXPLAIN ANALYZE DELETE`, `WITH ... INSERT`, `SELECT ... INTO`, and a SQL Server batch with a `DROP` after a `SELECT`.

Values from the grid and the filter strip are always bound as parameters. `ChangeSqlBuilder` and `FilterSql` never splice a value into SQL text; identifiers go through `SqlDialect.QuoteIdentifier`.

## Threading

The UI thread owns every element. View models are created on it and their `async` methods resume on it, so they update observable properties without dispatching. Database work runs on the thread pool, reached through the session's own yield. Store events (`ConnectionStore.Changed`, `SettingsStore.Changed`) fire on the saving thread, and their UI subscribers enqueue onto their `DispatcherQueue`.

## Windows

`AppHost` owns the windows, as the Linux app's `TableProApplication` does:

- `WelcomeWindow`, the connection picker, opens at launch and whenever no workspace is open.
- A `WorkspaceWindow` per connection, as on macOS: the sidebar of objects, a `TabView` of editors, tables, the server dashboard and diagrams, and a side pane for the value inspector, history, favorites and the AI assistant.
- `SettingsWindow`, laid out as Windows Settings is.

Each window draws its own title bar over the backdrop (`WindowChrome`), with acrylic as the default material and Mica, Mica Alt or none in Settings. The content sits on the Fluent layer brushes, so light, dark and high contrast follow Windows.

## The data grid

`DataGridView` shows every result, table page and structure list. It is written for large results rather than built on a list control:

- Rows and columns are both virtualized by hand on one canvas. Row height is fixed, so the visible range, every hit test and every scroll target are arithmetic.
- A realized row is a `GridRowPresenter` holding pooled text slots for the visible columns only. A slot skips any property write whose value has not changed, since each write crosses into the XAML runtime.
- The selection is one rectangle however many rows it spans, and the focused cell another.
- Values are formatted only when a cell becomes visible (`CellFormatter.FormatForCell`), from rows stored as the provider returned them.
- Editing goes through `IGridSource`. A table tab's `EditableGridSource` wraps a `TableEditBuffer`, which keeps changed cells, inserted rows and deleted rows with undo and redo until a save runs them in one transaction. A keyed change that hits other than one row rolls the whole save back.

## The SQL editor

`SqlEditor` is a `RichEditBox` colored by the dialect's lexer, debounced after typing. Its built-in undo is off, because every coloring pass would become an undo step; the editor keeps its own stack of text snapshots, grouping keystrokes typed within half a second. Line ends are `\r` inside the document, as RichEdit stores paragraphs, so the lexer's offsets and the caret agree without translation. Completion (`SqlCompletion` in Core) offers columns after an alias, tables after `FROM` and `JOIN`, and keywords, functions and the statement's columns elsewhere.

## Localization

The app ships the languages the macOS app does: English, French, Korean, Turkish, Vietnamese, and Simplified and Traditional Chinese. Text is in `.resw` files under `src/TablePro.App/Strings/<language>/`, one per area (`Connection.resw`, `Table.resw`...), compiled by MRT Core into the app's PRI, which works unpackaged and in the MSIX. Each file is a resource map, so a key is `Area/Name` in code and `x:Uid="/Area/Name"` in XAML. `Strings.Plural` picks `Name_One` or `Name_Other` by the language's plural rule, since resw has no plural forms. Settings > General stores a language override, which `App.OnLaunched` applies through `ApplicationLanguages.PrimaryLanguageOverride` before the first window; XAML and MRT Core read it once, so a change asks for a restart. `AppLanguages.Apply` also sets `CultureInfo.DefaultThreadCurrentUICulture` and `CurrentUICulture`, so thread-pool work speaks the same language.

The libraries cannot use MRT Core, which needs the app's PRI, so the text Core, Storage, Ssh, Ai and the drivers compose is in standard .NET resources: `src/<Project>/Resources/<Area>.resx` in English and `<Area>.<language>.resx` beside it, built into satellite assemblies (`fr/TablePro.Core.resources.dll`...). Each project reads them through a small accessor with the app's shape, `CoreStrings`, `StorageStrings`, `RedisStrings` and so on, over `Core/Localization/ResourceStrings`: a key is `Area/Name`, lookup follows `CurrentUICulture` and falls back to English, and numbers in a message follow `CurrentCulture`. `CoreStrings` is public because its `Driver` area holds the phrases drivers share (timeouts, read-only refusals, unsupported operations), so most drivers carry no resources of their own; a driver gets its own area only for text that is truly its own. `PluralRules` lives in Core and serves both `Strings.Plural` and the libraries' `Plural`. `NeutralLanguage` is en-US, and `SatelliteResourceLanguages` in `Directory.Build.props` keeps package satellites to the shipped languages; the libraries' satellites ship in the unpackaged folder and in the MSIX.

What stays English: SQL and identifiers, engine and product names, log text, text a server or cloud service sends (wrapped in a translated sentence where TablePro adds context), prompts sent to AI models, and MCP. `McpProtocolHandler` sets the invariant UI culture for each request, so tool results and errors reach AI clients in English whatever the app shows. Text stored for later, such as the rewind journal's summary, stores the counts and is worded when shown.

`LocalizationTests` and `LibraryLocalizationTests` in `TablePro.Core.Tests` check key parity, placeholders, plural pairs and that every key the code uses exists, and flag English left in a throw, a message property or a sentence literal in the libraries, against a short allow-list. Every test assembly runs in en-US (`tests/TestCulture.cs`), so tests that assert English pass on any machine.

## Storage

`TablePro.Storage` writes JSON through System.Text.Json source generation and replaces each file atomically. Secrets go to Windows Credential Manager through source-generated `LibraryImport` calls. Query history is a SQLite database with an FTS5 table for search. Missing JSON fields keep their declared defaults, so a file written by an older build still loads.
