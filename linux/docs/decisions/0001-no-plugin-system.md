# 0001 — No plugin system; drivers are statically linked

- **Status**: Accepted
- **Date**: 2026-04-26

## Context

The macOS TablePro app has a mature plugin system: each database engine ships as a `.tableplugin` bundle, loaded at runtime through `PluginManager`. The system supports user-installed plugins, ABI versioning, and a registry server for discovery. It is also a significant maintenance burden:

- ABI versioning crashes user-installed plugins on every protocol change with `EXC_BAD_INSTRUCTION` (uncatchable in Swift).
- Plugin validation, sandboxing, and signing eat real engineering time.
- Roughly 15% of issues in the macOS bug tracker trace back to plugin loading, ABI mismatches, or stale registry data.

For the Linux subproject we have a chance to avoid that complexity from day one.

## Decision

The Linux app does not have a runtime plugin system. Every database driver is a Rust crate inside `crates/drivers/`, statically linked into the `tablepro` binary, and registered in one place at startup.

Adding a new database engine requires:

1. A new crate at `crates/drivers/<engine>/`.
2. Implementation of the `core::DatabaseDriver` and `core::Connection` traits.
3. Adding the crate to the workspace.
4. One `r.register(...)` line in `app::main::build_registry`.
5. Recompiling.

There is no `.tableplugin` equivalent. There is no runtime discovery. There is no plugin manifest.

## Rationale

| Concern | Plugin model (macOS) | Static model (Linux) |
|---|---|---|
| Adding a driver | New bundle, version negotiation, registry entry | One crate + one register call |
| ABI stability | Critical, hard, has caused production crashes | Not a concern; same compile, same ABI |
| Type safety across boundary | Manual; transfer types in `TableProPluginKit` | Native Rust traits, fully typed |
| Sandboxing | Theoretical; in practice plugins run in-process | Not applicable; trusted code only |
| Third-party drivers | Possible | Possible only via a fork or PR |
| Build time impact | Each plugin builds independently | Adding a driver adds ~30s to a clean build |
| Binary size | App ships with N plugins as bundles | App grows by one driver's footprint per added crate |

The deciding factor is maintenance cost. Three person-weeks per year on macOS go into plugin-system fixes. The Linux user base is smaller and the engine catalogue is fixed by what we ship; there is no real demand for user-installed engines that the macOS app's plugin registry has surfaced.

A static driver layer also enables full type checking across the core / drivers boundary, eliminates a class of crashes, and makes the codebase legible to a new contributor in an hour.

## Consequences

Accepted:

- **No third-party drivers without a fork or upstream PR.** This is intentional. Engines we do not ship, we do not support.
- **Adding a driver requires recompilation and a release.** Cadence pressure: we batch driver work into release branches.
- **Binary grows linearly with driver count.** ~12 drivers projected, ~50–80 MB final binary; acceptable for a desktop app.
- **No hot reload.** Use `cargo watch` during development.

Gained:

- Zero plugin-loading crashes possible.
- Full Rust type checking across driver boundary.
- Single `cargo build` produces a runnable artefact.
- One bug report category disappears from the issue tracker.

## Alternatives considered

**WebAssembly plugins via Wasmtime Component Model.** Modern, sandboxed, language-agnostic. Lost because DB drivers need raw socket and TLS access; routing those through the host crosses an extra trust boundary for no real isolation gain (drivers handle credentials regardless). WASM is the right call for *editor* extensions (Zed's model), wrong for *driver* extensions.

**`abi_stable` Rust dynamic loading.** Mature crate, layout-checked at load. Lost because the maintenance benefit over a Cargo workspace is small while the complexity tax is non-trivial. We would gain "users can install drivers" — a feature no one has asked for on Linux.

**C-FFI plugin contract.** Universal but verbose, error-prone, no type safety. Inferior to `abi_stable` if we ever want plugins; inferior to static linking if we do not.

**Mirror the macOS `.tableplugin` model.** Would maximise consistency across platforms. Lost because the macOS model's pain points are well-documented (see Context) and we have a chance to not inherit them.
