# TablePro shared core

The Rust crates every platform's app builds on: the domain types and the driver contract, one crate per database engine, the network and SSH transports, sessions, storage, the MCP server and the AI client. None has a GUI. The Linux app (`linux/`) uses them directly, the Windows app through `crates/ffi`, and the macOS app through the same crate one slice at a time ([ADR 0001](docs/decisions/0001-shared-core.md), [ADR 0010](docs/decisions/0010-macos-on-the-core.md)).

This is the guide for work under `core/`. The root `AGENTS.md` holds the rules every app shares. Claude Code loads this file through `core/CLAUDE.md` once a file under `core/` is read; Codex reads it when started in `core/`, so otherwise read it yourself.

## Principles

1. **Tests define behavior**, as in the root `AGENTS.md`.
2. **No GUI, no platform service.** A core crate depends on no GUI toolkit and on no platform crate. What a platform does its own way comes in as a value or a trait the app passes in, or sits behind a `cfg` split; `ARCHITECTURE.md`, Platforms, lists both.
3. **Every target builds.** A change keeps the crates building for Linux, Windows (x64 and Arm64) and macOS. `std::os::unix`, `rustix`, `/proc` and Unix sockets go behind `cfg(unix)` or `cfg(target_os = "linux")`, with the other platforms' answer beside them.
4. **One-directional crates.** `ARCHITECTURE.md` has the graph. Drivers are linked in at compile time until the driver ABI lands (`docs/decisions/0004-driver-plugin-abi.md`).
5. **Errors carry a code, not a sentence.** Each boundary error has a stable `code()` and typed fields; an app words it. No translation catalog lives here.
6. **Decisions are recorded.** One that holds for every platform goes in `docs/decisions/` (`docs/decisions/README.md`).

## Map

- `crates/core`, `crates/net`, `crates/ssh`, `crates/storage`, `crates/session`, `crates/ai`, `crates/mcp`, `crates/account`, `crates/cli`: the libraries. `crates/drivers/*`: one crate per engine. `crates/ffi`: the library the Windows and Apple apps load (`ARCHITECTURE.md`, Bindings). `crates/bindgen`: the Swift binding generator. `crates/test-fixtures` and `crates/test-support`: test-only.
- `ARCHITECTURE.md`: the crates, the graph, the platform seams and the driver layer. `docs/decisions/`: the cross-platform decisions.
- The Cargo workspace and its tool settings are at the top of the repository: `Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml`, `rustfmt.toml`, `clippy.toml`, `deny.toml`, `.config/nextest.toml`.
- Until another app builds the core, the Linux docs hold its contracts: `linux/docs/adding-drivers.md`, `linux/docs/drivers/`, `linux/docs/error-handling.md`, `linux/docs/testing.md` and `linux/docs/storage.md`.

## Commands

The Linux wrapper builds and tests the whole workspace (`linux/AGENTS.md`, Commands). For another target, name the packages, since the workspace also holds the GTK app:

```bash
cargo check --locked --target x86_64-pc-windows-msvc -p tablepro-core -p tablepro-storage ...
cargo test --locked -p tablepro-core --lib
```

From macOS, `cargo xwin check` with LLVM's `clang-cl` on `PATH` checks the Windows targets. `.github/workflows/core.yml` runs the same on Windows and macOS runners, with the package list.

## Every change

- Code style, tests and lint follow `linux/AGENTS.md`, Code style and Every change: the workspace lints, no `unwrap` outside tests, `tracing` for logs, comments that say why.
- A user-visible change adds its fragment to the app that shows it, `linux/changelog.d/` today. A change no app shows adds none.
- Commits and pull requests follow the root rules, with scope `core` or `core-<area>`.
