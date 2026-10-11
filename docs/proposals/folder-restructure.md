# Folder restructure: move out of `linux/`

Status: done in two steps on 2026-10-11 (the lift out of `linux/`, then the split below). Differences from this plan: `meson.build` and `meson_options.txt` stay at the repository root, because Meson cannot reach files outside its source root; the TLS and release test crates went to `tests/driver-tls` and `tests/release`; `testdata` is `tests/data`. It follows the
[backlog](../backlog.md) item on separating the platform-neutral crates from the
Linux application and on moving tests out of the source folders.

## Goal

1. The product no longer lives under a `linux/` folder.
2. Reusable code (`core`, `policy`, `storage`, `ssh`, `transport`, `mcp`,
   `agentd`, the drivers) is separate from the Linux-specific GTK app.
3. Cross-crate tests and fixtures are separate from source.

## What is true today

Only the `app` crate depends on GTK, libadwaita and Relm4. Every other crate is
platform neutral (see [ARCHITECTURE.md](../../ARCHITECTURE.md), Containers). So
the split is a move, not a rewrite.

The cost is paths. At the time of writing, 800 tracked files mention `linux/`, 17
workflow files and 69 scripts hard-code paths, and the docs carry about 400
relative links. A half-done move breaks the gate, so it has to land as one change.

## Proposed layout

```text
crates/                 platform-neutral crates (core, policy, storage, ssh,
                        transport, mcp, agentd, drivers/*)
apps/linux/             the GTK app crate, plus what only it needs:
                        apps/linux/data/, apps/linux/po/, apps/linux/flatpak/, apps/linux/packaging/, meson.build, meson_options.txt
tests/                  cross-crate fixtures, test data, release and TLS test crates
scripts/                from scripts
ci/                     from ci
docs/                   from docs (the root docs folder merges in)
vendor/                 from vendor
```

Workspace files (`Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml`, `rustfmt.toml`,
`clippy.toml`, `deny.toml`) and the baseline files move to the repository root.

### Move map

| From (before) | To |
|---|---|
| `linux/crates/{core,policy,storage,ssh,transport,mcp,agentd}` | `crates/<name>` |
| `linux/crates/drivers/*` | `crates/drivers/*` |
| `linux/crates/app` | `apps/linux/app` |
| `linux/data`, `linux/po`, `linux/flatpak`, `linux/packaging` | `apps/linux/` |
| `linux/meson.build`, `linux/meson_options.txt` | repository root |
| `linux/crates/release-tests`, `linux/crates/driver-tls-tests` | `tests/release`, `tests/driver-tls` |
| `linux/tests/fixtures`, `linux/testdata` | `tests/fixtures`, `tests/data` |
| `linux/scripts`, `linux/ci`, `linux/vendor` | `scripts`, `ci`, `vendor` |
| `linux/docs`, `linux/ARCHITECTURE.md`, `linux/ROADMAP.md`, `linux/CHANGELOG.md` | `docs/`, root |
| `linux/Cargo.toml` and tool config files | repository root |

### Decision for the maintainer: unit and integration tests

Rust finds a crate's `tests/` folder by convention. Moving every crate's
integration tests out of the crate needs `[[test]] path = ...` in each manifest
and makes `cargo test -p <crate>` harder to read. The proposal is:

- Unit tests stay next to the code they test.
- Per-crate integration tests (`crates/<name>/tests`) stay in the crate.
- Only the cross-crate pieces move to top-level `tests/`: fixtures, shared
  test data, the release test crate, the TLS test crate and the installed-GTK
  harness.

If you want every integration test moved out, say so; it is a separate, larger
step.

## Order of work

1. Pause all agents; no open PRs (true on 2026-10-11).
2. One atomic change: `git mv` only, with `Cargo.toml` workspace paths, path
   dependencies and `include_str!` / `env!` paths updated so it still builds.
3. Rewrite path references in workflows, scripts, docs, `sonar-project.properties`,
   packaging files and `AGENTS.md`. A second pass can follow in the same PR.
4. Run the stale-path check (below), preflight and the full Forgejo gate.
5. Merge, regenerate the Forgejo sync, and tell the agents the new paths.

Do it in the pause, before the 0.2.0 candidate is cut, so the release evidence is
recorded against the new layout once.

## Stale-path check

Add a small script (for example `scripts/check-moved-paths.py`) that fails when any
tracked file outside `docs/archive/` and `docs/evidence/` still contains an old
prefix such as `crates`, `scripts` or `docs`. The existing
`scripts/check-doc-links.py` already catches broken links. Archives and evidence
keep their old paths on purpose: they are dated records.

## Risks

- **Flatpak and Meson** use relative paths into the crate tree and may break
  silently. Flatpak is out of 0.2.0 scope, but its manifests should still be updated.
- **CI cache keys and target directories** include job names, not paths, so they
  should survive; check `SCCACHE_DIR` and the `CARGO_TARGET_DIR` settings.
- **Generated files** (`ignored-tests.md`, baselines, `Cargo.lock`) must be
  regenerated, not edited by hand. The inventory script has hard-coded roots.
- **Open worktrees and branches** become hard to merge. That is why no PR may be
  open when this lands.
- **Rollback** is one `git revert` of the move commit, as long as nothing else
  lands in between.

## Not in this change

Renaming crates (`tablepro-*` stays, per the rename boundary), changing the
distribution names, and splitting `docs/` by audience.
