# UI-1b: SSH jump-chain editor and per-hop credentials

**Status:** Implementation in progress. PR #490 adds stable hop identities and per-hop Secret Service storage. PR #492 implements per-hop built-in transport resolution and cache identity. This dependent PR adds encrypted bundle v2 and retains version 1 import. GTK editing, full secret migration/rollback coverage, and installed acceptance remain incomplete. Keep jump-chain editing refused.

## Current behavior

Saved SSH routes are nested `SavedSshConfig` values with an eight-hop limit.
The connection editor refuses any saved chain. Secret Service entries are
currently keyed by connection ID and kind, so one SSH password and one SSH key
passphrase are available per connection. The transport refuses password auth
after hop 0; private-key hops all read the same passphrase entry. Reusing one
secret across distinct hops is not a per-hop credential model. The system
OpenSSH backend separately refuses a saved chain and expects `ProxyJump` in the
user's SSH config.

## Proposed behavior

1. Add an ordered hop editor with add, remove, and move controls. It edits each
   hop's host, port, user, auth mode, key path, agent selection, and passphrase
   setting. Enforce the existing eight-hop limit before save. Keep database
   endpoint settings separate from jump-host settings.
2. Give each hop a stable, non-secret `hop_id`. Reordering a route must not
   move credentials to another host. Store each secret in Secret Service with
   connection ID, hop ID, secret kind, and a credential revision. Persist only
   those opaque references and auth metadata in `connections.json`.
3. Treat existing root-hop secrets as legacy input. When editing a legacy
   connection, stage new per-hop Secret Service entries, write the migrated
   connection record, then retire old entries. If staging or the connection
   write fails, preserve the old record and credentials. Cleanup failure may
   leave an orphaned old entry, but must never leave the saved connection
   pointing at a missing credential.
4. Never prefill secret values into widgets. Show that a secret is saved,
   missing, or unreadable, with explicit Keep, Replace, and Remove actions.
   Secret Service failure blocks a save that would require a credential.
5. Resolve each hop's password or key passphrase independently in the built-in
   transport and include each hop's own secret in the session-material digest.
   Until that backend change lands, disable nested password auth and refuse to
   save unsupported combinations. Do not silently reuse hop 0's credential.
6. Keep saved jump chains unavailable to the system OpenSSH backend until its
   `ProxyJump` and per-hop askpass behavior is separately designed and tested.
7. Encrypted bundle version 2 carries each versioned hop's secret bound to
   its hop ID and credential revision; version 1 import remains supported.
   Plaintext exports stay free of credentials and malformed per-hop secret
   references are refused. GTK editor integration and failure-injection
   coverage remain before the edit refusal can be removed.

## Required checks before removing the refusal

- Legacy root-hop password/passphrase migration preserves connect behavior and
  removes the old Secret Service entry only after the new record is durable.
- Different secrets for two password-auth hops and two encrypted keys reach
  only their configured hop; a failure at one hop does not try another hop's
  secret.
- Reordering, inserting, or removing a hop keeps credentials attached to the
  intended `hop_id`; session material changes when any hop secret changes.
- Keyring and connection-file failure injection proves compensation and
  recovery. Secret values never appear in JSON, logs, audit records, or error
  messages.
- Bundle v1 import remains compatible; encrypted v2 round trips per-hop
  secrets; plaintext export refuses to include any secret.
- GTK tests edit a saved chain, preserve unrelated endpoint fields, and verify
  the stored route by connecting through the built-in client. Installed
  acceptance exercises the same trust flow.

The implementation can be split into storage and bundle support, transport
resolution and cache identity, then the GTK editor. Keep the current refusal
until all three are integrated; a UI-only editor would otherwise save routes
that cannot be safely resolved.
