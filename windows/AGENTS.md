# TablePro for Windows

The Windows app: C# on .NET 10 with WinUI 3, for Windows 10 1809 and later and Windows 11, on x64 and Arm64, over the shared Rust core in `core/` (`core/AGENTS.md`). This folder holds the app, the interop library it reaches the core through, the SQL editor and data grid controls, and their tests.

This is the guide for work under `windows/`. The root `AGENTS.md` holds the rules every app shares. Claude Code loads this file through `windows/CLAUDE.md` once a file under `windows/` is read; Codex reads it when started in `windows/`.

## Principles

1. **Tests define behavior**, as in the root `AGENTS.md`.
2. **Native only.** WinUI 3 controls, used as the Fluent guidance describes. No custom control where WinUI has one, no web view, no cross-platform toolkit. The SQL editor is our own control because RichEditBox failed its gate (`docs/decisions/0002-sql-editor-control.md`), and the data grid because WinUI has none (`docs/decisions/0003-data-grid-control.md`).
3. **The core does the work.** Drivers, sessions, the catalog, result sets and error codes live in `core/`. This folder words, lays out and styles. What the core lacks is added there, with its Rust tests.
4. **Nothing generated is edited.** `src/TablePro.Interop/Generated/` changes only through the generator (Bindings, below).

## Map

- `TablePro.slnx`: the solution. `global.json`: the .NET 10 SDK, and Microsoft.Testing.Platform as the runner `dotnet test` uses. `Directory.Build.props`: nullable, warnings as errors and the latest recommended analyzers for every project. `Directory.Packages.props`: every package version. `.editorconfig`: the C# style.
- `src/TablePro.Interop`: the library the app calls. Its public API is hand-written; `Generated/` holds the uniffi-bindgen-cs and csbindgen output, all `internal`, so a generator upgrade cannot change what the app sees. The project is AOT and trim compatible, and its analyzers fail the build otherwise.
- `tests/TablePro.Interop.Tests`: xunit v3 tests against the real core and real SQLite files.
- `src/TablePro.Editor.Model`: the editor's text, carets, undo history, find and line-state highlighter. Plain `net10.0` with no WinUI, so `tests/TablePro.Editor.Model.Tests` runs anywhere.
- `src/TablePro.Graphics`: the one text and drawing stack the controls share: Direct3D, Direct2D and DirectWrite through TerraFX, the editor's swap chain and line layouts, theme colors, and the font fallback warm-up. Its types are internal to the controls.
- `src/TablePro.Editor`: the `SqlEditor` control over that model: Direct2D and DirectWrite in a SwapChainPanel, TSF, the UIA text provider, and the core's lexer through `CoreSqlLexer`.
- `src/TablePro.DataGrid.Model`: the grid's columns, selection, keys, cell blocks read from the core (`ResultSetData`), pending edits laid over them (`EditedGridData`) and Excel-style copy. Plain `net10.0`, so `tests/TablePro.DataGrid.Model.Tests` runs anywhere; its `Needs=Core` tests load the real core.
- `src/TablePro.DataGrid`: the `DataGridView` control: ItemsRepeater rows that draw their cells with DirectWrite into composition surfaces, frozen columns, the header row, in-place cell editing with pending-change marks, and UIA peers.
- `tests/TablePro.DataGrid.Tests` and `tests/TablePro.Editor.Tests`: each control in a real WinUI window on a thread of its own, the app and window from `tests/Shared/WinUiApp.cs`. They run on Windows and only compile elsewhere.
- `tests/TablePro.DataGrid.Gate` and `tests/TablePro.DataGrid.Gate.Uia`: the grid's timing and behavior gate, outside the solution. `ci/run-gate.ps1` builds and runs it; `.github/workflows/windows-grid-gate.yml` runs it by dispatch.
- `src/TablePro.App`: the WinUI app: one window, the rail, the Connections page, the connection form window, Settings and a workspace per connection (`docs/decisions/0004-app-shell.md`). Strings are in `Strings/en-US/Resources.resw`.
- `src/TablePro.App.Model`: the app's settings and session files, the library tree, the connection form's fields, the object folders, the tab and connection lifecycles over small session, editor and run interfaces, and a table tab's pending edits. Plain `net10.0`, so `tests/TablePro.App.Model.Tests` runs anywhere.
- `tests/TablePro.App.UITests`: UI Automation tests (FlaUI) that launch the built app with a data folder of their own, and the installed MSIX once `TABLEPRO_PACKAGE` names its family.
- `ci/desktop.ps1`: readies a hosted runner's desktop for UI work (privacy settings window, WSL console, display size, window dragging), for `windows.yml`, `release-windows.yml` and the grid gate.
- `ci/winget-manifest.py`: writes a release's winget manifest, for `release-windows.yml`.
- `scripts/engine-glyphs.py`: writes `src/TablePro.App/Resources/EngineGlyphs.xaml` from the macOS app's engine artwork. Run it after that artwork changes or an engine is added.
- `scripts/package-assets.py`: writes the MSIX logos in `src/TablePro.App/Assets` from the app icon. Run it after the icon changes.
- `RELEASING.md`: how a release is built, signed, published and sent to winget.
- `docs/decisions/`: the decisions only the Windows app makes.
- The core's side of the boundary: `core/crates/ffi` (`core/ARCHITECTURE.md`, Bindings).

