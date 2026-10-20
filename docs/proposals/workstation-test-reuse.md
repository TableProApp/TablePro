# Workstation test reuse and upstream follow-up

**Status:** Proposed execution plan, recorded 2026-10-20. Hardware observations are dated evidence, not minimum product requirements. No machine configuration, filesystem, runner registration or test tier is changed by this document.

The [upstream analysis](../archive/upstream-main-analysis-2026-10-20.md) selects reliability investigations before feature work. Use the existing [validation tiers](../validation-playbook.md) to execute those investigations while retaining compiled artifacts. The desktop is a focused development and reproduction machine; Forgejo remains the serialized acceptance gate.

## Observed resources

Read-only inspection found:

| Resource | Observation | Planning consequence |
|---|---|---|
| CPU | Intel i7-11700K, 8 physical cores / 16 logical threads | Begin with 6 Cargo compilation jobs and 4 independent nextest tests; measure before raising concurrency |
| Memory | About 31 GiB usable, about 24 GiB available at inspection | Leave desktop and database headroom; run one compile-heavy task at a time |
| Main storage | 500 GB Samsung 980 PRO NVMe, encrypted Btrfs root/home, about 397 GiB available | Preserve the current build tree; avoid cold builds, broad cleans and repeated package assembly |
| Other storage | Unmounted 500 GB SATA SSD with an existing encrypted layout; unmounted 2 TB SATA SSD with a FAT32 partition | Neither is an approved build-cache destination; no formatting, mounting or migration is selected |
| Temporary memory | `/tmp` is tmpfs, capacity about 16 GiB | Use bounded disposable fixture files only; the whole build tree does not belong here |
| Swap | About 31 GiB zram and about 31 GiB disk swap; disk swap had no use at inspection | tmpfs is not a guarantee of zero NVMe writes under pressure |
| Existing Rust artifacts | Current checkout `target` about 9.7 GiB; Cargo registry about 1.2 GiB | Reuse these rather than starting a target directory for every command |
| Rust tools | rustc/Cargo 1.98.1; nextest 0.9.148; sccache 0.18.0 | Installed nextest matches the repository pin; no tool bootstrap compilation is needed |
| Compiler cache | No `RUSTC_WRAPPER` or `CARGO_TARGET_DIR` override in the inspected shell; sccache reports zero compile requests and a 10 GiB default capacity | Installed sccache does not establish effective compiler-cache reuse; verify hits in a bounded pilot |
| Docker | Host user belongs to Docker group; daemon responds; two images occupy about 445 MB; no containers or volumes present | Docker prerequisites work outside the agent sandbox; prepare only selected fixture images |
| GTK stack | GTK 4.24.1, libadwaita 1.10.0, GtkSourceView 5.22.0 | Useful native Arch desktop evidence; does not establish the supported distro floor |

The maintainer supplied a SMART reading on 2026-10-20: critical warning 0, temperature 31°C, available spare 100%, endurance used 3%, approximately 5.72 TB host data written, 930 power-on hours, zero media errors and zero error-log entries. These counters show no current SMART warning; they do not guarantee future reliability or a remaining service life. There are 17 historical unsafe shutdowns, whose cause is not established by this reading. Use these counters as a baseline and compare write deltas across measured workloads. The installed nvme-cli recommends `sudo nvme log smart /dev/nvme0n1`; the older `smart-log` spelling is deprecated. No drive serial or private host identity is retained here.

## GTK prerequisites for the inspected desktop

The follow-up prerequisite check found `xvfb-run` and the Python `pyatspi` module missing. AT-SPI introspection and the existing D-Bus tools are available. On the inspected Arch/Omarchy installation, the official package names are `xorg-server-xvfb` and `python-atspi`; the latter provides the module imported by the GTK safety harness. The maintainer can install them with:

```bash
omarchy pkg add xorg-server-xvfb python-atspi
```

The maintainer installed both packages, and the follow-up check confirmed `xvfb-run` resolves and `import pyatspi` succeeds. The native Arch GTK widget tier passed all 76 isolated cases under Xvfb. Its first invocation built the app test binary in 47.18 seconds; later Cargo invocations reported 0.22 seconds and reused it. Mesa printed a DRI3 acceleration warning under Xvfb, but no widget test failed. `python-atspi` is available for the separate installed-app accessibility tier; this widget run does not exercise that tier.

