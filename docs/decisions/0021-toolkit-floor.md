# 0021: Support only the newest GTK toolkit

- **Status**: Accepted
- **Date**: 2026-10-23

## Context

[ADR 0002](0002-rust-gtk4-libadwaita.md) defined two native-library floors: a Cargo compile and CI floor at the Ubuntu 24.04 stack (GTK 4.14, libadwaita 1.5, GtkSourceView 5.12) and a GNOME 50 Meson and package line (GTK 4.22, libadwaita 1.9, GtkSourceView 5.18). CI ran on Ubuntu 24.04 and Debian 13 containers and on runner hosts with their own toolkits.

Older toolkits cost UI work that newer releases no longer need:

- [#1445](https://github.com/cozyGarage/BookiE/issues/1445): GTK 4.18 under X11 pops down a one-row completion popup. The completion test was weakened to two proposals and a known limitation was published.
- [#1416](https://github.com/cozyGarage/BookiE/pull/1416): libadwaita 1.5 on Ubuntu 24.04 does not expose dialogs with an accessible dialog role, so the GTK scenarios skipped dialog waits there and used a separate click offset.
- [#1388](https://github.com/cozyGarage/BookiE/issues/1388): a completion popup sizing critical on GTK 4.24 under X11. Defects on the current toolkit already compete for the same UI time.

Each workaround needs code, tests, CI capacity and a desktop to reproduce on. The team is small, and newer toolkit releases already fix the old-toolkit bugs.

## Decision

The maintainer decided on 2026-10-23 that BookiE supports one toolkit floor, the newest stable line:

| Library | Minimum |
|---|---|
| GTK 4 | 4.24 |
| libadwaita | 1.10 |
| GtkSourceView 5 | 5.22 |

This is what Arch Linux and Debian testing ("forky") ship (GTK 4.24.1, libadwaita 1.10.0, GtkSourceView 5.22.0). GLib stays at 2.88. The Flatpak manifests move to the GNOME 51 runtime.

The floor is enforced in three places:

- The application checks the running library versions at startup and exits with a message naming the required and found versions when any is older.
- The root Meson project requires these versions.
- The Debian and Arch packages declare versioned dependencies on them.

The gtk-rs API level is separate from the runtime floor. libadwaita and GtkSourceView compile at `v1_10` and `v5_22`. GTK compiles at `gnome_47` (GTK 4.16 API): the GTK 4.18 level deprecates `GtkShortcutsWindow`, which the shortcuts window still uses, and raising it waits for that window to move to `AdwShortcutsDialog`.

The distro-floor CI job builds and tests on `debian:testing` only. No job tests an older toolkit, and fixes are not backported to older toolkits.

## Implementation clarification, October 23

The shortcuts migration replaces the deprecated GTK shortcuts window with `AdwShortcutsDialog`. With that migration the GTK Rust API features can advance to `gnome_50` plus `v4_24`, and GLib to `v2_88`, matching the accepted runtime floor. The earlier API-level exception records the state before this migration; it no longer describes the migrated code. Toolkit requirements and distribution support do not change.

## Rationale

One floor removes per-version branches from the app and the test tier and makes the floor the same stack developers run. Users on older distributions have a path that does not depend on BookiE carrying workarounds: a newer distribution release or, once offered, the Flatpak build.

## Consequences

- Ubuntu 26.04 LTS (GTK 4.22.4, GtkSourceView 5.18.0, libadwaita 1.9.1), Debian 13 (GTK 4.18.6, GtkSourceView 5.16.0, libadwaita 1.7.6) and Ubuntu 24.04 (GTK 4.14.5, GtkSourceView 5.12.0, libadwaita 1.5.0) are unsupported. The Debian package does not install there and a source build exits at startup.
- Flatpak on the GNOME 51 runtime is the intended path for those distributions. Flathub publication remains PKG-4 and PKG-8.
- Every Forgejo runner that runs GTK jobs must have GTK 4.24, libadwaita 1.10 and GtkSourceView 5.22 before this change merges. On 2026-10-23 the hosts `exec-a`, `exec-b` and `exec-c` run Debian 13 and the Ubuntu runner VM runs 24.04; merging first makes every Forgejo GTK job fail. Debian testing ("forky") is the reference GTK runner host; an Ubuntu 26.04 runner is below the floor and cannot run GTK jobs. Runner labels stay unchanged; the native Ubuntu nightly job is removed.
- When a newer toolkit becomes the stable line on the reference distributions, the floor moves with it by a new decision.

## Alternatives considered

- Keep the two-floor model. It keeps the workaround cost that prompted this decision.
- Use Ubuntu 26.04 LTS (GTK 4.22) as the floor. It still needs version-specific handling and would be the only CI stack on that line.
- Ship only Flatpak. Native Arch and Debian packages remain the primary 0.2 targets.
