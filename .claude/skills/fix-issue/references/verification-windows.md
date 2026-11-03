# Verification traps: Windows

Read this when a `verify.sh` verdict needs interpreting for the Windows app, before writing a test, or when a `windows` check is red. The usage line is `verify.sh [--platform windows] [--root <tree>] [--run <dir>] [--offline] <step> [args] [-- <test options>]`; on a Windows shell the platform is this one unless the option names another. The steps and their arguments are in the header of `.claude/skills/fix-issue/scripts/lib/platform-windows.sh`.

## Why the wrapper, always

- `dotnet` finds `windows/global.json` only from `windows/` and below, and without it `dotnet test` refuses the test projects (`windows/AGENTS.md`, Commands). The wrapper runs every .NET step there.
- Microsoft.Testing.Platform prints one summary per `dotnet test` call and exits 8 when a filter runs nothing. The wrapper reads the counts from the summary, sums them, and reports a filter that ran nothing as INCONCLUSIVE.
- Cargo errors reach MSBuild as plain text, followed by `MSB3073: The command "cargo build ..." exited with code 101`, which says nothing on its own. The wrapper pairs each Cargo error with its location and names it.
- It builds the core with the flags `windows.yml` sets and the target triple the csproj names, so `build`, `test`, `core` and `bindings` share one Cargo build.

## Build

- **The build runs Cargo first.** `BuildCore` in `windows/src/TablePro.Interop/TablePro.Interop.csproj` runs `cargo build --locked -p tablepro-ffi --target <triple>` before any C#. A new Cargo target folder compiles every crate, DuckDB's C++ the longest of them; `CARGO_TARGET_DIR` points every tree at one folder so the core builds once.
- **`RUSTFLAGS=-D warnings` and `AWS_LC_SYS_PREBUILT_NASM=1`** are set by the wrapper when unset, as `windows.yml` sets them. A Rust warning fails the build as it fails CI. A `cargo` or `dotnet` run by hand without them rebuilds every crate in the same target folder.
- **A warning fails the build**: `TreatWarningsAsErrors`, the latest recommended analyzers and the `.editorconfig` style run in every project (`windows/Directory.Build.props`). That includes CA1416, the version floor's check.
- **On macOS and Linux the WinUI projects compile only.** `TablePro.Editor`, `TablePro.Graphics` and `TablePro.DataGrid` skip their PRI step off Windows. A build that passes on a Mac can still fail on Windows in the PRI or manifest steps, which the pull request's Windows jobs run.
- **The app and its UI tests build on Windows only** and sit outside the solution (`windows/AGENTS.md`, Commands). `app` and `ui` report INCONCLUSIVE elsewhere and name the CI jobs that run them.
- **A file in use on Windows.** A running `TablePro.exe` or test host holds its DLLs, and MSBuild's copy fails with MSB3027 or MSB3021. The wrapper reports it as INCONCLUSIVE; close the process.
- **The pinned Rust toolchain needs the Windows targets**: `rustup target add x86_64-pc-windows-msvc aarch64-pc-windows-msvc` once per checkout (`windows/docs/decisions/0001-toolchain-baseline.md`, Consequences).

## Tests

- **A filter that matches nothing exits 8**, "Zero tests ran". The wrapper reports it as INCONCLUSIVE; check the executed count anyway.
- **A bare filter word matches part of a test's full name**, namespace and class included, through `--filter-method "*<word>*"`. xunit's own options go after `--`: `--filter-class`, `--filter-trait "Needs=Core"`, `--filter-query`.
- **`TablePro.DataGrid.Tests` runs on Windows only.** Its csproj turns `IsTestProject` off elsewhere, so the solution's run on a Mac compiles it and runs the other four projects: fewer cases than CI counts on Windows.
- **The `Needs=Core` tests load the real core** that the build copied beside the test assembly. They run on every runner.
- **Cargo exits 101 for a compile error and for a failed test.** The `core` step tells them apart by whether a test binary ran. A filter that matches nothing exits 0 with "0 passed", which the wrapper reports as INCONCLUSIVE.
- **`core` passes `--target <host triple>`**, as the csproj and `core.yml` do, so it reuses the build instead of compiling the core again into `target/debug`.

## UI tests

- **They drive the real app through UI Automation (FlaUI)** and take the mouse and keyboard. `TABLEPRO_APP` names the built `TablePro.exe`, which the `ui` step finds under `windows/src/TablePro.App/bin/` for the SDK's runtime identifier; run `app` first.
- **Each launch gets a new data folder** through `TABLEPRO_DATA_DIR`, with its theme and row limit written into `settings.json`, so the user's connections never show and nothing carries over.
- **`windows/ci/desktop.ps1` is for hosted runners.** It writes a machine policy, stops system processes and changes the display mode. Never run it on a developer's machine.
- **Keys and clicks go through `AppSession`.** It brings the app to the front first, and `Chord`, `Click(element, landed)`, `Drag(..., landed)` and `TypeInto` try up to three times, waiting 5 seconds each for the app to show the input landed. A new test sends a shortcut with `Chord` and a `landed` check, never a bare `Keyboard.TypeSimultaneously`.
- **A drag goes through `SendInput`** (`PointerInput`). FlaUI moves the pointer with `SetCursorPos`, which WinUI does not take as a pointer moving with the button down.
- **UIA reads an empty Name as none.** WinUI reports an empty name as not supported, so FlaUI's `Name` throws `PropertyNotSupportedException`: it did once on x64, in run 41566360608. Read a name that can be empty through `Properties.Name.ValueOrDefault`.
- **`TablePattern.ColumnHeaders` is empty on Windows App SDK 2.6.4.** `CUIATableProviderWrapper::GetColumnHeaders` releases its SAFEARRAY before filling it; microsoft/microsoft-ui-xaml#11820 fixed it after 2.6.4. Read the headers from the header peers, or a cell's `TableItem` while its header is realized (`windows/docs/decisions/0003-data-grid-control.md`, Consequences).
- **The rest of what the runner showed** is in `windows/docs/decisions/0004-app-shell.md`, What the runner showed: an owned window is listed under its owner, a closed `InfoBar` stays in the tree, the Toolkit's clickable `SettingsCard` has no Invoke pattern, and a `ContentDialog` needs its page's theme. Read it before writing a UI test.

