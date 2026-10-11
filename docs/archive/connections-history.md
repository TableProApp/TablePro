# Historical connection audits

Archived from `aeac107a4` on 2026-10-03. The September audit and subsequent
notes below describe their dated source, including obsolete gaps and advice.
Use [connection handling](../connections.md) and [the B4 board](../b4-task-board.md)
for current rules and acceptance. Missing cache reports do not establish a pass.

# Original connection handling

Historical connection audit: 2026-09-07. The original audit and its coverage table below are dated snapshots. Later additions retain their own dates. Current B4 acceptance is in [the task board](../b4-task-board.md), with evidence availability in [the consistency review](architecture-consistency-review-2026-10-03.md).

TablePro is a connection engine before it is a grid. This document records what
the connection layer did at that checkpoint, what is proven, what is known to be
wrong, and what has never been exercised. Every claim below was read out of the
source at the audit date. Status terms match [ROADMAP.md](../../ROADMAP.md):
**implemented** means the code and unit tests exist, **integrated** means every
production entry point uses it, **release-verified** means a deterministic
real-service test proves it.

## The layers

A connection is assembled in one direction, and every surface uses the same path.

```
saved connection
   │
   ├─ tablepro-transport   resolve secrets, build ConnectOptions,
   │                       resolve the SSH chain, open the tunnel,
   │                       set the service endpoint
   │
   ├─ driver.connect()     choose the wire transport, negotiate TLS,
   │                       authenticate, open the pool
   │
   └─ PolicyGuard          classify, evaluate, approve, mask, audit
```

Two ideas carry most of the security weight:

- **Dial address and service identity are separate.** `ConnectOptions.host` is
  where bytes go. `service_endpoint` is who the server must prove it is. A
  tunnel rewrites the first and never the second, so `VerifyFull` through SSH
  still checks the certificate against the real database hostname. See
  `ConnectOptions::service_address` and `ConnectOptions::transport`.
- **Verifying connections prefer a Unix socket over a local TCP port.** When the
  TLS mode verifies certificates and the driver supplies a socket name, the SSH
  chain forwards to a private directory (mode `0700`) instead of a loopback
  port. Nothing else on the machine can reach the forwarded database, and the
  TLS server name cannot be confused with `127.0.0.1`.
- **Local and forwarded sockets are different transports.** A saved PostgreSQL
  connection may name a local socket directory directly. Local sockets reject
  SSH and TLS, while an SSH-created socket retains the remote service identity
  required by certificate verification.

## Transport support by driver

| Driver | TCP | Unix socket | HTTP(S) | TLS modes honoured | Custom CA | Client cert | Connect timeout |
|---|---|---|---|---|---|---|---|
| PostgreSQL | yes | direct local and SSH-forwarded | n/a | all five on TCP; disabled locally | yes | no | pool acquire only |
| MySQL | yes | no | n/a | all five | yes | no | pool acquire only |
| SQL Server | yes | no | n/a | Disabled / encrypt / verify (CA and Full identical) | yes (implemented) | no | 5 s |
| SQLite | n/a | n/a (local file) | n/a | n/a | n/a | n/a | pool acquire only |
| ClickHouse | n/a | no | yes | Disabled / encrypt / verify (CA and Full identical) | yes | no | 5 s probe |
| Redis | yes | no | n/a | Disabled / encrypt / verify (CA and Full identical) | yes | no | 5 s |
| MongoDB | yes | no | n/a | Disabled / encrypt / verify (CA and Full identical) | yes | no | 5 s |
| DuckDB | n/a | n/a (local file) | n/a | n/a | n/a | n/a | n/a |

"Pool acquire only" means the driver bounds how long it waits for a pooled
connection but does not bound the initial TCP or TLS handshake.

The [bug and consistency audit](bug-consistency-2026-09.md) records its September source baseline; the [September audit](stabilization-2026-09.md) distinguishes historical base-commit hosted evidence from newer local changes. The driver TLS fixture also covers MySQL, ClickHouse, Redis and MongoDB; it is not a full SSH/reconnect fixture.

