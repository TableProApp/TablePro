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
