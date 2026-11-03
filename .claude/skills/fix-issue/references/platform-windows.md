# Platform: Windows

The native Windows app. Every profile has these seven sections in this order, so a value is always in the same place.

## Covers

- A report from Windows 10 or 11, on x64 or Arm64. The issue form's Platform field lists no Windows yet, so the `platform-windows` label or the reporter's own words name it.
- Code: `windows/`, the C# app on WinUI 3 with its interop library, the SQL editor and data grid controls and their tests (`windows/AGENTS.md`, Map).
- The core: the app reaches it through `core/crates/ffi` (`tablepro-ffi`), and a fix lands in whichever core crate holds the cause (`core/AGENTS.md`).
- A fix lands in one or more projects under `windows/src/` or crates under `core/crates/`; name them.

## Base

- Worktree base: `origin/main`.
- Pull request base: `main`.

## Done

- `windows/AGENTS.md`, plus the root `AGENTS.md` principles and writing style it points to. The per-change checklist is its Every change section. Under Claude Code, `windows/CLAUDE.md` loads it once a file under `windows/` is read; read it by path anyway in Phase 0. Codex loads it only when started in `windows/`.
- A fix in a core crate also follows `core/AGENTS.md`, Every change.
- The decisions in `windows/docs/decisions/` bind the app as the guide does: a fix that changes one says so and updates the record.

## Native standard

- WinUI 3 and Fluent, used as the Windows App SDK docs and the Windows design guidance on learn.microsoft.com describe, with the control WinUI or the Windows Community Toolkit already provides before anything drawn by hand (`windows/AGENTS.md`, Principles 2).
- The version floor is Windows 10 1809, build 17763: every Windows project sets `TargetPlatformMinVersion` and `SupportedOSPlatformVersion` to 10.0.17763.0.
- The build catches only part of what lies above the floor. CA1416 fails a call whose projection carries a `SupportedOSPlatform` above 17763. In the Windows SDK projection only some types carry one, none from `UniversalApiContract` 11 on, and Windows App SDK types carry none (`references/research-windows.md`, Windows platform; `windows/docs/decisions/0001-toolchain-baseline.md`, Why runtime checks).
- So an API above the floor gets a run-time check, and the plan names the fallback: `ApiInformation.IsApiContractPresent` or `IsTypePresent` for a Windows SDK API, the type's own check (`MicaController.IsSupported()`) for Windows App SDK behavior. Where CA1416 does fire, it accepts only `OperatingSystem.IsWindowsVersionAtLeast` as the guard, not `ApiInformation`.
- The Windows App SDK, Windows SDK build tools, TerraFX, Community Toolkit and test package versions are in `windows/Directory.Packages.props`; the .NET SDK is in `windows/global.json`; the Windows SDK the projection comes from is the target framework, `net10.0-windows10.0.26100.0`.
- Sources, the API ground truth and how to measure on a Windows runner: `references/research-windows.md`.

## Verify

Pass `--platform windows`, which a Windows shell (Git Bash, MSYS2, Cygwin) picks by default. The .NET steps run in `<tree>/windows`; `core` runs at the top of the tree.

| Step | When |
| --- | --- |
| `build` | always: the solution, with the core built first |
| `test <project> [filter]` | always, for each test project that covers what you changed |
| `test` | before the pull request: every test project in the solution, as CI runs them |
| `core [package] [filter]` | `core/crates/ffi` or a core crate changed; `tablepro-ffi` unless a package is named |
| `bindings` | the FFI crate's exported API, its UniFFI items or `src/window_abi.rs` changed |
| `app` | Windows only: anything under `windows/src/TablePro.App` changed, before `ui` |
| `ui [filter]` | Windows only: the change is visible in the app, or a flow the UI tests cover changed |

- Pick tests by what you changed: `src/<Name>` has its tests in `tests/<Name>.Tests` where that folder exists. `TablePro.Graphics` is reached through `TablePro.DataGrid.Tests`, and `TablePro.Editor` and `TablePro.App` through the UI tests. A core crate has its tests in its own folder.
- On macOS or Linux, `build`, `test`, `core` and `bindings` run. `app`, `ui` and `TablePro.DataGrid.Tests` report INCONCLUSIVE there: the pull request's `windows / Windows (x64)` and `windows / Windows (Arm64)` jobs run them.
- There is no lint step: `windows.yml` runs none. `build` is the lint, since `windows/Directory.Build.props` turns on the latest recommended analyzers and the `.editorconfig` style with warnings as errors.
- Extra review pass: none beyond the security pass.
- Traps and remedies: `references/verification-windows.md`.

## Screen

- The screenshots come from the UI tests. `AppSession.Screenshot(name)` saves `<TABLEPRO_UI_SCREENSHOTS>/<theme>/<name>.png`, each test runs once in Light and once in Dark, and each launch gets a data folder of its own, so no real connection shows. A surface no test shows gets a UI test that shows it.
- On Windows, `verify.sh ui` sets `TABLEPRO_UI_SCREENSHOTS` to a folder beside its log and names it in the verdict. The tests take the mouse and keyboard, so leave the machine alone while they run.
- Elsewhere the shots come from CI. `windows.yml` uploads them from each runner as `windows-screenshots-x64` and `windows-screenshots-Arm64`, also when a test failed:
  ```bash
  run=$(gh run list --repo TableProApp/TablePro --branch <branch> --workflow CI --limit 1 --json databaseId -q '.[0].databaseId')
  gh run download "$run" --repo TableProApp/TablePro -n windows-screenshots-x64 -D <scratch>/shots/x64
  gh run download "$run" --repo TableProApp/TablePro -n windows-screenshots-Arm64 -D <scratch>/shots/arm64
  ```
- The before shots are the same artifacts from the last CI run on `main` whose `windows` jobs ran. A surface with no test yet gets its before shot from a temporary branch that adds only the test (`references/research-windows.md`, Measuring on the runners).
- When an `AppSession` wait gives up, it saves `failure-<time>.png` beside the shots: look at it before reading the log.

## Ship

- `windows/` has no `changelog.d/` yet, and `.claude/rules/changelog.md` gives a fragment folder only to `apple/` and `linux/`. A change only the Windows app shows adds no fragment, and never one in another app's folder. A core change another app shows adds that app's fragment (`core/AGENTS.md`, Every change).
- Commit scope `windows`, or `windows-<area>` for one area of the app.
- Regenerated bindings ship in the same commit as the FFI change that made them (`windows/AGENTS.md`, Bindings).
- A probe worth keeping becomes a test in the project it measures: `windows/tests/` for the .NET side, the crate's `tests/` for the core. A fact measured on a runner goes in the decision that relies on it, with the run id, as `windows/docs/decisions/0004-app-shell.md`, What the runner showed, does. A temporary branch or workflow never merges.