## What is release-verified

The complete TLS/SSH/reconnect fixture is PostgreSQL, through the fixture in
`tests/fixtures/postgres-release`. That fixture proves, against a real server:

- `VerifyFull` succeeds against the certificate hostname and fails against a
  hostname outside the certificate.
- `VerifyCa` and `VerifyFull` both reject an unknown certificate authority.
- A TCP-forwarded `VerifyFull` never verifies the local dial address.
- A verifying session through SSH forwards over a private Unix socket and uses
  the original database hostname.
- An SSH tunnel reaches a database with no published port.
- Cutting the database path and cutting the bastion path both fail queries, and
  a fresh connection recovers in each case.
- The shared transport carries a tunnelled session for the GUI and the agent
  daemon identically, and fails closed when the bastion is unreachable.

Everything else in the table above is implemented and, at best, covered by
container integration tests that connect in plaintext.

## Known problems

Confirmed by reading the source. Ordered by severity.

### 1. MongoDB silently ignores the TLS setting — fixed

**Closed on 2026-08-19.** The driver now sets the client's TLS options from the
selected mode and honours a saved certificate authority. Because the rustls
backend has no CA-only mode, `VerifyCa` verifies the hostname as well, which is
stricter than requested and never weaker. The defect was reproduced first: a
`VerifyFull` connection to a TLS-only server failed with `unexpected end of
file`, proving the client was speaking plaintext. Release-verified by the
driver TLS tier.

### 2. Redis cannot use TLS at all, and defaults to trying — fixed

**Closed on 2026-08-19.** The dependency now enables `tls-rustls`, a verifying
mode reads the connection's certificate authority through `build_with_tls`, and
an encrypt-only mode uses the client's `#insecure` form. The defect was
reproduced first against a TLS-only server: `can't connect with TLS, the feature
is not enabled`. Release-verified by the driver TLS tier. The connect attempt is
now bounded at five seconds as well.

### 3. A private certificate authority is unusable on every driver — fixed

**Closed on 2026-08-19.** `SavedConnection` now carries `tls_root_cert`, the
connect dialog exposes it whenever the selected mode verifies certificates, and
`connect_options_for` threads it into `TlsConfig.root_cert`. Release-verified
against the fixture: a saved connection naming the fixture authority verifies a
privately issued certificate, one naming an unrelated authority is refused, one
naming none fails against the system trust store, and an encrypt-only mode
ignores the setting. PostgreSQL and MySQL consume the field; SQL Server,
ClickHouse, Redis, and MongoDB still ignore it, which is item 5 below.

### 4. `TlsConfig` advertises three capabilities that nothing implements

`client_cert`, `client_key`, and `pinned_fingerprint` are defined, serialized,
and read by no driver. Mutual TLS and certificate pinning do not exist. A field
that is stored and ignored is worse than an absent one, because a saved file can
carry a setting the user believes is in force.

### 5. TLS modes collapse on SQL Server

**ClickHouse closed on 2026-08-19.** It now builds its own HTTP connector, so
Prefer and Require encrypt without verifying, Verify Ca and Verify Full check
the chain, and a saved certificate authority is honoured. Both halves of the
defect were reproduced first: `VerifyFull` with the fixture authority failed
because the driver could only use the bundled root store, and `Require` failed
too, because asking for encrypt-only silently got full verification against
roots that do not know a private certificate.

SQL Server still maps Verify Ca and Verify Full to the same configuration, but now
passes a saved custom CA to `trust_cert_ca`. Configuration tests cover this;
real SQL Server certificate negotiation remains unverified. On ClickHouse, MongoDB, and Redis the rustls backend offers no CA-only
mode, so Verify Ca verifies the hostname as well; that is stricter than
requested, never weaker, and is documented in each driver.

### 6. No connect timeout on the SSH path — fixed

**Closed on 2026-08-19.** The SSH handshake is bounded at ten seconds and
authentication at twenty, each failing with an error that names the host and
port. MongoDB and Redis are bounded at five seconds. The SSH
bound has a sandbox regression test that connects to a listener which completes
the TCP handshake and then never sends a banner; a refused port returns
instantly and proves nothing.

