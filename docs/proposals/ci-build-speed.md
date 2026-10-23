# CI build speed after the toolkit floor

Status: proposal. Owner: UX lane. Depends on [ADR 0021](../decisions/0021-toolkit-floor.md) and the runner upgrade it requires.

## Where gate time goes

Measured from the job logs of green Forgejo runs 892, 893, 899 and 901, before ADR 0021:

| Run | Wall clock | Slowest jobs |
| --- | --- | --- |
| 892 | 19.2 min | distro-floor ubuntu 15.5, debian 14.6, consumers 8.0, driver mssql 7.2 |
| 893 | 19.5 min | distro-floor ubuntu 16.4, debian 15.7, e2e postgres 9.2, consumers 8.5 |
| 899 | 24.0 min | distro-floor ubuntu 20.8, debian 15.5, consumers 11.6, e2e postgres 8.7 |
| 901 | 26.9 min | distro-floor ubuntu 13.5, debian 12.7, driver mssql 10.3, consumers 8.6 |

- The distro-floor job is the critical path. In run 893 the Ubuntu floor spent 3.6 minutes building the package and 11.3 minutes running GUI scenarios in one container.
- `e2e (postgres)` reinstalled Rust and compiled 519 crates on every run, because `scripts/test-gtk-postgres.sh` resolved `CARGO_HOME` and `RUSTUP_HOME` from `$OLDPWD`. Fixed in #1459.
- `driver (mssql)` spends 7 to 10 minutes in tests, not in compilation.
- Release builds of the app, used by the GUI scenario jobs, are the largest compile step left in most jobs.

## Proposal 1: build GUI scenario binaries with a `ci` profile

`scripts/gtk-test-binary.sh` builds the app for `scripts/test-gtk-safety.sh`. It uses a `ci` Cargo profile by default: our crates at `opt-level = 1` with 256 codegen units, and dependencies at `opt-level = 3` as in `release`. `TABLEPRO_GTK_BUILD_PROFILE=release` keeps an optimized build for memory profiling, and `scripts/profile-baseline.sh` sets it.

Local measurement, 16 cores, rebuilding the app after an edit to `crates/core`:

| Profile | Rebuild |
| --- | --- |
| `release` | 76 to 96 s |
| `ci` | 63 to 64 s |

Each of the eight GUI scenario jobs saves 15 to 30 seconds of compile time per gate. Wall clock changes little because those jobs run in parallel and are not on the critical path. Dropping debug info from test builds saved 3 seconds and loses line numbers in CI backtraces, so it is not proposed.

The `ci` profile adds a `target/ci` directory beside each job's `target/release`. Runners were 92 to 98 percent full on 2026-10-22. Merge this after the runner upgrade, when the GUI job caches start empty, or remove the old `target/release` directories of the GUI jobs under [runner maintenance](runner-maintenance-and-isolation.md) once no gate is running.

## Proposal 2: shard the distro-floor GUI scenarios

After ADR 0021 the floor matrix has one entry, `debian:testing`, on MCP port slot 10. The GUI scenarios already support sharding through `TABLEPRO_GTK_SHARD`, which the `gtk` job uses as `1/3`, `2/3` and `3/3`.

1. `scripts/test-distro-floor.sh` forwards `TABLEPRO_GTK_SHARD` into its container. Unset, it runs every scenario as today.
2. `.forgejo/workflows/ci.yml` gives the floor job a `shard: [1, 2]` matrix on MCP port slots 10 and 11. Slot 11 is free since `debian:13` left the matrix. A third shard needs `scripts/ci-mcp-port.py` to accept slots above 11.
3. `scripts/test-deb-package.sh` and the upgrade check run in one shard only.

Expected floor time with two shards: about 3.6 minutes of package build plus 5.7 minutes of scenarios. The package is cached per commit on each host, so shards on different hosts each build it once. The gate would then be bounded by `consumers`, `driver (mssql)` and the `gtk` shards at 7 to 10 minutes.

Step 2 changes a workflow file. Agree it with the app-side session before opening the pull request, and gate it once on the upgraded runners.

## Order

1. Runners are upgraded to the ADR 0021 toolkit and verified.
2. Proposal 1 merges, with empty or cleaned GUI job caches.
3. Proposal 2 is agreed with the app-side session, then merges after one gate on the upgraded runners.
