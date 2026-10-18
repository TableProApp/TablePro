# 0015: GNOME 50 platform floor

- **Status**: Accepted; the runtime row and the channel that matters amended by 0018
- **Date**: 2026-09-15

## Context

The app pinned GTK 4.14, libadwaita 1.6, GtkSourceView 5.12 and the
Relm4 `gnome_47` feature. GNOME 47 reached end of life, and building at
that floor produced a stream of deprecation warnings that hid real ones:
`gtk::ShortcutsWindow` (replaced by `AdwShortcutsDialog` in libadwaita
1.9), `gtk::Spinner` (replaced by `AdwSpinner` in 1.6) and
`gtk::Calendar::select_day` (replaced by `set_date` in GTK 4.14).

Holding an old floor also costs API. `AdwShortcutsDialog` is not just a
newer widget: `AdwApplication` loads `shortcuts-dialog.ui` from the
application's resource base path and installs `app.shortcuts` with the
Control+? accelerator, which deletes about 120 lines of hand-built
shortcut window code.

## Decision

The floor is GNOME 50:

| Component | Floor | Feature |
|---|---|---|
| GTK | 4.22 | `gtk4/gnome_50` |
| libadwaita | 1.9 | `libadwaita/v1_9` |
| GtkSourceView | 5.18 | `sourceview5/v5_18` |
| GLib and GIO | 2.88 | `glib/v2_88`, `gio/v2_88` |

`meson.build` declares the same floors, so configuring fails early on an
older platform rather than at link time. The Relm4 `gnome_47` feature is
dropped, because the crates declare their own floors directly.

## Consequences

- The keyboard shortcuts window is `data/resources/shortcuts-dialog.ui`,
  loaded by `AdwApplication`. `build_shortcuts_window`, `AppMsg::ShowShortcuts`
  and the `win.shortcuts` action and accelerators are gone; the primary
  menu targets `app.shortcuts`.
- `AdwSpinner` has no `start`, `stop` or `spinning`: it animates while it
  is visible, so the call sites toggle visibility alone.
- `cargo clippy --all-targets -- -D warnings` passes at the floor with no
  deprecation warnings.

## Distro and runtime matrix

| Target | Ships |
|---|---|
| Ubuntu 26.04 LTS | GTK 4.22, libadwaita 1.9, GLib 2.88 |
| Fedora 44 | GTK 4.22, libadwaita 1.9, GLib 2.88 |
| org.gnome.Platform//51 | GTK 4.24, libadwaita 1.10, GLib 2.90 |

The distribution packages are the primary channels
([ADR 0018](0018-ppa-copr-and-flathub-later.md)), so Ubuntu 26.04 and
Fedora 44 are the floor that matters. The Devel Flatpak builds on the
latest GNOME runtime, as a Flathub submission must.
