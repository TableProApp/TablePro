# 0019: A chosen SSH key file limits the keys ssh offers

- **Status**: Superseded by 0020
- **Date**: 2026-10-20

## Context

[0013](0013-openssh-client-transport.md) lists the options the master forces over the user's ssh_config. A key file chosen in the app reached ssh as `-i` alone. OpenSSH offers the agent's other keys before a key that is only in a file, and the server ends the login with "Too many authentication failures" once `MaxAuthTries` keys were refused, 6 by default. With an agent that holds more keys than that, the chosen key is never offered (#3662).

## Decision

When the connection names a key file, the master also gets `-o IdentitiesOnly=yes`. This adds to 0013's forced options.

## Consequences

- ssh offers the chosen key and the keys the user's ssh_config names for the host, and no other agent key. The agent still signs with the chosen key when it holds it, so a key with a passphrase that is loaded in the agent needs no prompt.
- Agent authentication, and a private key with no file chosen, read the user's ssh_config as before.
- A jump host gets none of the master's `-o` options (0013, Consequences), so a hop still offers every agent key. `IdentitiesOnly yes` for the hop in ssh_config limits it.
