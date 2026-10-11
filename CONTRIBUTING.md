# Contributing to BookiE

BookiE is a Linux-only Rust project (formerly TablePro on this branch). Current development happens on the `linux` branch, and pull requests should target that branch in [`cozyGarage/BookiE`](https://github.com/cozyGarage/BookiE).

Every shipped feature must remain available without an account, license key, subscription, paid tier, or remote entitlement check.

The rules every change follows (code style, tests, security, commits, the Forgejo gate) are in [`AGENTS.md`](AGENTS.md).

## Development setup

The workspace requires Rust 1.98. For the build / CI floor install GTK4 4.14+, GLib 2.80+, libadwaita 1.5+, GtkSourceView 5.12+ (Ubuntu 24.04 and Debian 13), plus OpenSSL, Secret Service, Kerberos, Clang, `pkg-config`, and standard build tools. The GNOME 50 package line is higher; see [`README.md`](README.md) and [ADR 0002](docs/decisions/0002-rust-gtk4-libadwaita.md).

```bash
git clone https://github.com/<your-name>/BookiE.git
cd BookiE
git checkout linux
rustc --version
pkg-config --modversion gtk4 libadwaita-1 gtksourceview-5
cargo run -p tablepro-app
```

Use a short-lived local branch when useful, then open the pull request against `linux`.

## Project layout

The Cargo workspace is at the repository root. Crate roles, the governed request pipeline and the import DAG are in [`ARCHITECTURE.md`](ARCHITECTURE.md). Read that page before changing crate boundaries, policy enforcement, connection ownership, or async execution. Packaging lives in `apps/linux/packaging/`; the documentation map is [`docs/README.md`](docs/README.md).

## Code style

`rustfmt.toml` and `clippy.toml` define formatting and lint settings.

- Use Rust edition 2024 and Rust 1.98.
- Keep lines at or below 120 characters where practical.
- Do not add comments. Use names, types, functions, and tests to express intent.
- Prefer small functions and early returns.
- Do not use `unwrap`, `expect`, `panic!`, `todo!`, or `unimplemented!` in production paths.
- Use typed errors at crate boundaries.
- Use `tracing` for app logs. Do not use print macros for logging.
- Never log credentials, tokens, SQL parameters, connection strings, or unmasked query results.
- Keep GTK widget access on the glib main context. Move database and blocking work off the UI thread.

## Security and MCP changes

All database consumers must use a policy-gated connection. MCP requests require a valid token, the required scope, an allowed connection, and a passing policy decision. Do not bypass those checks for preview, retry, transaction, or batch paths.

Changes to policy, MCP, approvals, masking, or audit behavior need tests for both allowed and denied paths. Include timeout, cancellation, and terminal audit outcomes when affected. Keep secrets in Secret Service through `tablepro-storage`.

New dependencies need an advisory, source, and license review through `deny.toml`.

## Database drivers

Drivers are static crates under `crates/drivers/`. A new driver must:

1. Implement the contracts from `tablepro-core`.
2. Stay independent of GTK, Relm4, MCP, policy, and other drivers.
3. Register in the app and agent composition roots.
4. Include unit tests and real-engine integration tests.
5. Document maturity and known limits.
6. Add a user-facing entry to `CHANGELOG.md`.

See [`docs/adding-drivers.md`](docs/adding-drivers.md).

## Tests

Every testable behavior change needs a test. Put pure unit tests near the code and integration tests in the crate's `tests/` directory. Use `tempfile` for filesystem tests and testcontainers for database drivers.

For GTK-only changes, include manual test steps and light and dark screenshots in the pull request. Move business logic out of widgets when it can be tested as Rust code.

Run from the repository root:

```bash
bash scripts/check-file-size.sh
cargo fmt --all -- --check
cargo clippy --workspace --exclude tablepro-driver-duckdb --all-targets -- -D warnings
cargo test --workspace --exclude tablepro-driver-duckdb --lib --bins
cargo test -p tablepro-mcp --test enforce_policy
cargo test -p tablepro-mcp --test timeout_audit
cargo deny check
```

Driver integration tests require Docker or a compatible Podman socket. See [`docs/testing.md`](docs/testing.md).

## File size

`scripts/check-file-size.sh` enforces the Rust file-size guard. New files should stay at or below 1,200 lines. Unlisted files above 1,800 lines fail. Files in `baselines/file-size-baselines.txt` cannot grow beyond their listed ceiling. Split by responsibility instead of raising a baseline.

## Changelog

Update [`CHANGELOG.md`](CHANGELOG.md) under `[Unreleased]` for user-facing changes. Follow Keep a Changelog 1.1.0 and use `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, or `Security`.

Each entry must be one line and describe user impact. Documentation-only changes do not need an entry. Do not add a `Fixed` entry for a defect introduced and corrected before release.

## Commits

Use Conventional Commits 1.0.0. Commit subjects are one line with no body.

```text
feat(app): add query tab restore
fix(driver-postgres): cancel timed-out connections
security(mcp): enforce connection allowlists
refactor(core): split query result conversion
```

Keep one logical change per commit. Public API changes must update all callers and tests in the same commit.

## Pull requests

- Target the `linux` branch.
- Explain what changed and why.
- List the commands and manual checks you ran.
- Add or update tests.
- Update `CHANGELOG.md` for user-facing changes.
- Update documentation when behavior or setup changes.
- Include light and dark screenshots for UI changes.
- State any validation you could not run and why.

## Reporting bugs

Open a [bug report](https://github.com/cozyGarage/BookiE/issues/new?template=bug_report.yml) with the BookiE version, Linux distribution, desktop session, reproduction steps, database type and version, and redacted logs.

## License

Contributions are licensed under [AGPL-3.0-or-later](LICENSE).
