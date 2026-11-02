# 0001: Windows toolchain and build baseline

- **Status**: Accepted
- **Date**: 2026-11-02

## Context

The Windows app is C# on .NET 10 with WinUI 3 over the shared Rust core ([core 0001](../../../core/docs/decisions/0001-shared-core.md)). It runs on Windows 10 1809 and later and on Windows 11, on x64 and Arm64. Building it needs MSVC and the Windows SDK for the core, the .NET SDK for the app, and one command that builds both for the right architecture.

A spike on 2026-11-02 built a WinUI 3 app that calls a Rust `cdylib`, for both architectures, on a Windows 11 Pro 26H2 Arm64 VM (build 26300.9457, 4 CPUs, 8 GiB, a display-only GPU with no 3D). x64 binaries ran under emulation there.

## Decision

The Windows app builds with Build Tools for Visual Studio 2026 (MSVC for x64 and Arm64), Windows SDK 10.0.26100, the .NET 10 SDK and Rust with both MSVC targets, runs cargo from its csproj, publishes with Native AOT, and targets Windows 10 1809 (`TargetPlatformMinVersion` 10.0.17763.0) with runtime checks for what only Windows 11 has.

## Rationale

- **The toolchain installs silently and builds both targets.** On the Arm64 host, MSVC came with linkers for both: `bin\Hostarm64\arm64\link.exe` and `bin\Hostarm64\x64\link.exe`. The x64 AOT build cross-compiled from the Arm64 host.

  | Tool | Version that ran |
  |---|---|
  | Build Tools for Visual Studio 2026 | 18.11.3, MSVC 14.51.36231, components `VCTools`, `VC.Tools.x86.x64`, `VC.Tools.ARM64`, `Windows11SDK.26100` |
  | Windows SDK | 10.0.26100 |
  | .NET SDK | 10.0.403, runtime 10.0.14 |
  | Rust | 1.99.1, rustup 1.29.2, targets `aarch64-pc-windows-msvc` and `x86_64-pc-windows-msvc` |
  | Git for Windows | 2.56.0.windows.4 |
  | Windows App SDK | `Microsoft.WindowsAppSDK.WinUI` 2.6.4 |

- **cargo runs from the csproj.** A `CargoBuild` target runs `cargo build --target <triple>` before the build, with the triple taken from `-r win-x64` or `-r win-arm64`. The DLL is an item copied to the output and publish folders, and a build without a runtime identifier fails with a message. Both builds finished with 0 warnings.
- **Native AOT starts faster at half the size.** It published for both architectures with 0 warnings, and SDK 10.0.403 needed no explicit CsWinRT reference. Startup was measured from process creation to the first frame after the root's `Loaded`, as the median of runs 2 to 6:

  | Variant | First frame | Publish folder |
  |---|---|---|
  | Arm64, JIT | 291 ms | 188 MB |
  | Arm64, ReadyToRun | 244 ms | 241.7 MB |
  | Arm64, Native AOT | 218 ms | 90.5 MB, 20.0 MB of it the pdb |
  | x64 emulated, JIT | 651 ms | 171.1 MB |
  | x64 emulated, Native AOT | 256 ms | 83.2 MB |

  The working set was 92 MB with AOT against 129 MB with JIT. The VM has no GPU, so the numbers only compare the variants with each other.
- **The WinUI package alone.** The app references `Microsoft.WindowsAppSDK.WinUI`, not the metapackage, which also pulls in AI, ML, Search and Widgets. The 2.0 ML package needs Windows 10 1903 or later.
- **Why runtime checks.** A build with min version 10.0.17763.0 gave 0 warnings, because CA1416 flags only Windows SDK APIs with OS version attributes and Windows App SDK types carry none. So the compiler does not catch Windows 11 behavior:
  - Mica and Mica Alt fall back to a solid color below build 22000. `MicaBackdrop` does that itself.
  - `AppWindowTitleBar.IsCustomizationSupported()` returns true on Windows 10 since Windows App SDK 1.2, but title bar colors are ignored there.
- **Unpackaged and MSIX both stay possible.** The unpackaged self-contained app ran and loaded a driver DLL from `%LOCALAPPDATA%`. An Arm64 MSIX of 65.5 MB built from the same project. Both need signing: MSIX with a certificate whose subject matches the manifest's `Publisher`, unpackaged with the exe, the DLLs and the installer signed.

## Consequences

- `windows/scripts/install-toolchain.ps1` installs Git, the .NET SDK, Rust with both targets in `C:\rust` for every user, and the Build Tools, from the vendors' installers. It needs admin rights and can run one part at a time with `-Only`. A guest's disk use went from 19.6 GB to 34.7 GB.
- The script installs Rust stable, but the repository pins its version in `rust-toolchain.toml`. Run `rustup target add aarch64-pc-windows-msvc x86_64-pc-windows-msvc` once in the checkout so the pinned toolchain has both targets.
- The app ships one build per architecture, and so do its drivers ([core 0004](../../../core/docs/decisions/0004-driver-plugin-abi.md)).
- .NET 10 supports Windows 10 1809 as the LTSC release ("E" in its support list). x64 emulation exists only on Windows 11 Arm64, so Arm64 PCs on Windows 10 need the Arm64 build.
- Windows App SDK is backward compatible to 1809, but Microsoft supports it only on Windows releases still in support.
- Unverified: Mica on a machine with a real GPU (it showed as solid gray on the VM), the TabView in the title bar on Windows 10, the app on Windows 10 at all, and installing a signed MSIX and loading a driver from it. MSIX signing under LocalSystem failed with `APPX0105` and `APPX0107`.
- The first window of a session can take several seconds to show, and the first launch from a fresh folder took 16.7 s with JIT, likely Defender and a cold cache (unverified).
- `AppWindow.Resize` takes physical pixels, so a size must be scaled by the display's DPI.

## Alternatives considered

- **JIT or ReadyToRun.** Slower to start and twice the size or more, as in the table.
- **The full Windows App SDK metapackage.** Brings AI, ML, Search and Widgets the app does not use, and an ML package that needs 1903.
- **winget for setup.** winget 1.11.510 runs only for the desktop user at medium integrity, so a machine-wide install shows a UAC prompt, and run as LocalSystem it printed nothing.
- **A Windows 11 floor.** Drops Windows 10 1809 and later, which the app supports.
