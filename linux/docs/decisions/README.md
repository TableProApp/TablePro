# Architecture Decision Records

These are short documents recording the **reasoning** behind major technical choices. An ADR records the decision as it stood on its date, and is not kept current. The code, the workflows and the rest of `docs/` describe the system as it is now.

Every load-bearing decision in the Linux subproject has an ADR. If a contributor asks "why did we pick X", the answer should already be in this folder. If it is not, we missed an ADR.

## Format

```markdown
# 000N: Title

- **Status**: Accepted
- **Date**: YYYY-MM-DD

## Context

The forces at play. What is the situation that requires a decision?

## Decision

The choice we made, in one sentence.

## Rationale

Why this choice over the alternatives. Reference the alternatives explicitly.

## Consequences

What we accept by making this choice. Positive, negative, neutral.

## Alternatives considered

Brief note on each alternative and why it lost.
```

Context, Decision and Consequences are always there. Rationale and Alternatives considered are there when other options were weighed. A section an ADR needs beyond these, such as a matrix or a dated note, comes after them.

The Status is `Accepted`, `Superseded by 000M` or `Deprecated`. An accepted ADR that a later one changed in part reads `Accepted; <part> superseded by 000M` (replaced) or `amended by 000M` (extended). The `amended <date>` statuses below predate this rule.

ADRs are short on purpose. If yours is more than a page, you are probably arguing instead of recording.

## Changing a decision

A new ADR supersedes the old one, as in Michael Nygard's [Documenting Architecture Decisions](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions). The new ADR says what it replaces and why. The old ADR's only edit is its Status line, naming the new one, plus the same change to its row in the index. Do not rewrite an old ADR's body to match the current system.

A fact the repository keeps elsewhere, such as a workflow trigger, a branch, a variable's default or a ruleset, is pointed to from an ADR, not copied into it, so the ADR stays true without edits.

## Index

