# UI-1b: SSH jump-chain editor and per-hop credentials

**Status:** Backend support is implemented. PRs [#490](https://github.com/cozyGarage/BookiE/pull/490), [#492](https://github.com/cozyGarage/BookiE/pull/492), [#494](https://github.com/cozyGarage/BookiE/pull/494) and [#528](https://github.com/cozyGarage/BookiE/pull/528) add stable hop identities, per-hop Secret Service credentials, built-in transport resolution, encrypted bundle v2 and passphrase coverage. The connection form still refuses to edit saved jump chains. Keep that refusal until the editor and installed acceptance are complete ([#548](https://github.com/cozyGarage/BookiE/issues/548)).

## Current behavior

Saved SSH routes are nested `SavedSshConfig` values with stable hop identities
and an eight-hop limit. Passwords and key passphrases are stored per hop in
Secret Service and resolved independently by the built-in transport. Encrypted
connection bundles carry those credentials, and older bundle imports remain
supported. The connection form still refuses to edit a saved chain. The system
OpenSSH backend also refuses saved chains and expects `ProxyJump` in the user's
SSH config.

## Remaining behavior

1. Add ordered add, remove, and move controls for up to eight hops. Edit each
   hop's host, port, user, auth mode, key path and agent selection without
   changing the database endpoint.
2. Never prefill secret values. Show whether each per-hop secret is saved,
   missing or unreadable, with explicit Keep, Replace and Remove actions.
   Secret Service failure blocks a save that needs a credential.
3. Keep saved jump chains unavailable to system OpenSSH; it uses the user's
   `ProxyJump` configuration and has no editor-managed per-hop credential path.

## Required checks before removing the refusal

- The editor displays saved, missing and unreadable credential states without
  exposing secret values, and Keep, Replace and Remove behave as labelled.
- Reordering, inserting or removing a hop keeps its credentials attached to
  the intended hop; saving preserves unrelated endpoint settings.
- A GTK regression edits a saved route and verifies the resulting connection
  through the built-in client, including the trust flow and refusal paths.
- Installed acceptance confirms the edited route works with the packaged app.

The storage, bundle and built-in transport foundations are merged. The remaining
work is the GTK editor and its end-to-end acceptance. Keep the refusal until
that path is complete; an editor must not save a route it cannot represent or
connect safely.
