# Completion popup initialization, October 22, 2026

Status: implementation and local validation complete. Hosted and installed acceptance remain on the linked issue [#1388](https://github.com/cozyGarage/BookiE/issues/1388).

## Cause and fix

Application startup did not call `sourceview5::init()`. GtkSourceView initialization installs widget CSS, including a 150 px minimum width for the completion assistant. After a nonempty → empty → nonempty proposal transition, the popup can otherwise be presented before its rows acquire a width. The failure is a GTK critical, or an abort when fatal criticals are enabled.

Startup now constructs the Relm4 application to initialize GTK and its display, then initializes GtkSourceView before building application components. Existing open-file flags and activation behavior remain in the same startup helper. This covers editor, structure and JSON source widgets. The lazy proposal model is unchanged; changing it to an eager model still failed in three diagnostic runs and was reverted.

The official [GtkSourceView 5.22.0 release source](https://download.gnome.org/sources/gtksourceview/5.22/gtksourceview-5.22.0.tar.xz) establishes the initialization behavior in `gtksourceinit.c`, lines 222–255, and the completion minimum in `GtkSourceView.css`, lines 24–28. Initialization must follow GTK/display creation: it captures the default display and only runs once. This does not introduce a new native library version requirement.

## Reproduction and regression

The actual BookiE provider in a rooted window failed with `gdk_popup_present: assertion 'width > 0' failed`. Three single-prefix cases passed; cycling `do s`, `do so`, `sel`, `do s` failed as proposals returned after the empty case. A GDB backtrace reached popup presentation from the completion async callback.

The independent [initialized C probe](probe.c) and [otherwise identical probe without initialization](probe-without-init.c) use the installed libraries without BookiE, Rust or a database. Initialized: three of three passed. Without initialization: three of three aborted with the same critical. The [comparison record](initialization-ab-results.json) and compressed logs retain the observations.

The registered isolated GTK regression invokes the production startup helper and checks real popup visibility and positive allocated dimensions across those transitions. It also checks insertion through the existing provider activation helper. That insertion check is separate from popup presentation; this record does not claim keyboard selection of a displayed proposal, native Wayland acceptance or packaged acceptance. Bounded polling waits for expected presentation instead of assuming an unloaded runner.

## Independent probe commands

From this directory, compile each variant with the installed development libraries:

```bash
cc probe.c -o /tmp/bookie-completion-initialized $(pkg-config --cflags --libs gtksourceview-5 libadwaita-1)
cc probe-without-init.c -o /tmp/bookie-completion-uninitialized $(pkg-config --cflags --libs gtksourceview-5 libadwaita-1)
G_DEBUG=fatal-criticals GDK_BACKEND=x11 GSK_RENDERER=cairo GTK_A11Y=none GIO_USE_VFS=local dbus-run-session -- xvfb-run -a /tmp/bookie-completion-initialized
G_DEBUG=fatal-criticals GDK_BACKEND=x11 GSK_RENDERER=cairo GTK_A11Y=none GIO_USE_VFS=local dbus-run-session -- xvfb-run -a /tmp/bookie-completion-uninitialized
```

The second command is expected to abort on the affected uninitialized stack. The original host used GTK 4.24.1, GtkSourceView 5.22.0 and libadwaita 1.10.0 on Arch Linux under Xvfb. The tests use disposable windows and sessions and do not alter desktop configuration.

## Completed local validation

Preflight passed: 345 harness tests, 2,056 unit tests, 2,059 sandbox tests and the Redis cancellation regression. All 107 registered isolated GTK tests passed on the final source, including the new regression. Strict all-target app Clippy and all 728 ordinary app tests passed; 145 environment-specific tests remained ignored in that ordinary tier. Documentation links, issue ledger and isolated registrations passed. No existing test was removed or baseline raised.

[manifest.json](manifest.json) pins final source and test executable hashes, counts, scope and compressed log digests. The gzip files retain full output. GitHub checks, maintainer Forgejo and native/package acceptance remain separate. No Forgejo run or merge was started.