### 7. Two rustls providers left the default ambiguous — fixed

**Closed on 2026-08-19.** The static drivers pull in both `ring` (MySQL, SQL
Server, MongoDB) and `aws-lc-rs` (ClickHouse), so rustls could not choose a
process-wide crypto provider. Any library that built a `ClientConfig` without
naming one panicked at connect time: MySQL `Verify Ca` panicked in the real
application, because the GUI links every driver. The condition predates the
ClickHouse work and had never been visible, since no test binary linked both
families until the driver TLS tier did.

Every composition root now calls `install_crypto_provider` before connecting:
the GUI, the agent daemon, and each test binary that links more than one driver.
A driver that names its own provider, as ClickHouse now does, is unaffected
either way.

### 8. No local Unix socket connections — fixed

**Closed on 2026-08-20 for PostgreSQL.** Saved records carry an optional socket
directory without a schema-version bump. The GTK form exposes Network and Unix
socket endpoints only for capable drivers, defaults to `/run/postgresql`, and
keeps the port as the `.s.PGSQL.<port>` selector. Transport validation rejects
relative paths, non-socket targets, TLS, SSH, and unsupported drivers. GUI and
agentd both assemble the same `ConnectOptions`; a disposable real PostgreSQL
socket fixture covers query, write, cancellation, close, and reconnect.

### 9. The agent daemon and the GUI recover differently

The GUI runs a monitor that pings every 30 seconds and reconnects with backoff
from 5 to 60 seconds. The agent daemon's session cache validates with a ping on
use and reconnects lazily, with no monitor and no backoff. A tool call that
arrives during an outage retries as fast as the caller retries, bounded only by
the MCP rate limiter.

### 10. An unknown SSH host key is trusted without asking in the GUI

Fixed for the agent daemon; not fixed in the GUI. Recorded as a deliberate, documented posture rather than an
oversight, because closing it needs a user-facing decision.

A **changed** host key is refused: the connection fails with the recorded
line number and both fingerprints, and nothing is written. That is the
case that matters most, and it is covered by tests.

`tablepro-agentd` refuses an **unknown** host key: an unattended agent
connection fails, naming the fingerprint, until the key is in
`known_hosts` from a GUI connection or from `ssh`. Nothing is written.

In the GUI, an **unknown** host key is written to `known_hosts` and the connection
proceeds. There is no confirmation step, so the first connection to a
host trusts whatever answers. That is the same exposure `ssh
-o StrictHostKeyChecking=accept-new` accepts, and it is weaker than
OpenSSH's interactive default, which asks.

Consequences worth stating plainly:

- A machine-in-the-middle on the very first connection to a host is
  accepted and then pinned, so every later connection trusts the wrong
  key and the mismatch is never reported.
- The user is never told a trust decision was made on their behalf.

What would close it: surface the fingerprint before the first connection
completes and require an explicit accept, with Cancel as the default.
That needs a path from `tablepro-ssh`, which has no GTK dependency, up
to the window that can ask - the same shape as the existing approval
sink - so it is a product decision rather than a local fix. Until then,
verify a new host's fingerprint out of band if the network between you
and it is not trusted.

## Potential problems

Not confirmed. Listed so they are not rediscovered as surprises.

- **Connection pool identity.** PostgreSQL opens a four-connection pool plus a
  one-connection cancellation pool. Session state set on one pooled connection
  (`SET`, temporary tables, advisory locks, `search_path`) is not guaranteed to
  be visible to the next query. Anything that assumes session continuity across
  two calls may be relying on luck.
- **Tunnel lifetime versus pool lifetime.** The tunnel is held beside the
  connection and dropped with it. If a pool reconnects internally after the
  tunnel is gone, the failure mode has not been characterised.
- **IPv6 and bracketed literals.** Host strings are formatted into URLs by the
  ClickHouse, Redis, and MongoDB drivers without bracketing. An IPv6 literal
  will almost certainly produce a malformed URL.
