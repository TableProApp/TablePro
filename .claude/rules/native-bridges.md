---
paths:
  - "Native/**/*"
  - "Plugins/DamengDriverPlugin/**/*"
  - "Plugins/HanaDriverPlugin/**/*"
  - "scripts/build-dameng.sh"
  - "scripts/build-hana.sh"
---

# Native bridges

- **First-party bridge code lives in `Native/<X>Bridge`**, built by `scripts/build-<x>.sh`, with output in a gitignored folder beside the source, never in `Libs/`.
- **Rust may run in the app process; Go may not.** The Dameng staticlib is built with `panic = "unwind"`, and every export that does driver work wraps it in `catch_unwind`; a new export that does work takes the same guard. Go's `recover()` cannot catch a panic on a goroutine go-hdb starts, so HANA runs out of process as `tablepro-hana-helper`, one per driver session.
- **Toolchains and upstream code are pinned**: `rust-toolchain.toml`, `Cargo.lock` with `--locked`, the `toolchain` line of `go.mod`, `go.sum`. A protocol change for Dameng lands on the `TableProApp/rust-dameng` fork first, then the pinned `rev` moves.
- **Every nested Mach-O is signed with Developer ID, the hardened runtime and a timestamp** before the main binary; `scripts/build-plugin.sh` does it and checks it with `codesign -dvvv`.
