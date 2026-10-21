# Installed BookiE 0.2.0 GTK safety run

## Result

The installed release binary passed all 93 GTK safety scenarios from its matching `linux-v0.2.0` source: 93 passed, zero failed, process exit 0, in 426 seconds. The harness ran under a private D-Bus session, Xvfb, and AT-SPI. It did not use the native Wayland display.

The installed package was `bookie 0.2.0-1` for x86_64. Its `BUILD_INPUTS.json` identifies release commit `bd31a1d8b3dc83200c324b9f37fa83f3660d8aab` (`linux-v0.2.0`). `/usr/bin/bookie` SHA-256 was `d45556da8b994688987157cfc74e1d58e39d10894e11b157fc8077b2ccfbb386`. Host-side `pacman -Qkk bookie` reported 28 files and zero altered files.

The host was Arch Linux / Omarchy with Hyprland 0.56.2, native Wayland, GTK 4.24.1, libadwaita 1.10.0, GtkSourceView 5.22.0, and scale 1. The harness used X11 through Xvfb at 1280x1024 and system Python 3.14.8 for the installed `pyatspi` binding. No shell or desktop configuration was changed.

Coverage included connection-form and socket controls, SQL policy and approval outcomes, audit behavior, profile and bundle flows, editor and workspace restoration, result export and typed values, grid editing and paste, filtering and statistics, active-edit save/discard/cancel paths, and CSV import refresh behavior. The optional MySQL-container-only scenario was not enabled. This run does not qualify real database-driver integration or native Wayland appearance and interaction.

Three `A connection to the bus can't be made` messages appeared after the final passing scenario during teardown. There were no failure markers or traceback, and the harness returned exit 0.

## Resource observation

A five-second sampler recorded 85 samples over the run. It measured all processes owned by the user, not BookiE alone: peak aggregate CPU was 351.5%, peak aggregate RSS was 9,032,764 KiB, and the largest single process RSS was 841,520 KiB. These host-wide measurements are not an application footprint benchmark.

The run log, profile, and per-scenario temporary artifacts remain under `/tmp/bookie-installed-gtk-2026-10-21/`. They are not committed. The independent native Wayland light/dark, narrow-window, focus, clipboard, and screenshot checklist remains in [manual verification](../../manual-verification-0.2-features.md).