## Using the interop library

- Every async call starts on the thread pool, because the generated code finishes a call on the thread that awaits it. Its continuation comes back to the caller's context as usual.
- A `CancellationToken` fires the core's own cancel token, since UniFFI cannot cancel a call. A cancelled call throws `OperationCanceledException`; a failed one throws `TableProException`, whose `Code` the app words. A statement the server refused is not an exception: the run ends `QueryOutcome.Failed`.
- `QueryEditor.Run` returns at once. Read the run's events with `ReadEventsAsync` on the UI thread; rows that arrive while it is busy come as one event.
- A grid reads a `ResultSet` through `ResultCursor.Fetch`, one window per visible range. A cursor belongs to one thread, and a window cannot be read after the cursor's next fetch.
- `DataGridView.SetData(new ResultSetData(set, columns))` shows a set. Call the grid's `RowsChanged` after each `RowsAppended`. Sorting is the host's: the grid raises `SortRequested` and shows `Sort`.
- The core writes every sorted statement: `ReadTablePageAsync` reads a table's page with its sort and filter on a pooled connection and returns its run, `SortedQuery` writes a query result's, null when the statement cannot run again or the engine cannot name the column. `ResultSet.SortedAsync` then sorts the rows held (`core/docs/decisions/0007-sorting-a-result.md`). `ReadTablePageAsync` takes the page's offset, and `CanSeek` says whether the engine has later pages; `CountRowsAsync` counts the rows the filter picks, and `EstimateRowsAsync` gives the whole table's count from the engine's statistics, null where it keeps none. The filter's values are bound by the core, never written into SQL here (`core/docs/decisions/0022-browsing-through-the-ffi.md`).
- `GetStructureAsync` gives a table's columns, indexes, foreign keys and CREATE script, `GetObjectDefinitionAsync` a routine's, trigger's or sequence's source, `ExportRowsAsync` and `ExportTableAsync` write a file through the core's encoders, and `TableProCore.OpenHistoryAsync` the query history, which withholds what the engine says holds a secret.
- A table tab edits through `DatabaseSession.OpenTableEditorAsync`: the app sends what was typed (`CellEdit`) per row of the page's `ResultSet`, and `TableEditor.Plan` gives a `RowSave` with its statements and Safe Mode gate, which `RunAsync` saves (`core/docs/decisions/0019-row-edits-through-the-ffi.md`).
- `QueryEvent.Finished.Transaction` is the transaction the editor's connection is left in. A session's `Health` is waited on with `WaitForHealthChangeAsync`, which returns once it differs from the one passed in.
- The app starts the core with `TableProCore.CreateWithSystemSecrets`, so the core keeps secrets in Credential Manager itself. `ISecretStore` is for tests and hosts with a store of their own; the core calls it on a thread of its own.
- `TableProCore.Library` reads and writes the saved connections in the storage directory the configuration names. A list the app shows is rebuilt from `GetSnapshotAsync` after each change.
- A result share's columns start from `ResultSet.GetShareMaskingAsync` (what the detectors see), `GetShareSummaryAsync` says what a share with the sheet's choices sends and `GetSharePreviewAsync` shows it masked as sent; `CreateShareAsync` takes the same choices. Nothing else masks (`docs/decisions/0010-data-masking.md`).
- `TableProCore.OpenAccountAsync` opens the TablePro account once per app; `ReadStatusChangesAsync` gives its status on the UI thread, and its share calls (`GetShareLimitsAsync`, `CreateShareAsync` from a finished `ResultSet`, `ListSharesAsync`, `RevokeShareAsync`, `ExtendShareAsync`, `FetchSharedAsync`) throw `account.*` codes. `ShareLinks` holds the core's secret scan and deep link rule (`docs/decisions/0008-tablepro-account.md`, `docs/decisions/0009-share-links.md`).

