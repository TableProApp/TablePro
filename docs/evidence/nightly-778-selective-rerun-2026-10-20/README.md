# Forgejo nightly #778 selective rerun plan

**Recorded:** 2026-10-20 00:51 UTC  
**Run source:** `84f03a0385562d97554c47a06e6cebab189c3004`  
**Purpose:** preserve completed evidence and retry only work that can produce new evidence.

## Current evidence

Forgejo reports run #778 cancelled. At 00:51 UTC, its job list showed eight successes, ten failures, one cancelled mutation job, and three GTK soak jobs still running. The maintainer confirmed the GTK soak rerun is intentional. Runner logs showed those soak jobs still building; leave them running and do not queue another run until they finish.

| Job | Result | What it establishes |
|---|---|---|
| Coverage and six Docker coverage jobs | Passed | Keep these results; do not rerun them for this recovery. |
| app-services mutation | Passed: 185 mutants, 3 missed, all 3 in baseline; 149 caught, 29 unviable, 4 timeouts | No new missed mutants in this run. |
| agentd mutation | Failed: 115 mutants, 8 missed, 6 baseline; 2 new misses | Both new misses replace sequence-sync forwarding methods with `Ok(())`. PR #1162 adds tests that catch these no-op mutations, but that PR's source is not this run's SHA. |
| Redis mutation | Failed: 143 mutants, 39 missed, 0 baseline; 81 caught, 23 unviable | New test gaps cover connection/TLS errors, Redis error and value conversion, scan pagination, transaction counts, and metadata results. See issue [#559](https://github.com/cozyGarage/BookiE/issues/559). |
| SSH mutation | Failed: 487 mutants, 127 missed, 0 baseline; 235 caught, 120 unviable, 5 timeouts | New test gaps span askpass framing, host-key and known-host behavior, forwarding/lifecycle, OpenSSH routing/session handling, and process cleanup. See issue [#559](https://github.com/cozyGarage/BookiE/issues/559). |
| Transport mutation | Failed: 162 mutants, 13 missed, 11 baseline; 115 caught, 34 unviable | Two new misses: saved SSH route can become `None`; Flatpak detection can always return `true`. These are coverage gaps, not proven production defects. |
| Core shards 1–4 and Policy shards 1–2 | Failed without completed mutation summaries | All six ended by termination. OOM evidence was confirmed twice: three Core shards were interrupted at 23:52:37 UTC with an 18.8 GiB runner memory peak; Core shard 4 and both Policy shards were interrupted at 00:48:52 UTC during a second runner OOM (11.2 GiB service peak). Do not count partial output as mutation results. |
| PostgreSQL mutation | Cancelled at 00:51:11 UTC | The log ends with a cancelled command and has no final mutant/baseline summary. Partial misses are not a completed result. |
| GTK soak jobs 1–3 | Still running at 00:51 UTC | Intentional maintainer rerun. Do not cancel or overlap it. |
| Arch package, values, and three Ubuntu GTK jobs | Cancelled | No result from this run. Revisit after mutation recovery; do not infer a code failure from cancellation. |

## Plan for October 21

1. **Wait for the intentional GTK soak tasks to finish.** The run-level cancelled status did not mean all runner work had stopped. Recheck the Forgejo job list and runner processes before queuing anything. Do not stop, clean, or restart runner-owned work.
2. **Do not launch a full nightly dispatch to retry this run.** The current `workflow_dispatch` has no selection inputs, so it expands the full coverage and mutation matrix again. Preserve the eight successful jobs.
3. **Retry only the cancelled PostgreSQL mutation job once**, if Forgejo offers a job-level rerun for #778. This can complete its interrupted report without repeating the successful coverage jobs. If the UI only offers a whole-workflow rerun, stop rather than rerunning the matrix.
4. **Treat the OOM-interrupted shards as capacity failures.** Do not queue Core shards 1–4 or Policy shards 1–2 together. Before retrying Core, change scheduling so one memory-heavy mutation job runs at a time, or use a runner with more memory. If the first isolated Core shard OOMs again, stop the Core retries and fix capacity first. Keep each shard's output separate.
5. **Do not retry completed mutation-gap jobs unchanged.** They use the same tests and immutable source SHA, so another run would repeat the same survivors. Merge the sequence-forwarding regression tests from #1162 before checking agentd again. Add and locally verify focused tests for the Redis, SSH, and transport survivors before scheduling those packages again.
6. **Do not classify the three GTK soak attempts as nightly failures.** They were deliberately started by the maintainer and are still in progress. Record their final counts from their own logs when they finish.
7. **Only rerun downstream package/value/GTK jobs when their required mutation and Docker prerequisites are available.** Their cancellation gives no pass or fail evidence.

The local workstation plan in [workstation test reuse](../../proposals/workstation-test-reuse.md) remains the low-write path for focused checks: reuse its existing Cargo target tree and nextest artifacts, run one compile-heavy task at a time, and avoid `cargo clean`. No local or Forgejo rerun is claimed by this document.

## Cancellation follow-up

The maintainer subsequently cancelled the remaining run, including the intentional GTK soak retries. The final job inventory is eight successes, ten failures, and nine cancellations. Read-only process checks on both inspected executors found no remaining mutation, Cargo build/test, or GTK safety command. The successful jobs remain reusable evidence for this source SHA; the cancelled soak jobs provide no completed soak result.

Tomorrow's recovery starts from this terminal inventory. Skip the eight successful jobs. Retry cancelled PostgreSQL mutation separately if needed. Keep Core and Policy mutation retries isolated until their memory requirements are controlled. Completed mutation-gap jobs need regression tests before a useful rerun; job retries at the old SHA cannot include new tests. A dispatch at a new SHA currently expands the whole nightly, so selective dispatch support must be implemented and validated before using it to avoid repeating successful jobs.
