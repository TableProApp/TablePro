# Architecture Decision Records

These are short documents recording the **reasoning** behind major technical choices. They are not living documentation — once an ADR is accepted, it stays. If a later ADR supersedes it, link forward; do not edit history.

Every load-bearing decision in the Linux subproject has an ADR. If a contributor asks "why did we pick X", the answer should already be in this folder. If it is not, we missed an ADR.

## Format

```markdown
# 000N — Title

- **Status**: Accepted | Superseded by 000M | Deprecated
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

ADRs are short on purpose. If yours is more than a page, you are probably arguing instead of recording.

## Index

| # | Title | Status | Summary |
|---|---|---|---|
| [0001](0001-no-plugin-system.md) | No plugin system; drivers are static | Accepted | Drivers are crates, registered at compile time. No `.tableplugin`-equivalent on Linux. |
| [0002](0002-rust-gtk4-libadwaita.md) | Rust + GTK4 + libadwaita | Accepted | Validated by spike. Only stack with a production virtualized data grid (GtkColumnView). |
| [0003](0003-relm4-architecture.md) | Relm4 for app architecture | Accepted | Elm-style components scale to TablePro's view count. |
| [0004](0004-libsecret-secret-storage.md) | libsecret via oo7 for password storage | Accepted | Secret Service API is the universal Linux secret backend. |
| [0005](0005-supply-chain-policy.md) | Supply-chain policy | Accepted | Maintained crates first; custom code needs recorded evidence and a removal trigger. |
| [0006](0006-meson-cargo-build.md) | Meson drives Cargo | Accepted | Meson owns install, data files and the build-time config; Cargo stays the Rust compiler. |
| [0009](0009-crypto-provider-and-sources.md) | One crypto provider, upstream sources and dependency bans | Accepted | aws-lc-rs only; deny.toml enforces sources, licenses, bans and advisory ignores. |
| [0013](0013-openssh-client-transport.md) | SSH through the system OpenSSH client | Accepted | ControlMaster per connection, Unix-socket forwards, prompts through an askpass helper. |

## Adding an ADR

1. Pick the next number. Increments only, no gaps even if an earlier ADR is deprecated.
2. Copy the format above into a new file. Use a dash-separated lowercase title slug.
3. Open a PR. ADRs go through the same review as code.
4. After merge, link from the index above.
