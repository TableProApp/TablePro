# B4 current Linux tip acceptance

The manifest records local runs against BookiE `fork/linux` merge commit
`97e5f55bddacdfef427c51f162917fedcace3a9f`. The application binary was built
from that checkout and installed per-user in a package-layout directory. It
was not installed by pacman and does not qualify as distribution-package
acceptance.

The GTK suite used Xvfb/X11 with private D-Bus and AT-SPI. The PostgreSQL
release fixture used Docker Compose and exercised SSH host-key refusal/audit,
multi-hop trust, second-hop refusal, tunnel loss, reconnect, and saved mTLS.
The MySQL approval regression ran against MySQL 8.0; the failed-batch selector
ran its MySQL and MariaDB containers serially. Docker reported no remaining
running test containers after the fixtures completed.

At the time this evidence was captured, the post-merge Build Linux workflow
was still in progress. The logs do not establish hosted results, package
manager installation, native Wayland interaction, Windows AD interoperability,
or optional/vendor MySQL engines.

## Wayland observation

A separate manual launch on the earlier `3b903b826bf487ef7fad6eacb3a5b67c4c8b8bd1`
build produced a local systemd-coredump (PID 124876, 2026-10-09 17:26 CEST).
The main thread faulted in GTK's `gtk_widget_get_display` while Wayland client
events were being dispatched. The app had logged window activation and
workspace readiness in the same second. On `97e5f55`, an isolated 8-second
Wayland startup smoke showed no SIGSEGV and logged window activation, but did
not reach `workspace ready`; the isolated D-Bus could not activate the
AT-SPI registry, and the timeout stopped the process. This is incomplete and
does not establish native Wayland acceptance or confirm the earlier crash is
fixed. The raw output is `wayland-smoke.log`.
The repository's headless Wayland runner could not be started on this host
because `gnome-shell` is unavailable. Native Wayland acceptance remains open.