The AT-SPI smoke initially exposed three CSV import test failures with the portal file chooser. The test waited only for `ROLE_DIALOG`, then selected the path without waiting for the chooser to resolve it. The portal exposes `ROLE_FILE_CHOOSER`; after using the existing chooser-role and path-selection helpers, all three affected scenarios passed with the same release binary. The full accessibility smoke then passed all 90 scenarios with that binary. This is a test harness compatibility issue, not a reproduced application defect. See [issue #1165](https://github.com/cozyGarage/BookiE/issues/1165) and the [workstation evidence manifest](../evidence/workstation-reuse-2026-10-20/manifest.json). The release build took 194 seconds in the shared target. Sampled available memory stayed at or above 22 GiB and swap usage stayed at 1.3 GiB; free disk moved from 392 to 391 GiB. NVMe physical write deltas were not measured.

Rust, nextest, sccache, Docker/buildx, mold and Clang are already present; installing another copy does not improve artifact reuse. Configure and measure the cache strategy below instead.

## Cache and artifact policy

1. Keep one long-lived target tree per active build owner and compatible configuration. Use the current warm target for its current checkout. A worktree that changes source is a separate build owner; share compiler-cache objects, not concurrent writes to one target tree. Do not create a new target for every test filter or new commit.
2. Keep normal development, coverage and mutation artifacts separate because instrumentation and source mutation change the build. Distro/target/toolchain/feature differences can also require separate artifacts. Do not use a commit SHA as the target-directory name; use it in an evidence manifest instead.
3. Start with `CARGO_BUILD_JOBS=6` for a single compilation and four concurrent pure tests. Serialize GTK focus/input tests and initially run one database fixture operation at a time. These are proposed starting limits, not benchmark results. Docker tests that each launch containers need their own measured limit.
4. Preserve the repository's existing debug settings. Choose one cache strategy per build owner: incremental compilation for the existing edit loop, or nonincremental compilation with `RUSTC_WRAPPER=sccache` for repeated CI-like builds. Rust sccache does not support incremental compilation. Do not toggle profiles, wrappers, flags or feature sets between every command. Compare the two strategies in a small pilot before migrating a warm tree.
5. Share a bounded sccache directory across compatible worktrees. A cache hit still restores files and does not eliminate linking or every write. Monitor hits, misses, non-cacheable reasons, disk growth and elapsed time; tool installation alone is not evidence. Preserve stable source paths where practical. Do not expect arbitrary absolute-path changes to reuse every crate.
6. Do not run routine `cargo clean`, broad Docker prune or cache deletion between tests. Clean only a diagnosed stale artifact or a reviewed cache owner after its processes stop. Keep a free-space reserve of at least 20% and a preliminary 60 GiB ceiling for workstation build artifacts plus 10 GiB sccache; check real growth before treating these as adequate long-term quotas. Cleanup is manual until ownership and retention are proven.
7. Keep ephemeral fixture working data in a bounded temporary area only when durability is irrelevant. Crash recovery, lost-COMMIT, fsync and persistent-state tests must retain their intended real-storage semantics. Do not disable durability globally to reduce writes. Preserve the existing distinction between reusable fast PostgreSQL fixtures and dedicated durable fixtures.

Cargo's [build-cache documentation](https://doc.rust-lang.org/cargo/reference/build-cache.html) explains target artifacts and freshness. The [sccache Rust limitations](https://github.com/mozilla/sccache/blob/main/docs/Rust.md) govern which compiler invocations it can cache. These sources do not promise a zero-write test loop.

## Build once, run selected tests repeatedly

Prefer normal Cargo freshness for a single narrow run. For repeated cases at one unchanged source/configuration, nextest supports execution from stored build metadata without rebuilding. The installed 0.9.148 help exposes the commands below. The command pattern was exercised by the local Core pilot recorded below.

Example for the Core unit-test binary only, from the checkout that owns its existing target:

```bash
export CARGO_BUILD_JOBS=6
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
  --test-threads 4
```

Use nextest filters to repeat the relevant cases from those same binaries. Refresh the build metadata after any source, generated input, dependency, toolchain, profile, feature or compile-environment change. Record source SHA plus dirty-diff identity and relevant untracked/generated input hashes, Cargo.lock hash, compiler version, target, flags, features, selected binaries and nextest version beside it. Refuse stale metadata as current-source evidence. This example covers Core unit tests only; it does not replace preflight or another tier.

Use [nextest archives](https://nexte.st/docs/ci-features/archiving/) when distributing the same built test binaries across machines. Build in the pinned oldest-compatible CI environment, retain the archive/checksum and exact source revision, and verify runtime libraries and CPU compatibility on the executor. Arch-built dynamic binaries are not automatically runnable on Debian. Do not compile distributed artifacts with `target-cpu=native` on this workstation. Source fixtures and external services still need provisioning.

Avoid repeatedly extracting an archive for each filter: extract once into an owned location and reuse its metadata. The first pilot should prove two executions use the same binaries with no rustc/linker activity and no extra archive extraction. Keep normal, coverage and mutation evidence distinct; ordinary test binaries cannot substitute for instrumented coverage or mutant rebuilds.

## Images, fixtures and lab allocation

The private infrastructure design already describes an image registry/pull cache and shared compiler-cache storage. Those design entries are not proof that the current endpoints, credentials, retention or recovery behavior work. Verify the actual lab service before adding another registry or changing Docker daemon configuration. Public BookiE documentation should not contain private endpoint addresses, credentials, VM inventory or internal topology.

- Resolve existing workflow image references to the lab registry or pull cache without changing fixture semantics. Retain pinned digests, architecture, engine version and expected extensions. Warm only the PostgreSQL/PgBouncer and selected CI images initially; record their digests so one test does not silently select different inputs.
- Retain downloaded image layers and deterministic seed recipes. Use synthetic data only. Key any expensive generated seed artifact by schema/engine/extension/recipe version and checksum; restore into isolated per-run databases. Never reuse a dirty database as a known fixture.
- Preserve required startup environment and fixture ownership. A shared database service is valid only where the current harness already supports isolated databases and reset/serialization; do not point all tests at one mutable database merely to avoid container startup.
- Desktop: narrow regressions, Core/policy/app-services unit and sandbox cases, selected PostgreSQL/PgBouncer reproductions, native Arch GTK checks and one isolated memory measurement.
- Lab: instrumented coverage, mutation, supported distro/library floors, broad engine matrices and packaged/installed acceptance through the existing Forgejo jobs. Avoid scheduling workloads on a runner marked unavailable or with an unresolved hardware fault. Do not register the everyday desktop as a general untrusted CI runner.
- No added gate or duplicate heavy GitHub run. One Forgejo gate remains the merge authority; local reproductions provide targeted evidence. Offloading compilation to the desktop is a later build/archive pilot in a compatible builder, not a requirement to compile everything twice.

## Nightly boundary and next work

The inspected nightly is Forgejo #778 at `84f03a0385562d97554c47a06e6cebab189c3004`. Its run-level status says failure, but its jobs endpoint still reports active work: 8 successful, 1 failed, 6 running, 4 waiting and 8 blocked at the recorded observation. The failed job is agentd mutation. Core/policy mutation shards are still running. This is not a finished-nightly result. The agentd mutation log reports 115 mutants tested: 8 missed, 65 caught and 42 unviable. Six missed mutants match the baseline; the two new survivors replace the sequence-synchronization forwarding methods with `Ok(())`. This establishes a coverage gap in that run, not a reproduced production bug or an infrastructure failure. Triage the forwarding behavior under existing #559 before considering a rerun; rerunning unchanged tests does not address the missing assertion. Poll the same run's jobs endpoint until no job remains active; blocked jobs need a final disposition rather than being counted as passed. Do not dispatch another nightly or full gate while waiting.

Existing PostgreSQL coverage must be reused before selecting new cases:

| Existing evidence | What it establishes | Follow-up boundary |
|---|---|---|
| `disconnection::a_restarted_postgres_server_restores_the_existing_pool` | Real server stop/start with durability enabled; existing pool becomes usable through explicit read retries | Application operation identity and generation handling are a separate path |
| `disconnection::a_committed_write_with_a_lost_ack_is_not_replayed_after_reconnect` | Durable stored-state/request evidence for an acknowledged-result loss; historical frozen-candidate result under #593 | Confirm exact-source acceptance instead of recreating the same fixture |
| Release `direct_reconnect_restores_a_verified_session` and `ssh_reconnect_replaces_the_tunnel_and_the_session` | Explicit replacement after proxy path loss | Neither is proof of automatic in-flight operation replay |
| Release `guarded_application_error_does_not_replay_sequence_effects` | Governed SQL errors do not duplicate sequence effects | Keep this refusal if changing any read-retry rule |
| GTK `postgres_ssh_tunnel_loss_retires_session_and_reconnects` | Existing application/session recovery scenario | Extend request-generation and final rendered-state assertions here where applicable |

The inspected source lives in [PostgreSQL disconnection tests](../../crates/drivers/postgres/tests/support/disconnection.rs), [release reconnect tests](../../tests/release/tests/reconnect.rs), [policy transaction tests](../../tests/release/tests/policy_transactions.rs) and [GTK UX scenarios](../../apps/linux/app/tests/gtk_ux.py). This is a source inventory, not a new test run. An automatic replay feature requires an explicit safe-read contract; the upstream behavior is not an instruction to change BookiE's current refusal semantics. Issue #593 already records local frozen-candidate results and asks for exact-source Forgejo acceptance before closure.

The maintainer subsequently directed local implementation and tests to proceed while the hours-long nightly continues. Local targeted work is independent of the lab gate; do not wait for nightly completion to build or reproduce locally. Keep one local compile owner and the existing serialized Forgejo merge gate.

Next work:

1. Record final job outcomes and identify real test gaps versus infrastructure failures. Reuse existing mutation and CI issues; rerun only a justified failed job after diagnosis. Check the night's source against the current Linux source before assigning a regression to a branch.
2. Refresh the analysis branch against latest GitHub Linux, preserving the separate documentation-cleanup worktree. Finalize the documentation contribution using the docs-only checks and current repository merge rules; it needs no heavy gate.
3. Run the Core build/metadata reuse pilot locally while the nightly proceeds. Measure first build, unchanged rerun, one-file change, compiler-cache behavior, target size and memory. Keep the existing warm tree until the measurements support a switch. No benchmark is claimed yet.
4. Start the first PostgreSQL restart/lost-ack investigation under existing #593/#590, with recorded B3/B4/UX handoffs as required. Use #594 for the cross-consumer corpus, then #1029/#593 for the crash-save scenario and #1032/#554 for retained memory. Keep #947's reconciliation design separate from automatic write replay.
5. Use the existing tier for each case and the serialized Forgejo gate for code changes. Run a full tier once when required by the change; avoid repeating an unchanged heavy run simply to reproduce evidence already available from its owning gate.

Acceptance for the reuse pilot: unchanged repeated tests use the exact compiled binaries without recompilation; selected fixtures keep their isolation and durability requirements; memory remains within desktop headroom; no swap or low-space incident occurs; artifact identity and all unrun layers are recorded. Hardware capacity and endurance remain measured observations, never inferred from a green unit suite.

## Local reuse pilot result

The [October 20 manifest](../evidence/workstation-reuse-2026-10-20/manifest.json) records the Core unit-test reuse pilot, local GTK runs and UX test PR preflight. The Core build took 7.48 seconds with six Cargo jobs; both metadata-driven runs passed all 640 tests with four test processes in 2.371 and 2.360 seconds. The second run blocked Cargo, rustc and common compiler/linker command names on PATH and retained the exact binary hash and modification time. GTK widget and targeted accessibility results include their binary hashes and resource samples. The UX preflight passed 280 harness tests, 1,819 unit tests, 1,794 sandbox tests, the separately selected Redis cancellation test, formatting, Clippy and the guards. These results prove reuse only for the recorded binaries and source inputs. They do not measure physical NVMe write reduction, prove compiler-cache hits, or qualify other test tiers.
