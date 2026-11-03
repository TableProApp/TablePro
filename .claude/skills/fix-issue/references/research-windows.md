# Research sources: Windows

Where to find the correct behavior for the Windows app, and what counts as evidence for it. The method is in the research brief (`references/lanes.md`); this file is the sources.

## Windows platform

- **API ground truth: the metadata in the NuGet packages the build restores**, at the versions in `windows/Directory.Packages.props`. They are under `~/.nuget/packages/` (`%USERPROFILE%\.nuget\packages\` on Windows) once the solution has been built:
  - WinUI: `microsoft.windowsappsdk.winui/<version>/metadata/Microsoft.UI.Xaml.winmd`. Composition, windowing, input and backdrops: `Microsoft.UI.winmd` under `microsoft.windowsappsdk.interactiveexperiences/<version>/metadata/<sdk>/`. App model, resources and storage: `microsoft.windowsappsdk.foundation/<version>/metadata/`.
  - The native interop headers: `ISwapChainPanelNative` and `IWindowNative` in `microsoft.windowsappsdk.winui/<version>/include/`, and `ICompositorInterop`, whose IIDs differ from the system's, in `microsoft.windowsappsdk.interactiveexperiences/<version>/include/Microsoft.UI.Composition.Interop.h`.
  - Windows SDK WinRT types: `microsoft.windows.sdk.net.ref/<version>/lib/net8.0/Microsoft.Windows.SDK.NET.dll`. Each type carries its `ContractVersion`. 1809 is `UniversalApiContract` 7, so a higher contract version is above the floor. In 10.0.26100.57 only some types up to contract 10 (19041) also carry the `SupportedOSPlatform` that CA1416 reads, and none from 11 on.
  - Win32 and COM (Direct3D, DXGI, Direct2D, DirectWrite, TSF, user32): `terrafx.interop.windows/<version>/lib/net10.0/TerraFX.Interop.Windows.dll`, generated from the Windows SDK headers of its version.
  - The `.xml` beside each `.winmd` or `.dll` holds doc comments for only part of the API: `Microsoft.UI.Xaml.xml` in 2.6.4 has no entry for the `TitleBar` control the app uses. A symbol missing from it proves nothing.
- **Settle a symbol with the compiler.** It reads exactly these files, so a call that builds exists at the version we ship, and CA1416 reports the platform version where the projection declares one. Build the probe in the project that would use it, or in a scratch project with the same target framework, `TargetPlatformMinVersion` and `EnableWindowsTargeting`, which builds on a Mac too. To read attributes, load the type in a scratch console app and print `CustomAttributes`: that is how `GraphicsCaptureAccess` showed only `ContractVersion(UniversalApiContract, 12)`.
- **The Windows SDK headers**, for a Win32 or COM signature, a constant, or the version that introduced a function. They are in the `Microsoft.Windows.SDK.CPP` package for SDK 10.0.26100, the version TerraFX and the target framework name; about 160 MB:
  ```bash
  curl -sL -o <scratch>/sdk/sdk.nupkg https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.cpp/<version>/microsoft.windows.sdk.cpp.<version>.nupkg
  unzip -p <scratch>/sdk/sdk.nupkg c/Include/10.0.26100.0/um/WinUser.h | grep -n -B3 'GetDpiForWindow('
  ```
  A declaration sits under a guard such as `#if (NTDDI_VERSION >= NTDDI_WIN10_RS5)` or `#if(WINVER >= 0x0605)`. 1809 is `NTDDI_WIN10_RS5` in `shared/sdkddkver.h`, so a later guard is above the floor. On a Windows machine with the Build Tools they are in `C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0\`.
- **The web documentation runs ahead of the version we ship.** learn.microsoft.com documents the newest Windows App SDK, experimental APIs included. WinUI's `TableView` is in 2.5.4-experimental and not in 2.6.4 (`windows/docs/decisions/0003-data-grid-control.md`, Context). A page gives the intent; the metadata at our version settles whether TablePro can use it.
- **Fluent design guidance**: `https://learn.microsoft.com/en-us/windows/apps/design/`. For a database client the pages that matter most are layout, typography, color, commanding basics, app settings, title bar, keyboard and accessibility. Quote the rule; "the guidance says so" without a quote is not evidence.
- **Control pages**: `https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/`, one per control (title bar, navigation view, tab view, tree view, command bar, info bar, content dialog), each with when to use it and its keyboard and accessibility behavior.
- **API references**: the Windows App SDK at `https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/`, its release notes and supported Windows versions at `https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/`, the Windows SDK's WinRT at `https://learn.microsoft.com/en-us/uwp/api/`, Win32 at `https://learn.microsoft.com/en-us/windows/win32/api/`, UI Automation at `https://learn.microsoft.com/en-us/windows/win32/winauto/entry-uiauto-win32`, the Community Toolkit at `https://learn.microsoft.com/en-us/dotnet/communitytoolkit/windows/`, and CA1416 at `https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/quality-rules/ca1416`.
- **Behavior: the source.** WinUI is `github.com/microsoft/microsoft-ui-xaml`, the Windows App SDK `github.com/microsoft/WindowsAppSDK`, the Community Toolkit `github.com/CommunityToolkit/Windows`. Read the code a control runs, as ADR 0003 read ItemsRepeater's `ViewManager` for its traps, and check that a fix you find is in the release we ship: microsoft/microsoft-ui-xaml#11820 fixed `TablePattern.ColumnHeaders` after 2.6.4. Search the issues for the symptom before building a workaround.
- **TablePro's own decisions** in `windows/docs/decisions/` and `core/docs/decisions/`: a fix must not contradict a recorded decision without saying so. Their "What the runner showed" and Gate sections are measured facts; start there.

## Dependencies

The source is the package or crate as built, not a web page.

- .NET package versions are in `windows/Directory.Packages.props`, with transitive pinning on; the SDK is in `windows/global.json`. Read a package's source at the tag of that version: FlaUI, xunit v3, TerraFX, the Community Toolkit.
- The core's crates are in `Cargo.lock` at the top of the repository, and their source is under `$CARGO_HOME/registry/src/` (`~/.cargo` by default).
- The bindings come from uniffi-bindgen-cs at the version `windows/AGENTS.md`, Bindings, pins, which supports one UniFFI minor. Read its templates at that tag when a generated signature is in question.
- Where the source does not settle it, measure: an xunit test in the matching `windows/tests/` project against the real core and a real SQLite file, or a Rust test in the crate. The tests use no mocks, so a probe uses the real thing. What only Windows can run goes to a runner (below).

## Measuring on the runners

When no Windows machine is at hand, a probe runs on GitHub's `windows-2025` (x64, Windows Server 2025) and `windows-11-arm` (Arm64, Windows 11) runners. The editor, grid and shell lanes measured this way (`windows/docs/decisions/0002-sql-editor-control.md` and `0003-data-grid-control.md`, Gate; `0004-app-shell.md`, What the runner showed).

1. **A temporary branch with a temporary workflow.** Branch `tmp/windows-<slug>` from the fix branch, add `.github/workflows/tmp-<slug>.yml` triggered only by `push` to that branch, commit and push it to `origin`. A push to TableProApp/TablePro runs at once; a fork's pull request waits for approval (`references/verification-windows.md`, Reading CI). Give it `concurrency: { group: tmp-<slug>, cancel-in-progress: true }`, so a new push replaces the old run.
2. **Copy the steps from `windows.yml`**, pinned actions included: checkout, the Rust toolchain with the runner's target, `Swatinem/rust-cache`, "Drop the emptied DuckDB sources", `setup-dotnet`, and `RUSTFLAGS`, `AWS_LC_SYS_PREBUILT_NASM` and the `DOTNET_*` variables. Before any UI work, run `windows/ci/desktop.ps1` as it does: `Clear-FirstLogon`, `Start-WslWatch <log>`, `Set-Display 1920 1080`.
3. **Build the core once.** DuckDB's C++ takes most of a cold job under MSVC. A `core` job builds `tablepro_ffi.dll` per runner and uploads it; the next pushes skip that job, download the DLL into `target/<triple>/debug` with `actions/download-artifact` (`run-id`, `github-token`, and `permissions: actions: read`), and build with `-p:SkipCoreBuild=true`. The shell lane marked those commits `[reuse-core]` and kept the run id in a file on the branch.
4. **Run what settles the question**: one test with `dotnet test --project tests/TablePro.App.UITests -- --filter-method "<Namespace.Class.Method>"`, or the UI tests four times in one job, counting failed passes, to show a race is gone. Code only the probe needs, such as a shot of a state no test reaches, is a file the push adds to the temporary branch alone.
5. **Keep the evidence**: upload the screenshots, `windows/**/TestResults/**` and the logs with `if: always()`.
6. **Read it**: `gh run view <run> --repo TableProApp/TablePro --json jobs` for each job's result, `gh run view --repo TableProApp/TablePro --job <job-id> --log-failed` for a failed job's tail, and `gh run download` for the artifacts.
7. **Never force-push** (`SKILL.md`, Autonomy). Each round merges the fix branch into the temporary branch and pushes a new commit. When the question is settled, delete it: `git push origin --delete tmp/windows-<slug>`.
8. **Record the result** in the decision the code relies on, with the run id. The temporary branch and workflow never reach the fix branch.

Timing on a runner is relative. The runners have no GPU, so Direct3D runs on WARP, and the CPU a job gets varies from job to job (`references/verification-windows.md`, Runner traps). Compare variants inside one job, start each process on an idle CPU as `windows/tests/TablePro.DataGrid.Gate/ci/run-gate.ps1` does, and rerun a step the runner starved instead of raising the bar. Input methods differ too: Vietnamese Telex stays raw on `windows-2025`, in a stock TextBox as well, and composes on `windows-11-arm` (ADR 0002, Gate).

## Comparable clients

A Windows user describing how something "should" work is usually describing one of these. Most are not WinUI apps, so they answer what capability users expect, never how it should look.

| Client | Why read it | Where |
| --- | --- | --- |
| SQL Server Management Studio | The reference tool for SQL Server on Windows | `learn.microsoft.com/en-us/ssms/` |
| DBeaver | The widest driver and dialect coverage | `github.com/dbeaver/dbeaver` |
| HeidiSQL | Open source, Windows first, MySQL, PostgreSQL, SQL Server and SQLite | `github.com/HeidiSQL/HeidiSQL` |
| DataGrip | Deepest SQL tooling; take the capability, not the interaction | `jetbrains.com/datagrip` |
| Beekeeper Studio | Open source, cross-engine | `github.com/beekeeper-studio/beekeeper-studio` |
| DB Browser for SQLite | The SQLite reference tool | `github.com/sqlitebrowser/sqlitebrowser` |

For how a surface should look and behave, read apps built on the same stack:

| Application | Read it for | Where |
| --- | --- | --- |
| WinUI Gallery | One page per control, with its intended use and code | `github.com/microsoft/WinUI-Gallery` |
| PowerToys | WinUI 3 settings pages built from the Toolkit's `SettingsCard` and `SettingsExpander` | `github.com/microsoft/PowerToys` |
| Windows Terminal | TSF input, which the editor ports, and tabs | `github.com/microsoft/terminal` |
| Files | A large WinUI 3 app with a sidebar, tabs, trees and drag and drop | `github.com/files-community/Files` |

None of these can be run from here, so every claim about one is confirmed from a source you read or marked inferred.
