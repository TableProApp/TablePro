# 0004: Secret Service through oo7

- **Status**: Accepted
- **Date**: 2026-04-26
- **Clarified**: 2026-10-03 to match the typed-error contract in storage and transport.

## Context

Database, SSH, and MCP credentials must persist without being written to JSON files. The storage mechanism must work across common Linux desktop environments, expose an async Rust API, and fail safely when no keyring service is available.

Available choices include the Secret Service D-Bus API, desktop-specific keyring APIs, encrypted application files, plain files, or prompting on every connection.

## Decision

TablePro stores credentials through the Secret Service D-Bus API using the `oo7` Rust crate.

Items use the schema `com.tablepro.linux.Password` with connection and secret-kind attributes. The storage crate exposes typed functions for database passwords, SSH passwords, SSH key passphrases, and MCP secrets.

An absent keyring item returns `Ok(None)`. Unavailable, locked or cancelled
Secret Service access returns a typed `StorageError`; saved transport assembly
propagates the error and refuses connection assembly. Callers may offer recovery
or an explicit credential prompt, but must not disguise failed access as an
absent item. The application never falls back to a plain credential file.

## Rationale

Secret Service is supported by GNOME Keyring and KWallet compatibility services. It gives the application one desktop-neutral API and lets users inspect or remove credentials with their normal keyring tools.

`oo7` provides an async Rust interface that fits the storage crate. Keeping access behind `tablepro-storage` prevents UI and driver code from creating inconsistent schemas or fallback behavior.

## Consequences

Accepted:

- A desktop keyring service is required for persistent credentials.
- Minimal or headless sessions report keyring access failure; an explicit recovery flow may request credentials again.
- Sandboxed packages must verify Secret Service access through their desktop permissions.
- Existing item attributes and identifiers need migration if the application identity changes.

Gained:

- Credentials stay out of regular application files.
- GNOME and KDE sessions use one storage API.
- Secret values remain wrapped by `secrecy` until the driver boundary.
- Keyring failure has a defined fail-safe path.

## Alternatives considered

**Plain JSON with restrictive file permissions.** Rejected because credentials would remain directly readable by processes running as the user.

**Desktop-specific keyring backends.** Rejected because they would duplicate implementation and produce different behavior across environments.

**Application-managed encrypted files.** Rejected because they require a master-key lifecycle, recovery design, and cryptographic storage format that the system keyring already provides.

**Prompt on every connection.** Rejected as the normal user experience. A prompt
is an explicit recovery choice; keyring failures remain distinguishable from
missing items.
