# 0002 — Rust + GTK4 + libadwaita

- **Status**: Accepted; version floor superseded by [0015](0015-gnome-50-platform-floor.md)
- **Date**: 2026-04-26

## Context

The Linux app needs a GUI stack. Constraints from the project brief:

- **Native only.** No Electron, no WebView, no Tauri-style hybrid.
- **First-class on modern Linux desktops.** GNOME 47+ and KDE Plasma 6 must both work; GNOME polish is the priority.
- **A virtualized data grid is the central widget.** Million-row result sets must scroll smoothly.
- **A SQL editor with syntax highlighting and completion is required.**
- **Accessibility (screen reader, keyboard navigation, IME) must work.**
- **Sustainable maintenance** at the scale of one-to-two engineers.

The stack must be picked once and committed to. Switching the GUI framework partway through is a year-scale rework.

## Decision

The Linux app is built in **Rust** using **GTK4** (4.14+) with **libadwaita** (1.5+). Bindings are provided by [`gtk4-rs`](https://gtk-rs.org) and [`libadwaita-rs`](https://world.pages.gitlab.gnome.org/Rust/libadwaita-rs/).

## Rationale

A 2-day spike (April 2026) validated the stack against the load-bearing requirement: render and scroll 100,000 rows. `GtkColumnView` with `SignalListItemFactory` virtualization built the column view in 133 ms and scrolled smoothly with no perceptible lag.

| Stack | Data grid | Verdict |
|---|---|---|
| GTK4 + libadwaita | `GtkColumnView` — production-grade, used by GNOME Files | ✅ Picked |
| Slint 1.16 | None; build from `Flickable` | ❌ Missing the central widget |
| Iced 0.14 | None | ❌ Missing the central widget |
| Floem (Lapce's framework) | Custom; pre-1.0 framework | ❌ Framework instability |
| egui | Immediate-mode, broken IME for CJK | ❌ Accessibility failure |
| Qt6 + KDE Frameworks | `QTableView` — production-grade | Viable; lost on language (C++) |
| SwiftCrossUI / adwaita-swift | Pre-1.0; small ecosystem | ❌ Tooling immaturity |
| Tauri / Dioxus desktop | WebView | ❌ Excluded by "native only" |

GTK4 is the only candidate where the virtualized table widget is **already built and proven** at the row counts a database client demands. Building one from scratch in a Rust-native framework is a 3–6 month engineering task, paid before any other feature ships.

The libadwaita layer adds the layout primitives a database client wants: `AdwNavigationSplitView`, `AdwToolbarView`, `AdwTabView`, `AdwDialog`, `AdwEntryRow`, `AdwPasswordEntryRow`. Each is one-line in user code and looks correct on GNOME 47+ out of the box.

Rust gives us the driver ecosystem for free. The 2026 state of `sqlx`, `mongodb`, `scylla`, `fred`, `clickhouse-arrow`, `tiberius`, `aws-sdk-dynamodb` is the strongest cross-engine pure-Rust DB story in any ecosystem. Pairing it with C++ (Qt) would mean wrapping or duplicating that work.

The cost is that a future port to macOS or Windows from this codebase is impractical. Both have separate apps in this monorepo, and this is acceptable.

## Consequences

Accepted:

- **Linux only.** GTK4 has marginal Windows / macOS support; we do not pretend to use it.
- **GNOME-first.** KDE Plasma works because Adwaita widgets render correctly there; the app does not adopt Plasma styling. Users who want a Plasma-native client have alternatives.
- **Wayland-first.** X11 works because GTK4 supports it, but bug reports are triaged Wayland-first.
- **gtk4-rs upgrade discipline.** Monthly cadence. Pin to specific versions; plan binding upgrades alongside GNOME release cycles.
- **No declarative UI macros.** Relm4 (see [0003](0003-relm4-architecture.md)) gives structure; we do not adopt third-party DSLs on top.

Gained:

- The app feels native on the dominant Linux desktop.
- A widget set covering 95% of what the app needs without custom drawing.
- A Rust ecosystem that solves driver problems we would otherwise solve ourselves.
- A spike-validated stack — no surprises in Phase 0.

## Alternatives considered

**Qt6 + KDE Frameworks (C++).** Mature, KDE-native, has the data grid. Lost because committing to C++ for the host means giving up the Rust DB driver story or paying a heavy FFI tax to keep both. Choosing Qt would also lock the project into KDE-styling; GNOME users would see a non-native app, and they are the larger audience.

**Slint.** Closest non-GTK contender. Lost on the data grid widget. May be revisited for a v2 if Slint's table story matures.

**Iced.** Beautiful for single-window Elm-style apps. Lost on the data grid widget and on its document-IDE shape mismatch.

**SwiftCrossUI + adwaita-swift.** Tempting because it would share types with the macOS app. Lost on tooling, debug, and DB driver maturity.

**Egui.** Immediate-mode toolkits cannot deliver the layered, accessible, screen-reader-friendly UX a database client needs.
