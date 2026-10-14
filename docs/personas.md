# Personas - who we build for

> [NEEDS REVIEW] Draft written on 2026-10-11 from the UI, MCP and packaging surfaces. A maintainer review is pending.

A spec names which persona it serves.

## Why personas gate everything

A capability that serves no one is waste. When two personas conflict, the resolution is a recorded decision, not a coin flip. The primary persona wins ties unless a decision says otherwise.

## The roster

| Persona | Primary? | One-line |
|---|---|---|
| `Local DBA` | yes | runs BookiE on their own Linux machine against databases they already administer |
| `Package user` | no | installs a distro package and expects it to launch without a build tree |
| `MCP operator` | no | issues tokens so an agent can call tools without a raw database handle |
| `Packager` | no | builds Debian, Arch or Flatpak artifacts and keeps identifiers stable |

## Persona template

Copy this block per persona only when adding a new one.

### `Local DBA`

- **Distrust & friction.** A client that phones home, demands an account, or runs SQL the user did not see. A grid that silently changes a stored type. A cancelled query that keeps running on the server.
- **Jobs to be done.** When I open a saved connection, I want to browse and query without leaving the desktop, so I can stay on my machine. When I run a write, I want policy and an audit record, so I can see what happened.
- **Goals.** Connect through SSH if needed. Bind parameters. See native values. Stop a query on the server. Keep credentials out of JSON files.
- **Decisions they influence.** Static drivers (ADR 0001), GTK stack (ADR 0002), Relm4 (ADR 0003), Secret Service (ADR 0004), cancellation (ADR 0005), type/value (ADR 0007), session ownership (ADR 0008).
- **Success signals.** A connection opens and a governed query returns without an account. Saved database and SSH credentials use Secret Service; MCP tokens are shown once at issuance. A denied statement is audited as denied.
- **Anti-goals.** Multi-tenant roles, a hosted workspace, a web console.
- **Who / context.** Developer or DBA on Arch, Debian testing or another Linux desktop. Comfortable with SQL. Uses GTK applications.

### `Package user`

- **Distrust & friction.** A download that needs a compiler, a nightly runtime, or a license key. A `.desktop` file that launches a binary they cannot name.
- **Jobs to be done.** When I install the package, I want `bookie` to start, so I can work without cloning the repo.
- **Goals.** Documented distro artifacts. `tablepro` still works as an alias. XDG paths stay where the last version left them.
- **Decisions they influence.** Rename boundary in AGENTS and the sprint; packaging rows in the ledger (PKG-*).
- **Success signals.** The documented 0.1.5 Debian and Arch packages launch. No account gate appears at first run.
- **Anti-goals.** Building from source, running CI, editing policy rules.
- **Who / context.** Installs from a release page or a distro package. May never open the repository.

### `MCP operator`

- **Distrust & friction.** A token that can reach every saved connection, or a tool that returns a raw driver handle. An agent that runs writes on a read-only token.
- **Jobs to be done.** When I issue a token, I want scopes and an allowlist, so the agent can only call what I listed. When the agent runs SQL, I want the same `PolicyGuard` the UI uses.
- **Goals.** Least-privilege tokens. Empty allowlist denies access. Rate limits hold. Audit still writes on deny and cancel.
- **Decisions they influence.** Authority boundaries in ARCHITECTURE; PolicyGuard invariants in AGENTS.
- **Success signals.** A read-only token cannot call write tools. A token with an empty allowlist cannot use a connection. SQL still goes through `PolicyGuard`.
- **Anti-goals.** A public multi-tenant MCP cloud, OAuth to a BookiE account.
- **Who / context.** Same person as the local DBA, or someone who runs `bookie-agentd` beside the GUI.

### `Packager`

- **Distrust & friction.** A rename that changes app ID, XDG paths or keyring schema and breaks upgrades. A Flatpak permission that silently disables SSH.
- **Jobs to be done.** When I cut a package, I want identifiers to stay `tablepro` / `com.tablepro.linux` unless the sprint says otherwise, so existing installs keep working.
- **Goals.** Reproducible Debian, Arch and later Flatpak artifacts. Meson install names `bookie` / `bookie-agentd`.
- **Decisions they influence.** Persistence identity (ADR 0009); packaging and Flathub ledger rows.
- **Success signals.** App ID and keyring schema do not change in a packaging-only release. A refused Flatpak OpenSSH path fails closed rather than falling back to a weaker tunnel.
- **Anti-goals.** Shipping a Windows or macOS tree from this repository.
- **Who / context.** Maintainer or contributor who runs the packaging scripts and reads `docs/platforms.md`.
