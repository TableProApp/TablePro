# CI cache safety and runner isolation

Status: proposal. The repository contains a cache-lock helper and workflow integration, but deployment and isolated-runner acceptance remain unverified. Issue [#573](https://github.com/cozyGarage/BookiE/issues/573) owns the live runner sizing and concurrency work.

## Cache maintenance

Cache cleanup must coordinate with every job that can use the cache. Directory age and process-name checks do not prove that a target is idle. Broad container or volume pruning can remove unrelated state and must not be part of routine cache maintenance.

The cleanup path should:

1. Hold a shared lock throughout each cache-using job and take an exclusive, nonblocking lock before cleanup. If the lock is busy, skip cleanup and report that state.
2. Restrict deletion to known generated artifacts under approved cache roots. Refuse symlinks and preserve source files, logs, service data and unrelated files.
3. Report available space before and after cleanup. If the safe cleanup cannot meet its reserve, return a failure rather than deleting active work.
4. Protect recent targets during routine cleanup based on recorded use, not directory modification time alone. If the free-space reserve is still unmet after stale-cache cleanup, evict only marked Cargo profiles in least-recently-used order while holding the exclusive lock. Preserve unmarked legacy directories and stop when the reserve is met.
5. Test lock contention, path boundaries, symlinks, recent targets, command failures and insufficient space with disposable fixtures.

The implementation is in [`scripts/ci-cache.py`](../../scripts/ci-cache.py), with workflow and service integration under [`.forgejo/workflows/`](../../.forgejo/workflows/) and [`ci/`](../../ci/). These files prove repository configuration only; they do not prove deployment on a live runner.

## Gate scheduling

Scheduled runs and branch gates need one shared server-side concurrency group. A local lock cannot serialize workflows that the server starts independently. Existing jobs started before a workflow change may not participate, so drain them before treating the new queue as exclusive. Qualify a scheduled run alongside a branch run before relying on this behavior.

The current merge and nightly workflows declare a shared concurrency group and disable cancellation. This repository configuration does not establish that the runner service honors the queue or that a live pair has been qualified.

## Runner isolation

A job with access to the host Docker socket can control host containers and volumes. Treat code running on such a worker as trusted. Before accepting less-trusted branch code, use a dedicated virtual machine with its own Docker daemon, bounded compute and storage, and no host service mounts. Include fixture containers in capacity measurements and verify network restrictions from inside the guest.

Keep host names, labels, capacity readings, service inventories, credentials and deployment procedures in the operator's infrastructure runbook. They do not belong in this repository. Do not claim isolation, cache deployment or service recovery until the operator records the corresponding acceptance evidence.
