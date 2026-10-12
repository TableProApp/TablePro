# Platform: Linux

The native Linux app. Every profile has these seven sections in this order, so a value is always in the same place.

## Covers

A report from Linux. The code is `linux/`: a Cargo workspace of crates under `linux/crates/` (the GTK app, the UI-free core, storage, sessions, networking, SSH and one crate per driver), built by Meson. Drivers are linked in at compile time; there are no plugins. A fix lands in one or more crates; name them.

`linux/` exists only on the `linux` branch until the first Linux release, so a checkout of `main` cannot fix it.

## Base

- Worktree base: `origin/linux`.
- Pull request base: `linux`.

## Done

`linux/AGENTS.md`, plus the root `AGENTS.md` principles and writing style it points to. Under Claude Code, `linux/CLAUDE.md` loads it once a file under `linux/` is read; read it by path anyway in Phase 0, since the worktree path is not guaranteed to trigger that. Codex does not load it at all, so read it yourself.

## Native standard

GTK 4 and libadwaita, used the way the GNOME Human Interface Guidelines describe, with the widget the toolkit already provides before anything drawn by hand. The version floor is GNOME 50: GTK 4.22, libadwaita 1.9, GtkSourceView 5.18, GLib 2.88. The compiler enforces it through the binding crates' feature gates, so an API above the floor does not build.

Sources, the API ground truth and how to build a probe: `references/research-linux.md`.

## Verify

Pass `--platform linux`, which a Linux machine picks by default. Every step runs inside `<tree>/linux` with the environment `meson devenv` gives Cargo.

| Step | When |
| --- | --- |
| `setup` | a new tree; `linux/meson.build`, `linux/meson_options.txt` or a file under `linux/data/` changed |
| `build` | always |
| `test <package> [filter]` | always, for each crate you changed |
| `test` | before the pull request: every suite, as the CI fast job runs them |
| `lint` | always: rustfmt, then clippy with and without default features |
| `data` | a desktop entry, the GSettings schema, the metainfo or the icons changed |
| `l10n` | a user-facing string or a file that holds them changed |
| `docker <package>` | a driver, SSH or anything they connect through changed |
| `secrets` | `tablepro-storage` secret handling changed |
| `dist` | `meson.build` install rules changed (commit first) |

- The first step after a merge from the base is `setup`.
- Pick packages by what you changed: `grep -rl <name> linux/crates --include='*.rs'`. Package names are in each crate's `Cargo.toml`.
- Extra review pass: none beyond the security pass.
- Traps and remedies: `references/verification-linux.md`.

## Screen

Run the app from the tree with `meson devenv -C _build ./crates/app/tablepro` inside `linux/`. A development build uses its own application ID and data directories, so it never touches an installed one; point the `XDG_*_HOME` variables at a scratch directory as well when the shot must not show the user's real connections. Nothing drives the app from a script yet: only `app.*` actions reach D-Bus, and the window's actions do not. Launch it in the state the shot needs and capture with the `org.freedesktop.portal.Screenshot` portal, which GNOME allows for an unsandboxed caller; `org.gnome.Shell.Screenshot` refuses. The portal captures the whole screen, so crop to the window. Dark and light: `ADW_DEBUG_COLOR_SCHEME=force-dark` or `force-light`.

## Ship

- A user-visible change gets one fragment under `[Unreleased]` in `linux/CHANGELOG.md`, never in the root `CHANGELOG.md`, which is the macOS release notes.
- Commit scope `linux`, or `linux-<area>` for one area of the app.
- A probe worth keeping becomes a test in the crate it measures; the Linux workspace keeps no separate probe directory.