## Runner traps

These hold on GitHub's `windows-2025` and `windows-11-arm` images, where CI and any temporary workflow run.

- **The Arm64 privacy page.** The `windows-11-arm` image opens "Choose privacy settings for your device" over the desktop while the tests run, and it takes their clicks. `Clear-FirstLogon` in `windows/ci/desktop.ps1` turns the experience off by policy and stops its processes; it has to run before the UI tests.
- **The WSL console.** The image's provisioning agent runs `wsl.exe` every 30 seconds, and now and then its "update WSL" console opens over the app. `Start-WslWatch` stops each one for 20 minutes and logs what started it. A UI run that outlasts the 20 minutes is unguarded.
- **Dropped keystrokes and clicks on Arm64.** The runner's own windows take keys, drags and clicks now and then. That is why `AppSession` retries each input until the app shows it landed (UI tests, above). A failure screenshot that shows another window in front is this, not the change.
- **WARP timings vary from job to job.** The runners have no GPU, so Direct3D runs on WARP, and the CPU a job gets varies. The grid gate failed on Arm64 by one or two steps in three runs, while its UI thread got 67,000 cycles per ms against 2.1 million at the phase's median (`windows/docs/decisions/0003-data-grid-control.md`, Runner noise). Compare timings inside one job only, and rerun a starved step rather than raise a bar. That is why `windows-grid-gate.yml` runs by dispatch and never gates a merge.
- **Windows Server is not Windows 11.** `windows-2025` is Windows Server 2025: Vietnamese Telex stays raw there, in a stock TextBox too, while it composes on `windows-11-arm` (`windows/docs/decisions/0002-sql-editor-control.md`, Gate).

## Bindings

- **uniffi-bindgen-cs must be the exact version** the csproj names, `UniffiBindgenCsVersion`; `GenerateBindings` refuses another. The wrapper takes `UNIFFI_BINDGEN_CS`, then `~/.uniffi-bindgen-cs/bin/`, where `windows.yml` installs it, then `PATH`, and reports INCONCLUSIVE with no matching one. The install command is in `windows/AGENTS.md`, Bindings.
- **The step regenerates in place.** It keeps a copy of `Generated/` first and compares after. FAIL means the committed files were stale and the tree now holds the new ones: review and commit them with the FFI change, and a second run passes. A generator that fails leaves `Generated/` as it was.
- **The first `bindings` builds the core a second time.** `GenerateBindings` runs the `csbindgen` example with `cargo run` and no `--target`, so it compiles into `<target>/debug` beside the `<target>/<triple>/debug` the build uses: 11 minutes and 5.7 GB more on a Mac at two jobs.
- **CI checks the bindings on macOS only**, in the `windows / Windows (macOS)` job: it regenerates and fails on any change under `Generated/`.

## Reading CI

- `ci.yml` calls `windows.yml` when the `windows` suite changed (`.claude/rules/ci.md`). Its jobs are `windows / Windows (x64)`, `windows / Windows (Arm64)` and `windows / Windows (macOS)`. The Windows jobs test the solution, build the app, ready the desktop, run the UI tests and keep the screenshots; the macOS job tests the solution and checks the bindings. A change under `core/` also runs `core.yml` on the same runners.
- A failed job's tail: `gh run view --repo TableProApp/TablePro --job <job-id> --log-failed`. The screenshots, failure shots included: `windows-screenshots-x64` and `windows-screenshots-Arm64` (`references/platform-windows.md`, Screen). The UI tests' `TestResults/` and the WSL watch log are not uploaded.
- **Fork pull request runs need approval.** A push to a fork's pull request starts its workflow runs with conclusion `action_required`, and no job starts until a maintainer approves. Before the 45-minute rule in `SKILL.md`, Phase 7, applies, look for them:
  ```bash
  gh run list --repo TableProApp/TablePro --branch <branch> --json databaseId,conclusion -q '.[] | select(.conclusion == "action_required") | .databaseId'
  gh api -X POST repos/TableProApp/TablePro/actions/runs/<run-id>/approve
  ```
  Approving runs the fork's code on the repository's runners, so read what the push changed first.
- **The 150-minute job timeout is for a cold cache**, where DuckDB's C++ under MSVC takes most of the time. `Swatinem/rust-cache` keeps Cargo's artifacts, but DuckDB's unpacked sources come back as empty folders, which is why each job drops them first. A temporary workflow that restores the cache without that step fails in DuckDB's build script.
- **A UI failure on one architecture only** is often a runner trap above. Read the failure screenshot and the log first. A failure a runner trap explains gets one rerun; the same test failing again is the change.

## Worktrees

- `worktree.sh <branch> <base>` makes a plain tree for Windows work: it links only `apple/` files, which a Windows build does not read. NuGet restores into the user's package cache, which every tree shares.
- A tree builds into its own `windows/**/bin` and `obj`, and the core into `<tree>/target` unless `CARGO_TARGET_DIR` names a shared folder. Cargo's lock serializes two builds of one target folder, so `--no-wait` changes nothing.
- `worktree.sh --prune-merged` removes a tree with its `bin`, `obj` and `target`; a shared `CARGO_TARGET_DIR` stays.