## Commands

Run `dotnet` from `windows/`: `global.json` is found only from here, and without it `dotnet test` refuses the test project.

```bash
dotnet build TablePro.slnx
dotnet test --solution TablePro.slnx
```

On macOS the solution builds `TablePro.Editor` as a compile check only: WinUI's PRI and manifest tools run on Windows.

The app and its UI tests build on Windows only, so they sit outside the solution. The UI tests run the Native AOT publish, as CI does:

```bash
dotnet build src/TablePro.App -r win-x64 -p:Platform=x64
dotnet publish src/TablePro.App -c Release -r win-x64 -p:Platform=x64 -p:CargoProfile=dev
TABLEPRO_APP="$PWD/src/TablePro.App/bin/x64/Release/net10.0-windows10.0.26100.0/win-x64/publish/TablePro.exe" dotnet test --project tests/TablePro.App.UITests
```

Use `win-arm64` and `ARM64` on Arm64. `dotnet build` makes a JIT build for the debugger; `dotnet publish` compiles with Native AOT, and a trim or AOT warning fails it. Both run unpackaged with the Windows App SDK beside them and keep their files in `%LOCALAPPDATA%\TablePro`, or in `TABLEPRO_DATA_DIR`; the UI tests give each launch a new folder there. `-p:WindowsPackageType=MSIX -p:GenerateAppxPackageOnBuild=true` with `dotnet publish` makes the MSIX, as `RELEASING.md` does, signed with `-p:PackageCertificateThumbprint=` and a certificate whose subject is `CN=TablePro Development`. `TABLEPRO_UI_SCREENSHOTS` names a folder for the tests' light and dark screenshots.

The build runs `cargo build -p tablepro-ffi` for the runtime identifier, or for the SDK's own platform when none is given, and copies the library next to the assembly. `-r win-x64` or `-r win-arm64` picks the target, `-c Release` builds the core with Cargo's release profile unless `-p:CargoProfile=` names another, `CARGO_TARGET_DIR` is honoured, and `-p:SkipCoreBuild=true` leaves cargo out. On Windows the core links the hybrid CRT, so `RUSTFLAGS` gains `CoreRustFlags` from `src/TablePro.Interop/TablePro.Interop.csproj` (`docs/decisions/0005-distribution.md`). Building needs the Rust toolchain that `rust-toolchain.toml` names, with the target added, and the .NET 10 SDK; on Windows, MSVC.

The core's Rust tests: `cargo test -p tablepro-ffi`, from the top of the repository.

`.claude/skills/fix-issue/scripts/verify.sh --platform windows <step>` runs these with a verdict; its steps and when each runs: `.claude/skills/fix-issue/references/platform-windows.md`, Verify.

## Bindings

The generated files are committed: the API change is reviewed in the pull request, a build needs no generator, and an editor knows the types before the first build. CI's macOS job generates them again and fails when they differ.

After a change to the FFI crate's exported API, its UniFFI items or `src/window_abi.rs`, generate them and commit the result:

```bash
cargo install uniffi-bindgen-cs --locked --git https://github.com/NordSecurity/uniffi-bindgen-cs --tag v0.11.1+v0.31.0
dotnet msbuild src/TablePro.Interop -t:GenerateBindings
```

Pass `-p:UniffiBindgenCs=<path>` when it is not on `PATH`; the target refuses another version. uniffi-bindgen-cs supports one UniFFI minor, 0.31, so it and the core's `uniffi` move together. Its settings are in `core/crates/ffi/uniffi.toml`, and csbindgen runs as the crate's `csbindgen` example.

## Every change

1. **Tests.** Behavior of the interop library gets a test in `tests/` against a real database file. Behavior of the core gets its Rust test in `core/crates/ffi`.
2. **Code style.** `.editorconfig` and the analyzers; a warning fails the build. A comment is one `//` line that says why, never what: no XML doc and no multi-line block.
3. **Commits and pull requests** follow the root rules, with scope `windows` or `windows-<area>`.

## CI

`.github/workflows/windows.yml`, which `ci.yml` calls when the `windows` suite changed (`.claude/rules/ci.md`). It builds the core and runs the tests on x64, Arm64 and macOS runners, publishes the app with Native AOT and runs its UI tests on the Windows runners with their screenshots as an artifact, and on macOS checks the committed bindings. CI's Lint job runs zizmor on every workflow. `.github/workflows/release-windows.yml` builds and ships a release (`RELEASING.md`).
