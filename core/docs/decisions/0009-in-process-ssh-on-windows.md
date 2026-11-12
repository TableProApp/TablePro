# 0009: SSH on Windows runs in process on russh

- **Status**: Accepted
- **Date**: 2026-11-03

## Context

The core's SSH transport runs the system `ssh` as a ControlMaster and asks it for Unix-socket forwards, with prompts through an askpass helper over a Unix socket ([Linux ADR 0013](../../../linux/docs/decisions/0013-openssh-client-transport.md)). It builds on Unix alone, and [0001](0001-shared-core.md) left it off Windows. The Windows app's `SshTunnels` fails every SSH connection with `ssh.open_ssh_client_missing`.

Windows ships OpenSSH as a Feature on Demand from Windows 10 1809, which Microsoft lists as not installed by default on Windows 10 ([OpenSSH for Windows overview](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-overview)). Win32-OpenSSH does not implement the client's ControlMaster ([Project Scope](https://github.com/PowerShell/Win32-OpenSSH/wiki/Project-Scope)), so there is no master to add a forward to, and its askpass needs `SSH_ASKPASS_REQUIRE` from V8.6.0.0p1 on, newer than some inbox clients.

sqlx (MySQL), the mongodb crate and scylla dial an address themselves, and on Windows neither sqlx 0.9 nor mongodb 3.9 dials a Unix socket.

## Decision

`tablepro-ssh` gains a transport that runs SSH in process on russh, behind its `in-process` feature and built on every target; the Windows app uses it, and Linux keeps the OpenSSH transport.

## Rationale

- russh is the maintained async SSH client in Rust, on tokio as the core is, with aws-lc-rs as its provider ([Linux ADR 0009](../../../linux/docs/decisions/0009-crypto-provider-and-sources.md)).
- Each stream is a `direct-tcpip` channel of one authenticated session: one login per connection, as many forwards and reroutes as the drivers ask for, and no port open on the machine.
- Nothing outside the app runs, so it works whether or not the OpenSSH client is installed, on x64 and Arm64 alike.
- Every question goes to the app's `CredentialPrompter` with the `PromptPurpose` the askpass bridge gives, so the session's host key review and retry work as they do on Linux.
- The iOS app, which cannot start a process, can use the same transport.

## Consequences

- What it does in place of OpenSSH:
  - Host keys: `~/.ssh/known_hosts`, `known_hosts2` and the system file (`%ProgramData%\ssh\ssh_known_hosts` on Windows) are read with hashed names, patterns, `@revoked` and `@cert-authority`, and the key types they hold for a host are asked for first, as OpenSSH orders them. A key the user trusts is added to `~/.ssh/known_hosts`, which Win32-OpenSSH reads too. A changed key fails with `ssh.host_key_changed` naming the file and line, and `InProcessSsh::forget_changed_host_key` removes it as `ssh-keygen -R` would.
  - Authentication tries the methods in the order the OpenSSH transport's `PreferredAuthentications` gives. A chosen key file is the only key offered, and the agent signs it when it holds it ([Linux ADR 0020](../../../linux/docs/decisions/0020-pin-only-a-key-file-the-agent-lacks.md)). A jump host tries the agent, the connection's key file and the default identities, then asks, and is never given the destination's password.
  - The agent is `SSH_AUTH_SOCK`, else on Windows `\\.\pipe\openssh-ssh-agent`, then Pageant. Each hop opens its own agent connection and binds it to its session, as OpenSSH does for keys added with destination constraints. On Windows a pipe is used only when this user, LocalSystem or the Administrators own it, since any user can create it while the agent service is stopped, its default.
  - Keepalives follow `LivenessPolicy`, as `ServerAliveInterval` and `ServerAliveCountMax` do for OpenSSH.
  - It reads no `ssh_config`: the connection's fields are its whole configuration. A security key file cannot sign in process; an agent that holds one can. GSSAPI is not offered.
  - New failures: `ssh.identity_file_unreadable`, `ssh.identity_file_invalid`, `ssh.agent_unavailable` and `ssh.known_hosts_unwritable`.
- A forward's route is `TransportRoute::InProcess`. MySQL and MongoDB relay it through `tablepro_net::PrivateListener`: a Unix socket in a directory only the user opens, and on Windows a loopback port that serves only connections this process opened, by the owning process `GetExtendedTcpTable` names. Cassandra's loopback relay checks the owner the same way, so it serves Windows too ([Linux ADR 0023](../../../linux/docs/decisions/0023-loopback-relay-for-cql.md)).
- sqlx checks a certificate against the host it dials, so MySQL with Verify full through SSH on Windows is refused with `config.server_name_override_unsupported`, as on any route whose host is not the server's name.
- rsa is back in the graph, under russh and ssh-key, for RSA identity files and host keys. The reasoning of 0009's Stage A holds: one signature per login, and RUSTSEC-2023-0071 is about private-key timing a server cannot observe from one login. `deny.toml` allows rsa under those crates only.
- `tablepro-ssh` depends on `tablepro-net` for the first hop's dial, with its keepalive and `TCP_USER_TIMEOUT`.
- 0013's "russh leaves the dependency graph" holds for the Linux app only: the feature is off in its build, so its binary and license notices carry no russh.

## Alternatives considered

- **Win32-OpenSSH.** With no ControlMaster, each forward is its own `ssh.exe` and login, or a `-L` or `-D` port that `ssh.exe` opens on loopback for every local user; the client may be missing and its askpass varies by version.
- **In process on every platform.** Linux would lose the user's `ssh_config` (ProxyJump, Match, Include, certificates, FIDO keys), which is why 0013 moved to OpenSSH.
- **libssh2 through the ssh2 crate**, as the macOS app does: a blocking C library with its own crypto (WinCNG or OpenSSL) against 0009, and a thread and socket pair per jump hop.
