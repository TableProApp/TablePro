# 0013: SSH through the system OpenSSH client

- **Status**: Accepted
- **Date**: 2026-09-15

## Context

People reach their databases through bastions configured in `~/.ssh/config`: `ProxyJump`, `Match`, `Include`, host certificates, FIDO keys, agents and custom `known_hosts` files. The previous transport re-implemented SSH on russh. It ignored that configuration, kept its own host-key logic, opened a TCP listener on localhost for every tunnel, and needed security upgrades for seven russh advisories in one year.

## Decision

`tablepro-ssh` runs the system `ssh` binary as a ControlMaster (`ssh -M -N -T`) per connection and asks it for Unix-socket forwards with `ssh -O forward`.

## Rationale

- The user's ssh_config applies, except where the command line overrides it. Forced: the master lifecycle (ControlMaster, ControlPath, ControlPersist, ForkAfterAuthentication), socket permissions (StreamLocalBindMask), the prompt path (BatchMode, VisualHostKey), Tunnel and the forwarding switches (ClearAllForwardings, ExitOnForwardFailure, ForwardAgent, ForwardX11), PermitLocalCommand, RequestTTY, LogLevel, and the app's ConnectTimeout, ServerAliveInterval and ServerAliveCountMax. A StrictHostKeyChecking of accept-new or no is raised to ask, and password or keyboard-interactive auth sets PreferredAuthentications.
- Prompts reach the app through `SSH_ASKPASS` with `SSH_ASKPASS_REQUIRE=force` and the `tablepro-askpass` helper, so host-key confirmation, passwords, passphrases and keyboard-interactive answers use the app's own dialogs.
- Forwards are Unix sockets with mode 0600 inside a 0700 per-process directory, so no TCP port is opened on the machine.
- OpenSSH is the most used SSH implementation on Linux and receives security fixes through the distribution.

## Consequences

- openssh-client 8.7 or later is a runtime dependency: every master gets `-o ForkAfterAuthentication=no`, which OpenSSH 8.7 added, and an older ssh refuses the unknown option. The GNOME 50 Flatpak runtime ships a newer one.
- The helper is installed to libexecdir next to the app.
- A jump host runs in a second ssh that gets only `-l`, `-p`, `-J` and `-F` from the master (ssh.c turns ProxyJump into a ProxyCommand), never its `-o` options. When a hop's configuration sets `StrictHostKeyChecking accept-new` or `no`, the master gets a generated `-F` file that sets `ask` for that host, includes `~/.ssh/config` and then copies in `/etc/ssh/ssh_config`, so the hop asks through the same dialog. The system file is copied because OpenSSH holds an `Include` to an owner check it skips for that file, and in a Flatpak sandbox root's files belong to nobody. Copied in, a relative `Include` inside it resolves under `~/.ssh` rather than `/etc/ssh`. The `~` of `Include ~/.ssh/config` follows `HOME`, where ssh's own read of the user file follows the password database. A hop whose `ssh -G` lookup fails or takes over 5 seconds is not pinned, and neither is any hop before it. Every other connection reads the configuration as before.
- A StrictHostKeyChecking of yes is kept, for the destination and for each jump host as its own `ssh -G` lookup gives it. A key that changed under it is not offered for replacement, because ssh would then refuse the new key without asking; the host key review says to fix known_hosts outside the app, then retry.
- Failures are classified from OpenSSH's stderr, pinned by captured fixtures. A change to those strings in a later OpenSSH release shows up as a failing fixture test.
- russh, ssh-key and internal-russh-forked-ssh-key leave the dependency graph when the app moves to this transport.

## Alternatives considered

- **russh**: a second SSH implementation to keep secure, and none of the user's ssh_config.
- **openssh crate**: also drives the system client, but runs it in batch mode and has no way to answer prompts from the app.
- **ssh2 (libssh2)** and **libssh**: C libraries that do not read ssh_config and need their own host-key handling.
