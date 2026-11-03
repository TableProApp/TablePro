# 0005: Shipping the app: a self-contained, Native AOT MSIX bundle, signed with Artifact Signing, on winget

- **Status**: Accepted
- **Date**: 2026-11-04

## Context

The app built as an unpackaged Debug build for its UI tests and nothing else: no release build, no signing, no installer. The maintainer fixed the shape on 2026-11-03: MSIX, winget, signing with Azure Artifact Signing, Windows 10 1809 and later and Windows 11 on x64 and Arm64, and the unpackaged development build kept as it is. TablePro ships from GitHub Releases and winget, not the Microsoft Store.

Two facts in the tree stood against a release: no project set `PublishAot`, though [0001](0001-toolchain-baseline.md) chose Native AOT, and the core linked the dynamic C runtime. And every WinUI project referenced the `Microsoft.WindowsAppSDK` metapackage, though 0001 chose the WinUI package alone.

## Decision

A release is one MSIX per architecture, built with Native AOT in the Release configuration over the core's release profile, carrying the Windows App SDK, .NET and the C runtime itself, bundled into one `.msixbundle` that Azure Artifact Signing signs, published on GitHub Releases and submitted to winget by `release-windows.yml` (`windows/RELEASING.md`).

## Rationale

- **The Windows App SDK self-contained.** Microsoft's guide for framework-dependent packaged apps says "for packaged apps that are not distributed through the Store, you as the developer are responsible for distributing the Framework package", and the Main and Singleton packages come only through the Deployment API. A self-contained package needs neither, and "packaged, self-contained" needs no initialization ([deployment overview](https://learn.microsoft.com/windows/apps/package-and-deploy/deploy-overview)). Its costs in that table, a larger download and no shared code pages, are marked "unpackaged apps only"; the remaining one is that a Windows App SDK fix ships with our next release.
- **.NET self-contained.** Native AOT has no shared runtime to depend on, and .NET has no framework package for MSIX.
- **The metapackage stays, for now.** The metapackage also brings AI, ML, Search, Widgets and DWrite, and a self-contained build copies every component's binaries into the package (`Microsoft.WindowsAppSDK.SelfContained.targets` in Base 2.6.4): ONNX Runtime 1.27.1 and DirectML alone are 41.8 MB per architecture. But every Community Toolkit 8.2.251219 package depends on `Microsoft.WindowsAppSDK` 1.6.250108002 or later. With `Microsoft.WindowsAppSDK.WinUI` as the only reference, NuGet resolved that dependency to 1.6.250108002, whose WinUI targets loaded beside 2.6.4's (MSB4011), and the MSIX tooling stopped on `CustomBeforeMicrosoftCommonTargets` (run 41682292859). The Toolkit's 8.3 previews depend on `Microsoft.WindowsAppSDK.WinUI` instead; once 8.3 is stable, the app references the WinUI package alone, as 0001 chose. Meanwhile the extra components cost size and nothing else: the app never activates them, and none of their DLLs imports the VC++ redistributable (`llvm-objdump -p` over the 2.6.4 packages' x64 binaries, and the package check).
- **The hybrid CRT for the core.** Rust's MSVC targets link `vcruntime140.dll` by default, and DuckDB's C++ adds `msvcp140.dll`: a machine without the VC++ redistributable could not load `tablepro_ffi.dll`. Native AOT already links the hybrid CRT, the C++ runtime inside and the Universal CRT from Windows (`/NODEFAULTLIB:libucrt.lib /DEFAULTLIB:ucrt.lib` in `Microsoft.NETCore.Native.Windows.targets`), as the Windows App SDK guide asks of self-contained C++. The core does the same through `CoreRustFlags`: `+crt-static` makes `cc`, `cmake` and `aws-lc-sys` build with `/MT` too. The flags go into `RUSTFLAGS` because the workflows set `RUSTFLAGS`, which overrides any Cargo configuration file.
- **One package per architecture, then a bundle.** The tooling would split a bundle per architecture by scale once the logos have scale variants, so `AppxBundle=Never` keeps every scale in the one package, and `makeappx bundle` joins the two that the x64 and Arm64 runners build. Signing the bundle signs the packages in it ([Sign an app package using SignTool](https://learn.microsoft.com/windows/msix/package/sign-app-package-using-signtool)).
- **The version and publisher set by the workflow.** The manifest task (`WinAppSdkGenerateAppxManifest` in `Microsoft.Windows.SDK.BuildTools.MSIX` 1.7.251221100) takes the Publisher from the signing certificate only when the build signs, and Artifact Signing signs afterwards. So the workflow writes the version and `WINDOWS_PUBLISHER` into `Package.appxmanifest` before the build, as Microsoft's [desktop app workflows](https://github.com/microsoft/github-actions-for-desktop-apps/blob/main/.github/workflows/cd.yml) do. The same task writes `Windows.Desktop`'s MinVersion from `TargetPlatformMinVersion`, 10.0.17763.0, and its MaxVersionTested from the target framework's SDK, 10.0.26100.0.
- **Artifact Signing through OpenID Connect**, as the [action](https://github.com/Azure/artifact-signing-action/tree/v2.0.0) recommends: no client secret is stored, and the federated credential names the `windows-release` environment, which deploys from `windows-v*` tags only.
- **winget's 1.12 schema**, the one microsoft/winget-pkgs' pull request template asks for, though winget-cli publishes newer ones. One bundle URL serves both architectures, as Windows Terminal's manifest does.

## Consequences

- CA1416 checks calls against 10.0.17763.0 in every project; the package check fails a TargetDeviceFamily above 17763, a framework dependency, or a binary that imports the VC++ redistributable. The install jobs target Windows Server 2022, build 20348, the oldest Windows a hosted runner has (`windows-2019` was retired), and Windows 11 Arm64. Nothing ran on build 17763 itself.
- `windows.yml` runs the UI tests against the Native AOT publish, over the debug core the test step built (`CargoProfile=dev`). A trim or AOT warning fails the publish, and `TrimmerSingleWarn` is off so each names its own call site.
- `TheInstalledPackageStartsAndKeepsItsFilesInLocalState` is the only test of the packaged code path, where the data folder is the package's LocalState. It runs in `release-windows.yml`, not on pull requests.
- A Windows App SDK servicing fix reaches users only through our next release.
- The package carries Windows App SDK components the app never loads, until the Toolkit depends on the WinUI package.
- `WINDOWS_PUBLISHER` fixes the package family name. Changing it later makes Windows install the next version beside the old one.
- The Store would need its own reserved identity, a second package family.
- MSIX orders versions by four numbers, so the Windows app has no beta channel.
- The release build restores no Cargo cache, so a tag builds the core's release profile, fat LTO, from cold.

## What the runner showed

- Run [41695784890](https://github.com/TableProApp/TablePro/actions/runs/41695784890), job `MSIX (Arm64)`, built the release core and Native AOT app and passed every package check. `TablePro.App_0.1.0.0_arm64.msix` was 79.9 MiB, with identity `TablePro`, version `0.1.0.0` and publisher `CN=TablePro Development`.
- Its `Windows.Desktop` family declared MinVersion `10.0.17763.0` and MaxVersionTested `10.0.26100.0`. It had no framework package dependency, no `TablePro.dll` and no binary importing the VC++ redistributable.
- The AOT publish reported no trim or AOT warnings. MSIX tooling warned that `mspdbcmf.exe` was absent, so it did not generate a separate symbols package; the MSIX build and checks passed.
- The run passed the unsigned path's version and signing check. The x64 package, bundle, install/start tests and winget validation remain unverified while their jobs await runners or dependencies. Artifact Signing has not run with production credentials.

## Alternatives considered

- **Framework-dependent MSIX.** Smaller, but a GitHub or winget install would first need the Windows App SDK framework package, and we would ship the Deployment API call for the Main package.
- **An unpackaged installer** (MSI or Inno Setup). Gives up MSIX's clean uninstall, per-user install without elevation and the LocalState folder 0004 chose, and the installer, the exe and every DLL need signing.
- **A VCLibs framework dependency** instead of the hybrid CRT. A sideloaded install fails where the framework package is missing, and the unpackaged build would still need the redistributable.
- **The tooling's own Azure code signing** (`AzureCodeSigningEnabled`). It signs inside the build on each runner, so the bundle would need a second signing step anyway; the maintainer chose the action.
- **`ExcludeAssets` on each unused component.** Six references that hide packages the metapackage declares, and what WinUI still needs from them at run time would rest on what the UI tests happen to reach.
- **The newest winget schema.** winget-pkgs asks for 1.12, and its older clients read 1.12.
