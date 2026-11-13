# 0025: Linux and Windows link their drivers at compile time for good

- **Status**: Accepted
- **Date**: 2026-11-13

## Context

[0004](0004-driver-plugin-abi.md) chose downloadable drivers on every platform over a small C ABI, superseded [Linux ADR 0001](../../../linux/docs/decisions/0001-no-plugin-system.md), and had the first Windows release link its 9 drivers until the ABI lands. The ABI has not landed, so every app on the core links its drivers today.

The roadmap asked whether Windows should take engines after install ([ROADMAP.md](../../../ROADMAP.md#decisions), D-03). The maintainer answered on 2026-11-13.

## Decision

The Linux and Windows apps link every driver at compile time and never load one at runtime; 0004 still holds for macOS.

## Rationale

- Linux ADR 0001's reasons hold for both apps: on macOS, plugin loading, ABI mismatches and stale registry data trace to about 15% of issues, and plugin validation and signing take real time.
- 0004 left open risks that only the downloading apps carry: Microsoft Store Policy 10.2.2 on code included at runtime, `dlopen` inside the Flatpak and loading from an MSIX package's `LocalState`, all untested.
- Both apps ship whole through channels that update them: the PPA, COPR and the Flatpak repositories on Linux ([Linux ADR 0041](../../../linux/docs/decisions/0041-beta-repositories-and-release-packages.md)), MSIX and winget on Windows ([Windows ADR 0005](../../../windows/docs/decisions/0005-distribution.md)).

## Consequences

- Linux ADR 0001 is in force again. 0004 is superseded for Linux and Windows and stays accepted for macOS, which moves its engines to the core under [0010](0010-macos-on-the-core.md).
- A new engine reaches Linux and Windows only in an app release, the cost 0004 named under "Static drivers only".
- The drivers' `plugin` feature and the C ABI serve macOS alone. A Linux or Windows build never turns the feature on.
- Windows signs no driver DLLs and checks none with `WinVerifyTrust`.

## Alternatives considered

- **0004 as written.** Downloads on every platform. Lost on the reasons above.
- **Downloads on Windows only, Linux linked.** The roadmap's other option. Windows would still carry the Store policy risk and DLL signing, for engines that Linux, on the same core, ships in releases.