| # | Title | Status | Summary |
|---|---|---|---|
| [0001](0001-no-plugin-system.md) | No plugin system; drivers are statically linked | Accepted | Drivers are crates, registered at compile time. No `.tableplugin`-equivalent on Linux. |
| [0002](0002-rust-gtk4-libadwaita.md) | Rust + GTK4 + libadwaita | Accepted; version floor superseded by 0015, the Relm4 consequence by 0012 | Validated by spike. Only stack with a production virtualized data grid (GtkColumnView). |
| [0003](0003-relm4-architecture.md) | Relm4 for app architecture | Accepted; superseded by 0012 except for the saved-queries and CSV import dialogs | Elm-style components scale to TablePro's view count. |
| [0004](0004-libsecret-secret-storage.md) | Secret storage through oo7 | Accepted; store API and Flatpak path amended 2026-09-15, the rules for edits 2026-10-15 | The Secret Service on the host, and oo7's own keyring file with a key from the Secret portal inside Flatpak; never a plain-text file. |
| [0005](0005-supply-chain-policy.md) | Supply-chain policy | Accepted | Maintained crates first; custom code needs recorded evidence and a removal trigger. |
| [0006](0006-meson-cargo-build.md) | Meson drives Cargo | Accepted; where the version lives amended by 0017 | Meson owns install, data files and the build-time config; Cargo stays the Rust compiler. |
| [0007](0007-gsettings-preferences.md) | Preferences and window geometry in GSettings | Accepted; the schema id and path per profile amended 2026-10-15 | A schema with ranges and enums replaces preferences.json and window.json; keyed data stays in files. |
| [0008](0008-flatpak-sandbox-permissions.md) | Flatpak sandbox permissions | Accepted; the Flathub submission deferred by 0018 | Network, display, home and removable drives for SQLite, the SSH agent and the Kerberos KCM socket; portals for the rest; two Flathub lint exceptions. |
| [0009](0009-crypto-provider-and-sources.md) | One crypto provider, upstream sources and dependency bans | Accepted; sources and the PostgreSQL and ClickHouse TLS setup superseded by 0016, the ring ban amended by 0023 | aws-lc-rs only; deny.toml enforces sources, licenses, bans and advisory ignores. |
| [0010](0010-ddl-plans-and-table-definitions.md) | DDL plans against table definitions | Accepted | Each engine plans structure changes through its `DdlDialect` against the table's definition; the UI offers only what the plan accepts. |
| [0012](0012-window-per-session.md) | One window per connection session, built from gtk-rs subclasses | Accepted; what a window holds superseded by 0028 | One `TableProApplication` per profile through D-Bus uniqueness; a window holds at most one session and returns to the picker on disconnect; the application, the window and its workspace are subclasses, not Relm4 components. |
| [0013](0013-openssh-client-transport.md) | SSH through the system OpenSSH client | Accepted; the forced options amended by 0019, the TCP port amended by 0023 | ControlMaster per connection, Unix-socket forwards, prompts through an askpass helper. |
| [0014](0014-lossless-values-and-dialects.md) | Lossless values and engine dialects | Accepted | A value reaches the user and goes back without loss; every statement is spelled by the dialect of the connection that runs it. |
| [0015](0015-gnome-50-platform-floor.md) | GNOME 50 platform floor | Accepted; the runtime row amended by 0018 | GTK 4.22, libadwaita 1.9, GtkSourceView 5.18, GLib 2.88; AdwShortcutsDialog replaces the shortcuts window. |
| [0016](0016-driver-contract-v2.md) | Driver contract v2 | Accepted | Owned calls with engine stops, phase-aware write outcomes, server-side row limits; PostgreSQL on tokio-postgres; no forks. |
| [0017](0017-distribution-channels.md) | Distribution channels | Superseded by 0018 | Flathub, a .deb for Ubuntu 26.04 on GitHub Releases built with rustup, and an .rpm for Fedora 44 on COPR, all from `meson install` and one vendor tarball; no AppImage. |
| [0018](0018-ppa-copr-and-flathub-later.md) | A PPA and COPR first, Flathub later | Accepted | A Launchpad PPA built with `rustc-1.97` and a COPR project built on each release are the primary channels; Flathub follows as a submission a maintainer writes; Rust 1.97 is the MSRV. |
| [0019](0019-ssh-key-file-identities-only.md) | A chosen SSH key file limits the keys ssh offers | Superseded by 0020 | A key file comes with `IdentitiesOnly=yes`, so the agent's other keys cannot use up `MaxAuthTries` first. |
| [0020](0020-pin-only-a-key-file-the-agent-lacks.md) | Pin only a key file the agent does not hold | Accepted | `IdentitiesOnly=yes` only for a key file the agent lacks, so an agent-held certificate or encrypted PEM key still signs. |
| [0021](0021-engines-without-sql.md) | Engines without SQL keep the driver contract and say what they hold | Accepted; amended by 0026 | A key-value engine states `DataModel::KeyValue`, lists keys with `scan_keys` and reads them with `read_key`, has its own `SqlGrammar` variant, and is held read-only by the driver's check where the server cannot. |
| [0022](0022-ai-assistant-and-mcp-server.md) | An AI assistant and a local MCP server | Accepted | An MCP server on `127.0.0.1`, off until turned on, with a token and a per-connection External Clients level, every client write approved in the app; an AI assistant with no provider until the user adds one and a per-connection AI policy. |
| [0023](0023-loopback-relay-for-cql.md) | A loopback relay for the CQL client | Accepted | Each scylla session dials a 127.0.0.1 relay that serves only this user and carries every connection over `Transport::open`, so CQL reaches a server through an SSH forward. |
| [0024](0024-multi-cursor-on-text-marks.md) | Multiple cursors on text marks, in the app | Accepted | The SQL editor's view, a GtkSourceView subclass, keeps extra cursors as GtkTextMark pairs, runs GTK's own commands once per cursor and repeats committed text from `end-user-action`, so one undo takes back every cursor's edit. |
| [0025](0025-bundled-duckdb.md) | DuckDB built from the duckdb crate's bundled sources | Accepted | No PPA or COPR target but Ubuntu 26.10 ships libduckdb, so DuckDB 1.5.6 is compiled from the crate on every channel, with no extension fetched or loaded on its own. |
| [0026](0026-documents-in-the-table-tab.md) | Document collections open in the table tab, and their statements are shell calls | Accepted | A document engine states `DataModel::Document`, lists collections as tables, opens them in the table tab, and every builder writes a mongosh call with bound values through a document arm chosen by the grammar. |
| [0027](0027-one-data-grid.md) | One data grid on GtkColumnView, with rows and a focused cell | Accepted | Every surface shows rows in one `DataGrid`: row selection plus a focused cell, stable row slots, a row number column, values as text and a row detail pane. |
| [0028](0028-sessions-share-a-window.md) | A window holds several sessions in one tab view | Accepted | A `WorkspaceShell` per window shares one tab view among its sessions, each with its own workspace; the sidebar is a tree of the saved connections with each open session's schemas and tables. |
| [0029](0029-images-decode-in-glycin.md) | Images from the database decode in glycin's sandbox | Accepted | Row Details decodes a value's picture with the glycin crate 3.x, in a sandboxed loader process, never with GTK's in-process loaders. |

0011 is not used. It was reserved for the DDL decision, which was recorded as 0010, and docs cite ADRs by number, so the later ones keep theirs.

## Adding an ADR

1. Take the number after the highest one. Never reuse a number, even a deprecated ADR's.
2. Copy the format above into a new file. Use a dash-separated lowercase title slug.
3. If it replaces an earlier decision, set the earlier ADR's Status to `Superseded by 000N`, or `Accepted; <part> superseded by 000N`, in the same PR.
4. Open a PR. ADRs go through the same review as code.
5. After merge, link from the index above.
