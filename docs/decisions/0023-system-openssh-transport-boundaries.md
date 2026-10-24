# 0023: The system OpenSSH transport answers only exact prompts and owns no global state

- **Status**: Accepted
- **Date**: 2026-10-24
- **Origin**: Extracted from the 2026-09-25 system OpenSSH port recorded in the [upstream sync history](../archive/upstream-sync-history-2026-10-22.md). The code was checked against it on the extraction date. [ADR 0008](0008-connection-and-session-ownership.md) sets the trust rules (ask before accepting a host key, no silent backend switch); this record covers how the transport is built.

## Context

BookiE can reach a database through a saved `ssh` tunnel handled by the system OpenSSH client. The upstream implementation this port was based on answered the first `'s password:` prompt with the stored password whatever account the prompt named, so a jump host could receive the destination's password. It also relied on process-global task trackers and on error and transport types from the core crate.

## Decision

1. **Askpass answers only an exact match.** A stored password answers only a prompt naming exactly the configured `user@host`. A stored passphrase answers only a prompt naming exactly the configured key path. Keyboard-interactive text is classified before the password suffix, so a server-supplied prompt cannot pose as a password prompt.
2. **Everything else goes to a `Prompter`.** Every other prompt, and every host-key confirmation, is passed to a `Prompter` trait object. `UnattendedPrompter` (used by `bookie-agentd`) declines all of it. A confirmation needs an explicit accept, a secret prompt needs a secret, and a mismatched answer cancels.
3. **The askpass bridge is hardened.** It rejects a peer with another uid as an error, bounds each frame to 64 KiB, times out a peer that never sends a prompt, and builds replies in `Zeroizing` buffers.
4. **The client's options cannot be turned off from `~/.ssh/config`.** The transport forces `StrictHostKeyChecking=ask`, `StreamLocalBindUnlink=no`, `SessionType=none` and `GatewayPorts=no`. Host-key checking applies to the destination and to every `ProxyJump` hop, which closed the gap tracked in #970.
5. **No process-global state.** An explicit `OpenSshContext` holds the runtime, program paths and timeouts. There are no global task trackers or runtime cells.
6. **The ssh crate does not depend on `core`.** It returns its own `OpenSshError` and takes an `OpenSshTimeouts` value. A forward returns its local endpoint and the original target, so the caller keeps the service host for TLS verification.

## Rationale

A secret goes only to the host that asked for it by its exact name. Independent state and a crate with no `core` dependency can be tested without a database and cannot leak one connection's tasks into another.

## Consequences

- Adding an auth method means adding an exact-match rule and a test proving the secret does not reach another hop. The Docker-gated `openssh_session` test does this for a jump host.
- A prompt the transport does not recognise needs a user, so an unattended consumer fails closed.
- Code that wants a core type in the ssh crate must map it at the composition root.

## Alternatives considered

- **Answer the first password prompt (the upstream behaviour).** Rejected: a jump host receives the destination password.
- **Learn host keys on first use (`StrictHostKeyChecking=accept-new`).** Rejected. [ADR 0008](0008-connection-and-session-ownership.md) requires an explicit ask for every hop, and an unknown key must write nothing when the user declines ([connections](../connections.md#built-in-ssh-trust)).
- **Keep upstream's global task tracker and runtime cell.** Rejected: hidden shared state across connections and in tests.
- **Reuse core's `SshFailure` and `Transport` trait.** Rejected: it would give the ssh crate a dependency on `core` and reverse the layering in [ADR 0018](0018-headless-app-services-crate.md).
- **Rely on the user's `ssh_config` for host-key policy.** Rejected: a user setting could silently disable the check for the destination.