- **Hostname handling in the SSH chain.** Known-host learning is keyed on host
  and port. Whether a chain that reaches the same host through different jumps
  is treated consistently has not been examined.
- **Credential exposure in URLs.** Redis, MongoDB, and ClickHouse place the
  password in a URL string. Those strings are not logged today, but a future
  error path that includes the URL would leak the secret.
- **Kerberos and TLS interaction on SQL Server.** Integrated authentication runs
  on a blocking task with its own timeout. Its behaviour under a verifying TLS
  mode is untested.

## Untested areas

Ordered by how much risk the gap carries.

| Area | Historical coverage at the original audit |
|---|---|
| TLS on SQL Server | none — the container tests connect in plaintext |
| Redis, MongoDB, DuckDB | no integration test file at all |
| SSH jump chains of more than one hop | none — the fixture has a single bastion |
| SSH password and passphrase authentication | none — every test uses an unencrypted private key |
| Accepting an unknown SSH host key | the learning and refusal paths are unit-tested; there is no confirmation step to test |
| Unreachable-but-silent hosts | none — tests use refused ports, which return immediately |
| Custom certificate authority from a saved connection | assembly and driver fixture coverage; installed GTK selection remains untested |
| Client certificates and pinned fingerprints | not implemented |
| Reconnect on any driver but PostgreSQL | none |
| Cancellation on Redis, MongoDB, DuckDB | none; PostgreSQL, MySQL, ClickHouse and SQLite are verified against a real engine, and SQL Server is verified to retire its connection instead |
| Concurrent connections to the same host over one tunnel | none |
| IPv6 literals on any driver | none |

## Recommended order

Fixing the silent failures first, then the missing capability, then the coverage
that would have caught both.

1. ~~**Root certificate on saved connections.**~~ Done on 2026-08-19.
2. ~~**MongoDB TLS.**~~ Done on 2026-08-19.
3. ~~**Redis TLS.**~~ Done on 2026-08-19.
4. **Connect timeouts.** The SSH handshake, MongoDB, and Redis are bounded;
   add a fixture case that black-holes packets
   rather than refusing them.
5. **Remove or implement the dead TLS fields.** `client_cert`, `client_key`, and
   `pinned_fingerprint` should either work or not exist.
6. ~~**Local Unix socket connections.**~~ Done for PostgreSQL on 2026-08-20.
7. **A TLS fixture per network driver.** The PostgreSQL fixture is the model.
   Until MySQL, SQL Server, and ClickHouse have one, their TLS behaviour is
   asserted only by reading the code — which is how items 1, 2, and 5 survived.

## System OpenSSH client

A saved SSH tunnel can set `"client": "open_ssh"` (the connect dialog's "Use
system OpenSSH" switch). The app then runs the user's `ssh` as a ControlMaster
in a private runtime directory and forwards the database port through it, so
`~/.ssh/config`, `ProxyJump`, ssh-agent and host certificates apply.

- Host keys: `StrictHostKeyChecking=ask` is forced on the command line, which
  takes precedence over `~/.ssh/config`. The GUI asks before trusting a new key;
  `tablepro-agentd` declines every prompt, so an unknown host fails.
- Secrets: the saved password answers only a prompt naming the saved user and
  host, and the saved passphrase only a prompt naming the saved key path. Any
  other prompt goes to the user, or is declined by agentd.
- Jump hosts come from `~/.ssh/config`. A saved `ssh.jump` chain is refused in
  this mode; use the built-in client for per-hop saved credentials.
- The `tablepro-askpass` helper must be installed beside the app or on `PATH`.
  The Flatpak build cannot run the host `ssh`, so the option fails there with a
  clear message.

## ssh-agent

A saved SSH hop with `"agent": true` authenticates through the agent at
`$SSH_AUTH_SOCK`, trying each key the agent holds. It works on every hop of a
built-in jump chain, because it needs no per-hop secret, and maps to agent
authentication when the hop uses the system OpenSSH client. The hop still records
a private-key path, so an older build that ignores the flag falls back to that key
file instead of failing to read the connections file.

