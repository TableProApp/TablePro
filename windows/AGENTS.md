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

## Code style

`Directory.Build.props` and `.editorconfig` are the source of truth: warnings are errors, the latest recommended analyzers are on, nullable is on, namespaces are file-scoped and private fields are `_camelCase`. Package versions live only in `Directory.Packages.props`. Beyond them:

- Comments say why, never what, as in the root guide.
- Prefer `x:Bind` over `{Binding}`; a window-level `x:Bind` cannot use a converter, so bind through a typed adapter property instead.
- Code-built UI uses the Fluent theme brushes (`ThemeResources.Brush`), never literal colors, so light, dark and high contrast follow Windows.
- An icon-only button carries `AutomationProperties.Name`.

## Every change

1. **Tests.** A unit test for testable behavior; a driver change gets a test against SQLite or DuckDB files, or a connection-string and DDL test for the network engines.
2. **Roadmap.** A feature that lands or a gap that is found updates `ROADMAP.md`.
3. **Commits and pull requests** follow the root rules: Conventional Commits with scope `windows` or `windows-<area>` (for example `windows-grid`, `windows-editor`), and the root `.github/pull_request_template.md`.
