# Connection handling

[ADR 0008](decisions/0008-connection-and-session-ownership.md) owns identity and trust; [ADR 0005](decisions/0005-server-side-cancellation.md) owns cancellation. The B4 lane on [Project #3](https://github.com/users/cozyGarage/projects/3) owns remaining acceptance. This guide describes current contracts; check the code and owning issue before relying on a time-sensitive acceptance claim. The [September connection audit](archive/connections-history.md) is historical evidence only.

## Shared assembly and ownership

GUI and agentd use `tablepro-transport` to resolve saved configuration/secrets, assemble options, open the selected SSH route, and connect the driver. Consumers receive `PolicyGuard` handles. MCP scopes and connection allowlists apply in addition to SQL policy. Dedicated editor sessions retain their own physical identity; loss refuses subsequent SQL rather than using a pool or replaying it.

Saved UUID, live handle, editor session and namespace are distinct owners. The GUI monitor watches tunnel closure and driver fault signals as well as ping; replacement changes identity and invalidates old editor sessions. Stop visibility uses the driver's capability, not an engine-name list. Actual loss/cancellation outcomes and test ownership are in [disconnection contracts](disconnection-contracts.md).

GUI and agentd scope connection state to the live generation. Agentd creates an `AuditState` generation for each cached session and attaches a fault sink that retires only the matching session, even if its ping still succeeds. Journal failure remains shared across sessions.

After a connection attempt is classified, permanent login and database errors stop the reconnect loop: authentication failures (class 28, including a wrong password, unknown role or no `pg_hba.conf` entry) and a missing database (3D000) are not retried. A busy server (53300) and network faults remain retryable. PostgreSQL's initial SQLx pool startup can retry connection attempts until its acquire deadline before the driver returns an error; this is separate from the app's reconnect classification.

## TLS identity and evidence

The dial endpoint and authenticated service hostname are separate. SSH retains the saved service identity. Where supported, verifying connections forward a private Unix socket; other drivers must explicitly verify the original hostname over TCP or refuse. Local PostgreSQL sockets use a socket directory plus port. MySQL and MariaDB local sockets use the full socket-file path. Local sockets reject SSH and TLS; forwarded sockets retain the remote identity. Selecting a local socket never falls back to TCP.

PostgreSQL's release fixture covers TLS through SSH. Driver TLS fixtures cover direct CA/hostname/encryption and no-fallback cases, including SQL Server; MySQL and SQL Server fixtures also verify TLS through real built-in SSH routes. See [testing](testing.md) for commands and [the release audit](archive/release-audit-2026-10-03.md) for historical results.

Saved custom CA and client certificate/key paths are assembled through saved connections, bundles, GUI setup, and agentd transport. PostgreSQL and MySQL drivers opt in; other drivers refuse configured client identities. TLS modes that can fall back to plaintext are rejected, and missing, partial, non-file, or oversized identity material fails closed. Local PostgreSQL fixtures prove required-client-cert authentication through direct and SSH saved routes, reject missing/untrusted identities, and accept a rotated identity. MySQL's driver TLS fixture proves the same direct/SSH, missing/untrusted, and rotation cases. GTK opens and queries a saved PostgreSQL mTLS connection; agentd proves saved mTLS directly and through its saved SSH route, and rejects an untrusted identity. These are local source/test results; installed-package and hosted acceptance remain separate.

MongoDB's TLS backend has no CA-only mode, so `VerifyCa` also verifies the hostname there (the 2026-09-07 audit records the same for Redis). PostgreSQL and MySQL Verify CA and Verify Full use the operating system trust store when no custom authority is named. A named authority is added to those roots. Verify CA checks the certificate chain; Verify Full also checks the service hostname. Do not promise certificate pinning or Kerberos qualification without their specific native evidence. Typed keyring failure propagates instead of becoming a missing password; see [storage](storage.md#secrets).

## Built-in SSH trust

The GUI defaults to `UnknownHostKey::Refuse` and installs a prompter. An unknown key requires explicit consent before persistence; decline/cancel must write no key. A changed key is refused. Each hop owns its own trust decision. Agentd is unattended and refuses unknown keys. Built-in known hosts are distinct from OpenSSH's `~/.ssh/known_hosts`; running system `ssh` does not populate the built-in store. Installed trust-refusal and audit acceptance are tracked under B4-7; overall Arch/Hyprland package acceptance is tracked under PKG-1. Steps are in the [manual checklist](manual-verification-0.2-features.md).

## System OpenSSH

A saved tunnel can select `client: open_ssh`. Its ControlMaster/forward lives in a private runtime directory; `StrictHostKeyChecking=ask` applies to the destination and every `ProxyJump` hop. GUI prompts explicitly and agentd declines unanswered prompts. Saved passwords/passphrases answer only a matching destination/key prompt. Jump routing comes from `~/.ssh/config`/`ProxyJump`; effective `ProxyCommand` routes are refused. Saved per-hop chains are refused for this backend. Built-in SSH supports saved chains and ssh-agent.

Inside Flatpak, selecting system OpenSSH fails with an explicit message before resolving saved SSH credentials or dispatching the database driver. The client does not switch to built-in SSH; select that backend explicitly if it is wanted. Native system OpenSSH remains available outside Flatpak. The executable `tablepro-askpass` helper must be installed beside the app or on PATH. The Debian builder installs it with the app binaries, and package validation rejects a build without it. Flatpak package/runtime behavior remains a separate acceptance check.

## Remaining evidence

Use the current B4 task IDs in [Project #3](https://github.com/users/cozyGarage/projects/3) for TLS, trust, audit, cache and installed-route work. Source-level and local route results do not replace hosted checks, native engine oracles, Wayland acceptance or package rollback. Preserve safe refusal for combinations without exact support.

## Daemon session cache and DuckDB flat files

A `bookie-agentd` session key includes the saved transport fields plus a digest of Secret Service secret values and SSH private-key, TLS CA, and TLS client certificate and private-key contents. Rotating any of them opens a new session. Handles already issued keep the session they hold until released. If a secret or material file cannot be read, a new open is refused instead of serving the cache ([bug consistency review](archive/bug-consistency-2026-09.md)).

For a DuckDB flat-file connection the driver pins the checked file before DuckDB opens it: it opens the path with `O_PATH` and `O_NOFOLLOW`, checks identity, reopens through the descriptor with `O_NONBLOCK` so a replaced FIFO cannot hang setup, makes a private same-filesystem hard link, and allows only that alias. If pinning cannot be applied, setup fails closed. This is a DuckDB-level path restriction, not an operating-system sandbox ([DuckDB read-only record](archive/duckdb-read-only-aud10-2026-10-10.md)).
