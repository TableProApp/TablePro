# BookiE 0.1.4: correctness and executable quality gates

## Scope

Reconcile the two local commits (TLS endpoint identity and manual connection lab)
with remote Linux through `2c5499947`, preserving its session-rotation/SCRAM fixes,
SQLx 0.9/system SQLite, GResource and app-library groundwork. This is a stability
release, not completion of the broader [0.2 sprint](../bookie-0.2-sprint.md).

## Review actions

- Formatter safety lives in core, preserving literal-prefix adjacency, operator
  adjacency and newline-sensitive adjacent strings. PostgreSQL integration checks
  compare actual results rather than trusting the same lexer as its own oracle.
- Cell editability combines declared metadata with runtime values. BOOLEAN cells
  with bytes/text cannot emit edits; acceptance checks reject queued invalid edits.
  Isolated widget tests cover bind/rebind, normal booleans/NULL and binary TEXT.
- PostgreSQL interval minima cannot overflow; invalid address prefixes are rejected.
  A bounded byte corpus exercises every decoder without panic.
- Ignored tests have an executable environment mapping; GTK/keyring registrations
  are checked for omissions and stale entries. Each isolated test runs in its own
  process and must execute exactly once. Cargo/GTK E2E remain separate tiers.
- TLS hostname-negative tests require a successful verified control connection and
  a certificate-related rejection, not just any connection failure.
- Local/hosted fast checks share `ci-local.sh full`. Evidence under `target/quality`
  records SHA, dirty state, toolchain, mode, raw logs and per-binary test summaries.
  Release mode includes fast, widgets, drivers, TLS, keyring, PostgreSQL release,
  installed GTK, optional DuckDB, deny and audit. Manual gates are never implied.
- Settings writer uses `attempted` rather than misleading `completed` terminology.
  Its error/flush contract and the distinct workspace recovery writer are retained.
- Manual DuckDB quoting and Redis read-only SELECT permissions are corrected.
  Arch packaging declares system SQLite and the actual Rust minimum.

## Verification ledger

Packaging on this tree installs `bookie` and `bookie-agentd`, with `tablepro` aliases.
Debian `rules` and `scripts/build-deb.sh` agree at `tablepro` 0.1.4-1, with system SQLite and Rust 1.98.
The GitHub Release tag is `linux-v0.1.4`. Ubuntu 24.04 is below the GLib 2.82 / libadwaita 1.6 baseline; GTK CI uses Ubuntu 25.10.

Wayland install, rollback, and soak remain operator checks after downloading the artifacts. They are not implied by the tag.

## Install and verify on Omarchy

Follow [omarchy.md](../platforms.md#arch-and-omarchy-package). Close BookiE and privately back up existing
`~/.config/tablepro` and `~/.local/share/tablepro` before upgrading. The package
replaces the currently installed `tablepro` package but retains its application ID,
XDG paths, keyring schema and compatibility commands.

Test existing connections, draft restoration, formatting, boolean/binary grids,
Jump to Column, CSV/JSON export, cancellation and a second window under Wayland.
Keep the previous package for rollback; do not delete user data or keyring records.

## Next foundation work

Retain small commits with a failing regression, invariant/why, runner, and evidence.
Scheduled mutation covers core/policy/SSH/Redis; formatter logic now participates
in core measurements. Triage infrastructure failures separately from surviving
mutants. Coverage is a map, not a release percentage target.

0.2 must still establish lossless driver-to-grid-to-export contracts for every
engine, migration/rollback and ambiguous-write/session lifecycle acceptance. The
current Redis lossy UTF-8 mapping is legacy behavior, not the lossless target.
Keep upstream module boundaries and attribution; do not merge unrelated persistence
writers or mechanically reorganize small imported files. GNOME 50/Meson qualification,
hosted exact-candidate evidence and retry-free package soak remain explicit work.
