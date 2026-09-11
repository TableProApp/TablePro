# AGENTS.md

## Cursor Cloud specific instructions

TablePro is a native macOS/iOS application (SwiftUI + AppKit) built with Xcode and XcodeGen. It **cannot be built, tested, or run on the Linux Cloud Agent VM**:

- Building requires macOS 14+, Xcode 26+, and `xcodebuild`, none of which exist on (or can be installed on) Linux. See "How to Build" in `README.md` and the build/test/lint commands in `CLAUDE.md`.
- The app and its SwiftPM packages (`Packages/TableProCore`, `Packages/TableProOracle`) import Apple-only frameworks (AppKit, SwiftUI, CloudKit) and declare only `.macOS`/`.iOS` platforms, so `swift build` / `swift test` do not work on Linux either.
- `Libs/` and `Libs/ios/` are prebuilt macOS/iOS binaries fetched by `scripts/download-libs.sh`; they are not usable without Xcode.

Because there is no Linux dependency-install/update step for this codebase, no Cloud Agent update script is configured. Do lint/build/test/run work on a macOS host with Xcode, following `README.md` and `CLAUDE.md`.

Note: an experimental native Linux client (Rust) exists only on the `linux` branch under `linux/` and is a prototype ("nothing to install yet" per `README.md`). It is separate from this branch's macOS/iOS codebase.
