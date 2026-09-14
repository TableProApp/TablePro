# 0013: SSH through the system OpenSSH client

- **Status**: Accepted
- **Date**: 2026-09-15

## Context

People reach their databases through bastions configured in `~/.ssh/config`: `ProxyJump`, `Match`, `Include`, host certificates, FIDO keys, agents and custom `known_hosts` files. The previous transport re-implemented SSH on russh. It ignored that configuration, kept its own host-key logic, opened a TCP listener on localhost for every tunnel, and needed security upgrades for seven russh advisories in one year.

## Decision

`tablepro-ssh` runs the system `ssh` binary as a ControlMaster (`ssh -M -N -T`) per connection and asks it for Unix-socket forwards with `ssh -O forward`.

## Rationale

- The user's ssh_config applies unchanged. Only the options that define the master lifecycle, socket permissions and the prompt path are forced on the command line (ControlMaster, ControlPersist, ForkAfterAuthentication, StreamLocalBindMask, BatchMode, VisualHostKey, Tunnel and the forwarding switches).
- Prompts reach the app through `SSH_ASKPASS` with `SSH_ASKPASS_REQUIRE=force` and the `tablepro-askpass` helper, so host-key confirmation, passwords, passphrases and keyboard-interactive answers use the app's own dialogs.
- Forwards are Unix sockets with mode 0600 inside a 0700 per-process directory, so no TCP port is opened on the machine.
- OpenSSH is the most used SSH implementation on Linux and receives security fixes through the distribution.

## Consequences

- openssh-client 8.4 or later is a runtime dependency; the GNOME 50 Flatpak runtime ships it.
- The helper is installed to libexecdir next to the app.
- Failures are classified from OpenSSH's stderr, pinned by captured fixtures. A change to those strings in a later OpenSSH release shows up as a failing fixture test.
- russh, ssh-key and internal-russh-forked-ssh-key leave the dependency graph when the app moves to this transport.

## Alternatives considered

- **russh**: a second SSH implementation to keep secure, and none of the user's ssh_config.
- **openssh crate**: also drives the system client, but runs it in batch mode and has no way to answer prompts from the app.
- **ssh2 (libssh2)** and **libssh**: C libraries that do not read ssh_config and need their own host-key handling.
