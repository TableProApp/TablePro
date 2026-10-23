# Runner maintenance and mini PC isolation

Status: proposed, October 20, 2026. No timer, runner, Docker daemon or virtual machine was changed by this proposal. The other operator owns the serialized Forgejo gate queue. Related infrastructure work: [#573](https://github.com/cozyGarage/BookiE/issues/573); cleanup alone does not satisfy that issue's sizing and concurrency acceptance.

## Observed failure and current limits

The executor cleanup timer already runs hourly with up to five minutes of randomized delay. Adding cron would duplicate it. Inspection of exec-b found `/usr/local/sbin/executor-cleanup.sh` running broad container, volume and image pruning, then scanning Cargo targets for recent file modification times. It also removes `nightly-*` targets using directory age. No shared lock coordinates these deletions with jobs. Reading a cached artifact does not update its modification time, so these checks do not prove a target is idle. When free space remains below its configured 45 GB threshold, the script still exits successfully.

During this session exec-b exhausted its disk and jobs reported ENOSPC. With no compiler or Docker fixture active, removing generated sandbox and PostgreSQL release debug artifacts recovered about 49 GB. A later read-only check found 44 GiB free on the 394 GiB filesystem. This is a dated measurement, not a reservation for the next job. Do not repeat that manual deletion during the other operator's gates.

The mini PC currently runs the exec-e container, n8n, its PostgreSQL database and an Atlassian automation systemd service. It has approximately 30 GiB RAM and 160 GiB available on its 475 GiB root filesystem. Swap contained approximately 15 GiB; this alone does not establish current paging pressure. Exec-e has a 16 GiB memory limit, no CPU quota and the host Docker socket mounted. Its fixture containers are siblings on the host, outside that memory limit. Docker socket access also reaches persistent service containers and volumes. Broad volume pruning is unsuitable for this shared host.

`virsh` and `/dev/kvm` exist, but the system libvirt sockets are disabled and no connection to `qemu:///system` was available. Installed tools do not establish a working VM platform.

## Prepare cleanup before deployment

Keep one existing systemd timer. Version its replacement script, service and installation instructions alongside regression tests. Locate the provisioning owner before deploying; do not maintain conflicting copies in multiple repositories.

The implementation must reach both Forgejo workflows, their shell execution, the installed cleanup service and lock-file provisioning:

1. Give every cache-using shell step a shared lock and cleanup an exclusive nonblocking lock. Use a root-owned lock location that survives reboot through systemd tmpfiles. A failed lock acquisition means skip cleanup with an explicit busy result. A process-name check alone is not coordination.
2. Record target usage while holding the shared lock. Protect recent targets between steps. Inspect all consumers, including installed binaries and nightly jobs, before choosing the idle interval. Directory age alone is insufficient.
3. Restrict deletion to known generated Cargo artifacts inside approved cache roots. Refuse symlinks and preserve source, logs, service data and unrelated files. Never prune host Docker volumes as routine executor maintenance.
4. Report free bytes before and after cleanup. If the required reserve cannot be recovered safely, return failure so systemd exposes the condition. Do not delete active or recently used targets merely to report a healthy result.
5. Test real lock contention with subprocesses, old versus recently used artifacts, symlinks, unrelated files, command failure propagation and insufficient space. Verify that a build holds the lock for its whole shell step. Run focused tests, preflight and the normal gate through its assigned operator.

Stage the lock helper first, then qualify the workflows that acquire it. Activate replacement cleanup only after all older jobs without that lock have drained. Otherwise the exclusive lock gives false assurance. Keep the previous timer configuration available for rollback, but do not restore its destructive pruning while jobs run. Observe an actual timer invocation and subsequent warm-cache build before calling maintenance complete.

## Serialize scheduled runs with gates

On October 20 at 22:19 UTC, PR run #822 and scheduled run #823 both ran widget tests on exec-a using `/var/cache/ci/target/widgets`. Their logs repeatedly alternated build-directory lock waits and app compilation, taking about 34 seconds per selected test while completed tests took approximately 0.1 seconds. Both continued to pass tests. At inspection, the host had 73 GiB disk free and 14 GiB available memory. See the [run evidence on #573](https://github.com/cozyGarage/BookiE/issues/573#issuecomment-6303063907).

The current workflow concurrency group includes the branch ref. A scheduled run on `linux` and a push to a gate branch therefore use different groups. The gate script's local file lock cannot serialize a server-triggered schedule. Before accepting overlapping workloads, coordinate scheduled runs with the gate queue or isolate their build directories and qualify the resulting resource load. Verify this with an actual scheduled-run and branch-run pair; a manual gate pair alone does not cover the failure.

The workflow hotfix gives both merge-tier and nightly workflows the same static concurrency group, `bookie-lab`, with `cancel-in-progress: false`. Forgejo queues these workflows across refs without cancelling the accepted gate. Existing runs retain their original workflow settings; the queue owner must resolve their overlap. Verify the server has concurrency-group queuing enabled and qualify a scheduled-run and branch-run pair before claiming live acceptance.

The proposed cache helper holds shared locks for active jobs. Those locks exclude cleanup, but allow concurrent builds. Cleanup coordination does not satisfy this scheduling requirement.

## Move exec-e gradually

Preserve the existing n8n and Atlassian services during the runner migration. First identify their configuration and backup owners. Verify a restore of the n8n database together with its encryption key; a database backup without the matching key cannot establish usable credential recovery. Keep secrets out of this repository.

Prepare a dedicated Debian runner VM with its own Docker daemon and disk. Its whole-VM CPU and memory limits must cover both the runner and fixture containers. Measure a capacity-one pilot before selecting the final allocation; current host free memory is not a workload peak measurement. Keep sufficient host capacity for services and a bounded cache reserve. Do not allocate the remaining root space wholesale to a new VM.

Use a separate pilot runner label. Verify nested fixture startup, networking, distro floor, package installation, GTK accessibility and cancellation cleanup before assigning the normal executor label. Restrict guest network access to required CI endpoints; verify that the guest cannot read host Docker sockets, service volumes or service credentials. A VM by itself does not prove network isolation.

After a successful gate on the pilot, drain exec-e through the queue owner and retain its configuration for rollback. Retire its registration and generated cache only after the replacement is accepted and service backups are verified. Do not stop active fixtures or remove existing service volumes.

## Evidence required to close this work

- Replacement maintenance tests fail on unsafe behavior and pass on the corrected implementation.
- Every cache consumer participates in coordination; no older uncoordinated jobs remain at activation.
- A timer run skips busy caches and reports an unrecoverable reserve as failure.
- n8n and Atlassian service recovery is demonstrated with the required secrets retained privately.
- The isolated runner passes the existing Forgejo acceptance tier and leaves no owned fixtures behind.
- The old runner is drained and its temporary resources are removed without interrupting services.

References: [Docker daemon security](https://docs.docker.com/engine/security/), [n8n encryption key](https://docs.n8n.io/hosting/configuration/configuration-examples/encryption-key/).

## Prepared implementation and deployment order

The prepared helper is `scripts/ci-cache.py`. Its `run` command acquires a shared lock, marks the selected direct-child target as used, and replaces itself with Bash using `-e -o pipefail`. The lock descriptor remains open through the shell and its children. Its `cleanup` command takes the exclusive lock without waiting, removes only marked Cargo debug/release profiles idle for five days, then considers profiles idle for one day if below the 45 GiB reserve, stopping after a target restores that reserve. Unmarked legacy targets are preserved. The five previously unbounded merge-tier jobs now have explicit 90-minute timeouts; the other merge jobs and all nightly jobs also have explicit limits, up to 150 minutes. The marker records step start; long-running commands remain protected by the inherited lock. Background work must not outlive its job.

The workflow defaults cover all current shell steps in both Forgejo workflows, including checkout. No action or per-step shell override currently bypasses them. Local or manual cache consumers must also invoke the installed helper; the lock cannot protect commands that bypass it. This is coordination for trusted executors, not a sandbox for a malicious job that already controls the host Docker daemon.

Foundry's `scripts/provision-executor.sh` provisions the executor packages and runner account, while lab-playbook's service installer describes the older bookie-ci VM. Neither inspected file owns the live cleanup script. These repository-owned files are the proposed canonical maintenance source; integrate their installation with the current provisioning owner before considering rollout complete. No other repository was edited.

Deployment is pending and must be coordinated with the gate owner:

1. On every host eligible for `any-host` or `debian-host`, install the helper as root-owned `/usr/local/libexec/bookie-ci-cache` with mode 0755. Install `ci/bookie-ci-cache.conf` into `/etc/tmpfiles.d/` and run `systemd-tmpfiles --create` for that file. It creates root-owned `/run/bookie-ci` with mode 0750 and the group-accessible lock inside it; runner jobs cannot create or replace entries in that directory. Confirm the runner can open the resulting lock and invoke a harmless wrapped shell. Install the helper inside exec-e too; a host path is not automatically visible inside its container.
2. Keep the replacement cleanup inactive. Have the queue owner qualify the workflow change through the normal gate. Other open CI PRs, especially #1202, should land first; merge their latest base normally and revalidate this change before its gate. Do not start a second gate.
3. Drain all older jobs and other cache users that do not acquire the lock. For exec-e, run cleanup inside the same container with the same lock inode, or explicitly bind a shared root-owned lock into both environments. A separate host lock with the same pathname is insufficient. Never run this cleanup against the mini PC's service data or host Docker volumes.
4. Replace the existing `executor-cleanup.service` and timer with the files in `ci/`, reload systemd and retain one hourly timer. Do not add cron or keep the old destructive script scheduled. Installation commands are not authorization to stop the other operator's jobs.
5. Verify a busy invocation skips, an idle invocation preserves recent artifacts, and a warm-cache build still passes. Check free bytes and systemd's result. If the reserve remains insufficient, investigate capacity with the queue owner; failure is the intended report, not permission to remove live caches.

The focused tests use temporary cache trees, real child shells and real kernel file locks. A separate reproduction ran a copy of the live old cleanup script with its cache path redirected to a temporary directory and Docker pruning stubbed out. It deleted a recently marked nightly artifact solely because the parent directory was old. The new helper preserves that case. No live cache or Docker resource was touched by that reproduction. Missing-helper failures during test development are not evidence of the legacy defect.

## CI credential and runner trust update, October 23, 2026

Both Forgejo workflows now pass the short-lived repository token to Git as a Basic authorization header scoped to the Forgejo server URL for the checkout command. The token is no longer part of the clone URL, process arguments or persisted `origin` URL. This reduces accidental credential exposure but does not protect the token from code running in that checkout step or other same-user processes on a host runner.

The workflows still use `any-host` and the runner Docker socket. Treat branch execution as trusted-only. The repository change does not provide a security boundary: a dedicated runner VM with its own Docker daemon and disk, no host service mounts, and a separate runner label remains required before accepting less-trusted branch code. The VM and cleanup deployment are not verified by this change. Do not describe runner isolation or cache-helper deployment as complete until the live acceptance evidence above is recorded.
