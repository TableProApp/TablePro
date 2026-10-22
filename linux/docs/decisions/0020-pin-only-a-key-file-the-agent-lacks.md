# 0020: Pin only a key file the agent does not hold

- **Status**: Accepted
- **Date**: 2026-10-21

## Context

[0019](0019-ssh-key-file-identities-only.md) gives the master `-o IdentitiesOnly=yes` whenever the connection names a key file. Two setups that connected before stop connecting under it:

- The agent holds a certificate for the chosen key and no `-cert.pub` sits beside the file, as with certificates an SSO tool loads into the agent. `IdentitiesOnly` keeps the agent's plain key and drops the certificate, so a server that takes only certificates refuses the login.
- The chosen file is an encrypted PEM key with no `.pub`, and the agent holds it. ssh cannot read the file's public half to match it to the agent's copy, so it asks for the passphrase instead of letting the agent sign.

When the agent holds the chosen key, ssh already offers it first, with the agent's certificates for it after. `MaxAuthTries` cannot run out before it.

## Decision

The master gets `-o IdentitiesOnly=yes` only when `ssh-keygen -l` reads the key file's fingerprint and the agent `ssh -G` names does not list it in `ssh-add -l`. This supersedes 0019.

## Consequences

- An agent full of other keys still cannot use up `MaxAuthTries` before a key only in the file.
- A key the agent holds, a certificate only the agent holds and an encrypted PEM key the agent holds sign through the agent with no prompt.
- Each connection with a key file runs `ssh-keygen -l` and `ssh-add -l` first, each bounded at 5 seconds. A file whose fingerprint cannot be read is not pinned. An agent that cannot be asked counts as not holding the key.
- A jump host still gets none of the master's `-o` options, as 0019 says.
