# Workstation test reuse and upstream follow-up

**Status:** Archived execution plan and pilot record, 2026-10-20. It did not change machine configuration, filesystems, runner registration or test tiers. Use the current [validation playbook](../validation-playbook.md) for test tiers and commands; this dated plan does not define release scope.

The [upstream analysis](upstream-main-analysis-2026-10-20.md) selected reliability investigations before feature work. Use the existing validation tiers to execute such investigations while retaining compiled artifacts. The local desktop was used for focused development and reproduction; Forgejo remained the serialized acceptance gate.

## Local test findings

The October 20 pilot confirms that a warm Cargo target and stored nextest metadata can reuse exact test binaries for repeated, unchanged runs. The manifest records the source and binary identities and timing observations. It does not measure source-edit rebuild speed, compiler-cache hits or physical storage writes.

The native GTK checks needed Xvfb and AT-SPI prerequisites. The manifest records a 76-test widget result as summary-only because its raw output was not retained; it also records a 90-scenario installed-accessibility smoke after the chooser harness was corrected. The chooser issue was in test synchronization, not a reproduced application defect ([#1165](https://github.com/cozyGarage/BookiE/issues/1165)). These results are local observations, not release or Forgejo acceptance.

## Cache and artifact policy

1. Keep one long-lived target tree per active build owner and compatible configuration. Use the current warm target for its current checkout. A worktree that changes source is a separate build owner; share compiler-cache objects, not concurrent writes to one target tree. Do not create a new target for every test filter or new commit.
2. Keep normal development, coverage and mutation artifacts separate because instrumentation and source mutation change the build. Distro/target/toolchain/feature differences can also require separate artifacts. Do not use a commit SHA as the target-directory name; use it in an evidence manifest instead.
3. Choose Cargo build jobs and test threads from measured machine capacity. Serialize GTK focus/input tests and initially run one database fixture operation at a time. Treat concurrency limits as measured settings, not universal defaults. Docker tests that each launch containers need their own measured limit.
4. Preserve the repository's existing debug settings. Choose one cache strategy per build owner: incremental compilation for the existing edit loop, or nonincremental compilation with `RUSTC_WRAPPER=sccache` for repeated CI-like builds. Rust sccache does not support incremental compilation. Do not toggle profiles, wrappers, flags or feature sets between every command. Compare the two strategies in a small pilot before migrating a warm tree.
5. Share a bounded sccache directory across compatible worktrees. A cache hit still restores files and does not eliminate linking or every write. Monitor hits, misses, non-cacheable reasons, disk growth and elapsed time; tool installation alone is not evidence. Preserve stable source paths where practical. Do not expect arbitrary absolute-path changes to reuse every crate.
6. Do not run routine `cargo clean`, broad Docker prune or cache deletion between tests. Clean only a diagnosed stale artifact or a reviewed cache owner after its processes stop. Set a reviewed free-space reserve and per-owner cache quotas from observed growth. Cleanup is manual until ownership and retention are proven.
7. Keep ephemeral fixture working data in a bounded temporary area only when durability is irrelevant. Crash recovery, lost-COMMIT, fsync and persistent-state tests must retain their intended real-storage semantics. Do not disable durability globally to reduce writes. Preserve the existing distinction between reusable fast PostgreSQL fixtures and dedicated durable fixtures.

Cargo's [build-cache documentation](https://doc.rust-lang.org/cargo/reference/build-cache.html) explains target artifacts and freshness. The [sccache Rust limitations](https://github.com/mozilla/sccache/blob/main/docs/Rust.md) govern which compiler invocations it can cache. These sources do not promise a zero-write test loop.

## Build once, run selected tests repeatedly

Prefer normal Cargo freshness for a single narrow run. For repeated cases at one unchanged source/configuration, nextest supports execution from stored build metadata without rebuilding. The installed 0.9.148 help exposes the commands below. The command pattern was exercised by the local Core pilot recorded below.

Set `CARGO_BUILD_JOBS` and `NEXTEST_THREADS` to measured limits for the machine before using this Core unit-test example:

```bash
export CARGO_TARGET_DIR="$PWD/target"
mkdir -p "$CARGO_TARGET_DIR/reuse/core-unit"
NEXTEST="$(bash scripts/ensure-nextest.sh)"
"$NEXTEST" nextest list --locked -p tablepro-core --lib \
  --list-type binaries-only --message-format json \
  > "$CARGO_TARGET_DIR/reuse/core-unit/binaries.json"
cargo metadata --locked --format-version 1 \
  > "$CARGO_TARGET_DIR/reuse/core-unit/cargo.json"
"$NEXTEST" nextest run \
  --cargo-metadata "$CARGO_TARGET_DIR/reuse/core-unit/cargo.json" \
  --binaries-metadata "$CARGO_TARGET_DIR/reuse/core-unit/binaries.json" \
  --test-threads "$NEXTEST_THREADS"
```

Use nextest filters to repeat the relevant cases from those same binaries. Refresh the build metadata after any source, generated input, dependency, toolchain, profile, feature or compile-environment change. Record source SHA plus dirty-diff identity and relevant untracked/generated input hashes, Cargo.lock hash, compiler version, target, flags, features, selected binaries and nextest version beside it. Refuse stale metadata as current-source evidence. This example covers Core unit tests only; it does not replace preflight or another tier.

Use [nextest archives](https://nexte.st/docs/ci-features/archiving/) when distributing the same built test binaries across machines. Build in the pinned oldest-compatible CI environment, retain the archive/checksum and exact source revision, and verify runtime libraries and CPU compatibility on the executor. Arch-built dynamic binaries are not automatically runnable on Debian. Do not compile distributed artifacts with `target-cpu=native` on a developer machine. Source fixtures and external services still need provisioning.

Avoid repeatedly extracting an archive for each filter: extract once into an owned location and reuse its metadata. The first pilot should prove two executions use the same binaries with no rustc/linker activity and no extra archive extraction. Keep normal, coverage and mutation evidence distinct; ordinary test binaries cannot substitute for instrumented coverage or mutant rebuilds.

## Images, fixtures and CI allocation

Keep registry endpoints, credentials and machine inventories in private operational documentation, not in this public repository. This plan does not add or reconfigure an image registry or shared cache.

- Reuse approved image caches without changing fixture semantics. Retain pinned digests, architecture, engine version and expected extensions. Warm only selected test images initially; record their digests so one test does not silently select different inputs.
- Retain downloaded image layers and deterministic seed recipes. Use synthetic data only. Key any expensive generated seed artifact by schema/engine/extension/recipe version and checksum; restore into isolated per-run databases. Never reuse a dirty database as a known fixture.
- Preserve required startup environment and fixture ownership. A shared database service is valid only where the current harness already supports isolated databases and reset/serialization; do not point all tests at one mutable database merely to avoid container startup.
- Local machine: narrow regressions, Core/policy/app-services unit and sandbox cases, selected PostgreSQL/PgBouncer reproductions, native GTK checks and one isolated memory measurement.
- Merge-tier CI: instrumented coverage, mutation, supported distro/library floors, broad engine matrices and packaged/installed acceptance through the existing Forgejo jobs. Do not register a developer machine as a general untrusted CI runner.
- No added gate or duplicate heavy GitHub run. One Forgejo gate remains the merge authority; local reproductions provide targeted evidence. Offloading compilation to another development machine is a later build/archive pilot in a compatible builder, not a requirement to compile everything twice.

## Nightly boundary and next work

The October 20 nightly inventory and selective rerun plan are in [evidence](../evidence/nightly-778-selective-rerun-2026-10-20/README.md). Interrupted and cancelled jobs are not completed mutation or soak results. These run-specific results do not establish current acceptance; use the exact-source gate for a proposed change.

Existing PostgreSQL coverage must be reused before selecting new cases:

| Existing evidence | What it establishes | Follow-up boundary |
|---|---|---|
| `disconnection::a_restarted_postgres_server_restores_the_existing_pool` | Real server stop/start with durability enabled; existing pool becomes usable through explicit read retries | Application operation identity and generation handling are a separate path |
| `disconnection::a_committed_write_with_a_lost_ack_is_not_replayed_after_reconnect` | Durable stored-state/request evidence for an acknowledged-result loss; historical frozen-candidate result under #593 | Confirm exact-source acceptance instead of recreating the same fixture |
| Release `direct_reconnect_restores_a_verified_session` and `ssh_reconnect_replaces_the_tunnel_and_the_session` | Explicit replacement after proxy path loss | Neither is proof of automatic in-flight operation replay |
| Release `guarded_application_error_does_not_replay_sequence_effects` | Governed SQL errors do not duplicate sequence effects | Keep this refusal if changing any read-retry rule |
| GTK `postgres_ssh_tunnel_loss_retires_session_and_reconnects` | Existing application/session recovery scenario | Extend request-generation and final rendered-state assertions here where applicable |

The inspected source lives in [PostgreSQL disconnection tests](../../crates/drivers/postgres/tests/support/disconnection.rs), [release reconnect tests](../../tests/release/tests/reconnect.rs), [policy transaction tests](../../tests/release/tests/policy_transactions.rs) and [GTK UX scenarios](../../apps/linux/app/tests/gtk_ux.py). This is a source inventory, not a new test run. An automatic replay feature requires an explicit safe-read contract; the upstream behavior is not an instruction to change BookiE's current refusal semantics. Issue #593 already records local frozen-candidate results and asks for exact-source Forgejo acceptance before closure.

Local targeted work can proceed independently of scheduled runs. Keep one local compile owner and the existing serialized merge gate.

Post-release work and its priority live in the [backlog](../backlog.md) and Project #3. This execution plan does not set product scope. Reuse existing driver, release and GTK evidence before adding another run, and refresh each result against the selected issue's exact acceptance.

Acceptance for the reuse pilot: unchanged repeated tests use the exact compiled binaries without recompilation; selected fixtures keep their isolation and durability requirements; resource use remains within measured limits; artifact identity and all unrun layers are recorded. Capacity and storage endurance are measured observations, never inferred from a green unit suite.

## Local reuse pilot result

The [October 20 manifest](evidence/workstation-reuse-2026-10-20/manifest.json) records the Core unit-test reuse pilot, the GTK widget and accessibility runs, and UX test PR preflight. The Core build took 7.48 seconds with six Cargo jobs; both metadata-driven runs passed all 640 tests with four test processes in 2.371 and 2.360 seconds. The second run blocked Cargo, rustc and common compiler/linker command names on PATH and retained the exact binary hash and modification time. The manifest records 76 GTK widget passes and the app test binary identity, but the raw widget output is not retained; the 90-scenario accessibility result is also recorded there. Machine-specific storage, memory and swap readings are omitted from the public manifest. The UX preflight passed 280 harness tests, 1,819 unit tests, 1,794 sandbox tests, the separately selected Redis cancellation test, formatting, Clippy and the guards. These results prove reuse only for the recorded binaries and source inputs. They do not measure physical storage-write reduction, prove compiler-cache hits, or qualify other test tiers.
