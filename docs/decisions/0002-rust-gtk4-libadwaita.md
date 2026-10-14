# 0002: Rust, GTK4, and libadwaita

- **Status**: Accepted
- **Date**: 2026-04-26
- **Updated**: 2026-10-11

## Context

The application needs a native Linux GUI with these properties:

- A virtualized grid for large database results.
- A SQL editor with highlighting and completion support.
- Keyboard, screen-reader, and input-method support.
- Native desktop integration on GNOME and KDE Plasma.
- Async database work without blocking the UI thread.
- A maintenance cost suitable for a small team.

Changing the GUI stack after product development starts would require a large rewrite.

## Decision

BookiE uses Rust and the gtk-rs stack on Linux only. Two native-library floors apply; they are not interchangeable:

| Floor | GTK4 | GLib | libadwaita | GtkSourceView | Where it applies |
|---|---|---|---|---|---|
| Cargo compile / CI floor | 4.14+ | 2.80+ | 1.5+ | 5.12+ | Ubuntu 24.04 and Debian 13 Cargo-based distro-floor tests; this floor does not configure the root Meson project ([platforms](../platforms.md), [packaging](../../apps/linux/packaging/README.md)) |
| GNOME 50 Meson / package line | 4.22+ | 2.88+ | 1.9+ | 5.18+ | Root Meson dependency requirements and GitHub Release `.deb`; Arch/Omarchy packages track current GNOME |

Rust bindings come from the gtk-rs project. Rust 1.98 remains the language floor for both. Cargo compile and test support at the lower floor does not imply that Meson builds or the release `.deb` support those libraries.

## Rationale

`GtkColumnView` provides the virtualized list and column model needed by the result grid. `RowStore` weakly caches row GObjects on demand, preserving each object's identity while consumers hold it; clean shared rows can be recreated after release, while drafts and replacement rows remain model-owned. The query result itself remains fully resident in memory; database paging is a separate capability and is not implied by widget virtualization. GtkSourceView provides the editor foundation. GTK supplies accessibility, input methods, clipboard integration, drag and drop, and desktop services without embedding a browser runtime.

libadwaita provides navigation, tab, toolbar, dialog, and preference widgets that match the selected GNOME platform baseline. GTK remains usable on KDE Plasma without a second UI implementation.

Rust provides the async and database libraries used by the static driver crates. Keeping the host and drivers in one language avoids a foreign-function boundary between the UI service layer and database operations.

## Consequences

Accepted:

- The application targets Linux only.
- GNOME behavior is the primary desktop reference.
- KDE Plasma is supported through GTK and standard desktop services.
- Wayland is the primary display path. X11 remains supported by GTK.
- GTK, libadwaita, Relm4, and system GLib requirements must be upgraded together within a chosen floor; raising the package line does not silently raise the distro-floor CI target.
- Native development packages are required for local builds.

Gained:

- Native widgets for the application shell and data grid.
- GtkSourceView for SQL editing.
- Existing accessibility and input-method integration.
- One Rust type system across services and database drivers.

## Alternatives considered

**Qt with C++.** It has a mature table widget, but it would split the application from the Rust driver ecosystem or require a large foreign-function interface.

**Slint, Iced, Floem, and egui.** Rejected because none provided the required native, accessible, virtualized database grid when the decision was made.

**Browser-based desktop shells.** Rejected because the product contract requires a native Linux interface without an embedded browser.
