# SSH transport

> [NEEDS REVIEW] Draft written on 2026-10-11 from `tablepro-ssh`, `tablepro-transport` and ARCHITECTURE. A maintainer review is pending.

**Spec tier:** buildable
**Serves:** `Local DBA`
**Status:** in-development
**Success metric:** A tunnel opens only after the host key is trusted or explicitly learned; TLS still verifies the saved database hostname, not loopback.

## Purpose

Turn a saved SSH hop into a local forward, and decide whether an unknown or changed host key is trusted. Preserve the service hostname used for certificate verification so a tunnel is not a TLS downgrade.

## Scope

- Built-in `russh` tunnels and the optional system OpenSSH backend (`crates/ssh`).
- Host-key outcomes: trusted, learned, changed, unknown, known_hosts I/O failure (`crates/ssh/src/known_hosts.rs`).
- `UnknownHostKey::{Learn, Refuse}` (`crates/ssh/src/lib.rs`).
- Transport assembly: saved connection to driver options, SSH chain, tunnel, TLS service identity (`crates/transport`, [ARCHITECTURE](../../ARCHITECTURE.md#transport-and-service-identity)).

## Out of scope

- What SQL may run after the driver connects ([governed-sql](../governed-sql/spec.md)).
- Storing hop passwords and key passphrases (Secret Service / ADR 0004). Jump-chain editing that is not yet integrated stays on the ledger.
- Flatpak OpenSSH refuse (I2 / packaging). That is a packaging decision, not this capability's host-key rule.

## Core concepts

- **Dial target.** Where bytes are sent (forwarded socket or `127.0.0.1:ephemeral`).
- **TLS service identity.** The hostname the certificate must match (the saved database host).
- **BookiE known_hosts.** A file this crate reads and writes. System `~/.ssh/known_hosts` is not a substitute for the built-in backend.

## Data contracts

`UnknownHostKey` (`crates/ssh/src/lib.rs`):

```text
Learn
Refuse
```

`HostKeyOutcome` (`crates/ssh/src/known_hosts.rs`):

```text
Trusted
LearnedNew { fingerprint }
Changed { fingerprint, line }
Unknown { fingerprint }
KnownHostsIo(String)
```

`SshError` host-key variants (`crates/ssh/src/lib.rs`):

| Variant | When |
|---|---|
| `HostKeyMismatch { host, port, new_fingerprint, line, known_hosts }` | Stored fingerprint differs. |
| `UnknownHostKey { host, port, fingerprint, known_hosts }` | Key is absent and this connection does not add keys. |
| `KnownHosts(String)` | The known_hosts file could not be read or updated. |

OpenSSH backend forces `StrictHostKeyChecking=ask` (`crates/ssh/src/openssh/argv.rs`). Prompt kinds include `HostKeyConfirmation { host, algorithm, fingerprint }`.

## Interface contracts

### `verify_or_learn`

`crates/ssh/src/known_hosts.rs` line 19.

- Known matching key → `Trusted`.
- Unknown key and `UnknownHostKey::Refuse` → `Unknown`.
- Unknown key and `Learn` → write the key, then `LearnedNew` or `KnownHostsIo`.
- Changed key → `Changed` (never overwritten in this function).

### `verify_or_prompt`

`crates/ssh/src/known_hosts.rs` line 37.

- Known matching key → `Trusted`.
- Otherwise prompt. `PromptAnswer::Accept` records the key. Any other answer → `Unknown`.

### Transport identity

`ConnectOptions` keeps dial target and TLS identity as separate fields. SSH + Verify CA/Full uses a Unix socket in a private directory when the driver reports a forwarded socket name; otherwise TCP. TLS verifies the saved database hostname, not `127.0.0.1`. Unsupported combinations fail closed. [ARCHITECTURE](../../ARCHITECTURE.md#transport-and-service-identity).

| Endpoint | Status | errorCode | Message / condition |
|----------|--------|-----------|---------------------|
| built-in verify | n/a | `HostKeyMismatch` | Fingerprint differs; line cited in `known_hosts`. |
| built-in verify | n/a | `UnknownHostKey` | Absent key and `Refuse`; running system `ssh` will not write this file. |
| built-in verify | n/a | `KnownHosts` | I/O or parse failure on the BookiE known_hosts file. |
| OpenSSH backend | n/a | `HostKeyUnknown` / `HostKeyChanged` / `HostKeyRevoked` | Classified from OpenSSH stderr (`crates/ssh/src/openssh/error.rs`). |

## Algorithms & rules

1. Resolve the saved hop (host, port, username, auth). Secrets remain wrapped until the driver/SSH boundary.
2. Read BookiE `known_hosts` (default from `default_known_hosts_path`).
3. Compare the presented key.
4. Match → continue. Change → fail with `HostKeyMismatch`. Missing + `Refuse` → fail with `UnknownHostKey`. Missing + `Learn` or an accepted prompt → append and continue.
5. Open the forward. Timeouts: connect 10s, auth 20s, keepalive 15s (`crates/ssh/src/lib.rs`).
6. Hand transport a local dial target plus the original service hostname for TLS.

OpenSSH: pass `StrictHostKeyChecking=ask` and classify host-key stderr. Do not set `accept-new` or `no`.

## State machine

| From | To | Trigger | Guard |
|------|----|---------|-------|
| unseen | trusted | key matches known_hosts | check succeeds |
| unseen | learned | unknown key, `Learn` or prompt Accept | write succeeds |
| unseen | refused | unknown key, `Refuse` or prompt decline | no write |
| unseen | mismatch | key changed | never overwrite |
| unseen | io-failed | known_hosts I/O error | fail closed |
| learned / trusted | forwarded | auth and channel succeed | connect/auth timeouts |
| forwarded | connected | driver dials the forward | TLS identity is the saved host |

## Requirements

- The system MUST compare the presented host key to BookiE `known_hosts` before forwarding.
- A changed key MUST fail closed. The stored line MUST NOT be overwritten automatically.
- `UnknownHostKey::Refuse` MUST NOT add a key.
- System `ssh` writing `~/.ssh/known_hosts` MUST NOT be treated as trust for the built-in backend.
- TLS through an SSH tunnel MUST verify the saved database hostname when verification is requested.
- The OpenSSH backend MUST use `StrictHostKeyChecking=ask`.

## Invariants

- A changed host key MUST NOT be learned over the old line.
- A Refuse connection MUST NOT create a new known_hosts entry.
- TLS identity MUST NOT become `127.0.0.1` merely because the dial target is a local forward.

## Config & flags

| Flag | Effect |
|------|--------|
| `UnknownHostKey::Learn` | First-seen keys may be written after the backend's learn/prompt path. |
| `UnknownHostKey::Refuse` | First-seen keys fail. |
| OpenSSH backend | Optional; still asks on unknown keys. Flatpak may refuse this backend entirely (packaging). |

## Edge cases

- Keyboard-interactive-only servers are unsupported (`SshError::KeyboardInteractiveUnsupported`).
- An empty jump chain is `SshError::EmptyChain`.
- OpenSSH 9.6 and 10 host-key prompts parse to the same `HostKeyConfirmation` (`crates/ssh/src/openssh/prompt.rs`).
- Jump-chain editing in the UI may still be disabled while per-hop storage already exists. That gap is ledger work, not a second trust rule.

## Trust boundaries

- Host keys are a trust decision. A mismatch is treated as a possible on-path attack.
- Auth secrets (password, key passphrase, agent) stay in `secrecy` types until the SSH crate boundary.
- The known_hosts file is local trusted state. Corruption or I/O errors fail closed.

## Cross-capability interactions

### governed-sql

Transport returns a driver connection. Policy starts after that handle is wrapped.

## Acceptance criteria

- **Known key.** GIVEN a host key that matches BookiE known_hosts WHEN the tunnel opens THEN the outcome is `Trusted` and forwarding proceeds.
- **Refuse unknown.** GIVEN `UnknownHostKey::Refuse` AND no matching line WHEN verify runs THEN the error is `SshError::UnknownHostKey` AND the file is unchanged.
- **Changed key.** GIVEN a stored key that does not match WHEN verify runs THEN the error is `HostKeyMismatch` AND the old line is still present.
- **Learn new.** GIVEN `UnknownHostKey::Learn` AND no matching line WHEN verify_or_learn succeeds THEN the outcome is `LearnedNew` AND a new line exists.
- **Prompt decline.** GIVEN verify_or_prompt AND the prompter does not accept WHEN the key is unknown THEN the outcome is `Unknown` AND no line is added.
- **TLS identity.** GIVEN SSH plus certificate verification WHEN transport assembles options THEN the TLS hostname is the saved database host, not the local forward.
- **OpenSSH ask.** GIVEN the OpenSSH backend WHEN argv is built THEN it contains `StrictHostKeyChecking=ask`.

## Open questions

None known.
