# Manual verification checklist

This checklist records installed and native desktop checks that are not established by GTK unit or widget tests. It is not the live milestone status: the maintainer marked 0.2.0 delivery complete, and subsequent work is tracked in the [backlog](backlog.md). An unchecked item means no result is recorded here; it does not establish whether the work is open. A failure recorded from an earlier run is historical and must be rerun after its fix. Dated package observations below identify whether they tested the published release, a pull request artifact, or current source.

Issue [#575](https://github.com/cozyGarage/BookiE/issues/575) was opened when this checklist had 107 unchecked items (2026-10-11). Later desktop scenarios expanded it; use the current checklist rather than that issue-body count.

The 0.2.0 desktop target was **Arch Linux / Omarchy / Hyprland, native Wayland**. Debian and Ubuntu GNOME desktop acceptance is tracked under PKG-2. Use the [recorded UI packets](archive/bookie-0.2-completion-handoff-2026-10-18.md#arch-omarchy-wayland-ui-packets) for release-era results; Xvfb success does not establish native Wayland behavior.

The source-matched installed GTK safety run passed 93 scenarios under Xvfb/AT-SPI on 2026-10-21; see its [package identity, result and limitations](evidence/installed-gtk-0.2.0-2026-10-21/README.md). It does not close the native Wayland visual checklist below.

Native Wayland observations are recorded separately for the [October 22 release run](evidence/installed-wayland-0.2.0-2026-10-22/README.md), the [October 23 source build](evidence/installed-wayland-0.2.0-2026-10-23/README.md), and the [October 24 installed Arch profile](evidence/installed-arch-profile-2026-10-24/README.md). They cover different binaries and checks; a later result supersedes only the specific observation it repeats. The October 22 run verified system appearance restoration and test-profile cleanup. An unchecked item has no complete current result unless one is recorded beside it.

Record the full binary/package SHA, package checksum when installed, GTK backend, OS/Hyprland/GTK/libadwaita versions, display scale, light/dark mode, result and screenshot paths. Test both normal size and a narrow/resized window, keyboard focus, clipboard and popover/dialog placement. Mark blocked and not-run items explicitly.

Take light and dark screenshots for each section, per `AGENTS.md`. Record a result beside each item rather than leaving it blank, because a blank line here reads as "passed" to the next person.

Independent value checks compare database-native results with the app's display and supported write paths. The [oracle review](oracle-review.md) explains the method and includes a historical sample; its blank worksheet is not acceptance evidence.

## Areas

| Area | Checklist |
|---|---|
| Connections and ssh | [manual-verification-connections.md](manual-verification-connections.md) |
| Sql editor and sessions | [manual-verification-editor.md](manual-verification-editor.md) |
| Grid, filters and data transfer | [manual-verification-grid.md](manual-verification-grid.md) |
| Catalog, sidebar and application shell | [manual-verification-app.md](manual-verification-app.md) |

Dated run records: [installed run 2026-10-12 and AppImage run 2026-10-21](archive/manual-verification-runs-2026-10-21.md).
