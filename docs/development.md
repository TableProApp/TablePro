# Contributing to TablePro Linux

This repository is a Linux-only Rust and GTK project. The Cargo workspace is at the repository root, so run development commands from there.

## Development environment

Install the native packages listed in [README.md](../README.md). Rust 1.98 is the minimum supported version and is pinned in `rust-toolchain.toml`. Arch may also provide a newer `/usr/bin/cargo`; see [docs/platforms.md#rust-toolchain](platforms.md#rust-toolchain) when comparing toolchain results.

Use the fast checks while iterating:

```bash
cd linux
./scripts/preflight.sh
./scripts/ci-local.sh
./scripts/ci-local.sh integration
cargo run -p tablepro-app
```

`preflight.sh` checks non-GTK crates. `ci-local.sh` checks the full default workspace, including the GTK binary tests. Integration mode requires Docker or a compatible Podman socket.

## Code style

| Tool | Configuration | Rule |
|---|---|---|
| `rustfmt` | `rustfmt.toml` | Run before each pull request |
| `clippy` | `clippy.toml` | Workspace targets pass with `-D warnings` |
| Rust edition | Workspace manifest | Edition 2024 |
| MSRV | `rust-toolchain.toml` | Rust 1.98 |

Keep code focused and readable:

- Prefer small functions and early returns.
- Do not use `unwrap()` or `expect()` in production paths.
- Do not leave `panic!`, `todo!`, or `unimplemented!` in production paths.
- Keep public crate boundaries typed with `thiserror` errors.
- Add tests for behavior changes.
- Keep GTK objects on the GLib main context. Run database and service work through the existing Relm4 and Tokio bridge.
- Add comments only when they explain a constraint that names and types cannot express.

## Database drivers

Follow [docs/adding-drivers.md](adding-drivers.md). Drivers are statically registered by the application. A driver change should include focused unit tests and a real-engine integration test when the behavior depends on the server.

## Storage changes

Read [docs/storage.md](storage.md) before changing persisted data. Do not put passwords, SSH secrets, or MCP secrets in JSON. Preserve existing files or add an explicit migration when a stored shape changes.

## GTK changes

Keep UI state in Relm4 components and move testable rules into pure Rust services. Add unit tests for extracted logic. Safety-sensitive GTK flows need targeted tests when they can run deterministically. The current release blockers are listed in [docs/production-audit.md](archive/production-audit.md).

Include before and after screenshots for visible changes. Test both light and dark themes when colors or contrast change.

## Packaging

GitHub Release packages are Arch x86_64 and Ubuntu 25.10 amd64. Test
`apps/linux/packaging/arch/PKGBUILD`, `scripts/validate-arch-package.sh`, and
`scripts/validate-deb-package.sh` when a change affects installed files,
native dependencies, desktop integration, or launch behavior. Public AUR
and Flathub publication are deferred and must not define current requirements.

## Commits and pull requests

Use a single-line Conventional Commit message:

```text
feat(drivers): add ClickHouse metadata query
fix(app): stop duplicate sidebar fetches
refactor(core): split connection control logic
docs(testing): document PostgreSQL cancellation fixture
```

A pull request should include:

1. A short summary of the problem and the chosen fix.
2. A test plan with the exact commands run.
3. Screenshots for visible GTK changes.
4. Any remaining release or migration risk.

Run these before requesting review:

```bash
./scripts/preflight.sh
./scripts/ci-local.sh
```

Run `./scripts/ci-local.sh integration` for driver behavior that needs a real server.

## Optional reference review

Other TablePro implementations may be inspected as product or security references. Do not merge their source trees into this repository. Record a manual Linux port only when the review changes behavior here, following [docs/upstream-sync.md](upstream-sync.md).

## Where to start

1. Read [ARCHITECTURE.md](../ARCHITECTURE.md) and [docs/decisions/](decisions/).
2. Pick a small issue with a clear test path.
3. For a new driver, use a current Rust driver crate as the structural reference.
4. Keep pull requests narrow enough to review and verify in one pass.
