# Connection handling

Source checked in the B4 Linux working tree on 2026-10-07. [ADR 0008](decisions/0008-connection-and-session-ownership.md)
owns identity and trust, [ADR 0005](decisions/0005-server-side-cancellation.md)
cancellation, and [the B4 board](b4-task-board.md) remaining acceptance.
The [September connection audit](archive/connections-history.md) retains older source
claims and coverage tables; its gaps are not current status.

## Shared assembly and ownership

GUI and agentd use `tablepro-transport` to resolve saved configuration/secrets,
assemble options, open the selected SSH route, and connect the driver. Consumers
receive `PolicyGuard` handles. MCP scopes and connection allowlists apply in
addition to SQL policy. Dedicated editor sessions retain their own physical
identity; loss refuses subsequent SQL rather than using a pool or replaying it.

Saved UUID, live handle, editor session and namespace are distinct owners.
The GUI monitor watches tunnel closure and driver fault signals as well as ping;
replacement changes identity and invalidates old editor sessions. Stop visibility
uses the driver's capability, not an engine-name list. Actual loss/cancellation
outcomes and test ownership are in [disconnection contracts](disconnection-contracts.md).

GUI uncertainty is scoped to a live connection generation. Journal failure
remains shared. Agentd still supplies one shared `AuditState` and has no guard
fault sink; headless generation isolation and forced retirement remain open.
Successful ping alone cannot prove safe reuse after a caught driver panic.

## TLS identity and evidence

The dial endpoint and authenticated service hostname are separate. SSH retains
the saved service identity. Where supported, verifying connections forward a
private Unix socket; other drivers must explicitly verify the original hostname
over TCP or refuse. Local PostgreSQL sockets reject SSH and TLS; forwarded
sockets retain the remote identity.

PostgreSQL's release fixture covers TLS through SSH. Driver TLS fixtures cover
direct CA/hostname/encryption and no-fallback cases, including SQL Server; B4-1
and B4-2 also cover MySQL and SQL Server TLS through real SSH routes. See
[testing](testing.md) for commands and [the release audit](archive/release-audit-2026-10-03.md)
for historical results.

Saved custom CA and client certificate/key paths are assembled through saved
connections, bundles, GUI setup, and agentd transport. PostgreSQL and MySQL
drivers opt in; other drivers refuse configured client identities. TLS modes
that can fall back to plaintext are rejected, and missing, partial, non-file,
or oversized identity material fails closed. Local PostgreSQL fixtures prove
required-client-cert authentication through direct and SSH saved routes, reject
missing/untrusted identities, and accept a rotated identity. MySQL's driver TLS
fixture proves the same direct/SSH, missing/untrusted, and rotation cases. GTK
opens and queries a saved PostgreSQL mTLS connection; agentd proves saved mTLS
directly and through its saved SSH route, and rejects an untrusted identity.
These are local source/test results; installed-package and hosted acceptance
remain separate.

PostgreSQL and MySQL Verify CA and Verify Full use the operating system trust
store when no custom authority is named. A named authority is added to those
roots. Verify CA checks the certificate chain; Verify Full also checks the
service hostname.
Do not promise certificate pinning or Kerberos qualification without their
specific native evidence. Typed keyring failure propagates instead of becoming
a missing password; see [storage](storage.md#secrets).

## Built-in SSH trust

The GUI defaults to `UnknownHostKey::Refuse` and installs a prompter. An unknown
key requires explicit consent before persistence; decline/cancel must write no
key. A changed key is refused. Each hop owns its own trust decision. Agentd is
unattended and refuses unknown keys. Built-in known hosts are distinct from
OpenSSH's `~/.ssh/known_hosts`; running system `ssh` does not populate the
built-in store. Native and installed acceptance remain on F6/G5 and the
[manual checklist](manual-verification-0.2-features.md).

## System OpenSSH

A saved tunnel can select `client: open_ssh`. Its ControlMaster/forward lives
in a private runtime directory; `StrictHostKeyChecking=ask` applies to the
destination. GUI prompts explicitly and agentd declines unanswered prompts.
Saved passwords/passphrases answer only a matching destination/key prompt.
Jump routing comes from `~/.ssh/config`/`ProxyJump`; saved per-hop chains are
refused for this backend. Built-in SSH supports saved chains and ssh-agent.

Inside Flatpak, selecting system OpenSSH fails with an explicit message before
resolving saved SSH credentials or dispatching the database driver. The client
does not switch to built-in SSH; select that backend explicitly if it is wanted.
Native system OpenSSH remains available outside Flatpak. The executable
`tablepro-askpass` helper must be installed beside the app or on PATH. The Debian
standalone builder includes the helper, but debhelper rules and package
validation need I1. Flatpak package/runtime behavior remains a separate
acceptance check.

## Remaining evidence

Use B4 task IDs for TLS, trust, audit, cache and installed route work. U4 owns
permanent-error retry classification. U5's source-level and local route/consumer
acceptance is recorded in B4-14; installed-package, hosted CI, native engine
oracles, Wayland, and package rollback remain separate proof. Preserve safe
refusal for combinations without exact support.
