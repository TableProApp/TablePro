# 0048: The Flatpak build reads the folders of the Flatpak apps it imports from

- **Status**: Accepted; amends 0008
- **Date**: 2026-11-25

## Context

Import from Another App and the setup guide ([core ADR 0057](../../../core/docs/decisions/0057-a-setup-guide-shows-on-an-empty-library.md)) read another database app's connections from its files. For three of the apps they import from, the core's importers (`core/crates/foreign-import/src/apps/`) also look in the folder the app's Flathub build keeps under `~/.var/app`.

[0008](0008-flatpak-sandbox-permissions.md) grants the home folder and nothing else of the user's. Flatpak's `home` grant leaves out `~/.var/app`: an app reaches only its own folder there (https://docs.flatpak.org/en/latest/sandbox-permissions.html). So the Flatpak build of TablePro never found those apps when they came from Flathub, and said they were not on the computer, while the .deb and .rpm found them.

## Decision

Both manifests grant, read-only, each `~/.var/app/<id>` the importers search:

- `--filesystem=~/.var/app/io.dbeaver.DBeaverCommunity:ro`
- `--filesystem=~/.var/app/com.jetbrains.DataGrip:ro`
- `--filesystem=~/.var/app/io.beekeeperstudio.Studio:ro`
- `--filesystem=~/.var/app/io.beekeeperstudio.desktop:ro`, the older id of the same app

`build-aux/tests/test_flatpak_foreign_apps.py` reads the ids from the importers and fails when a manifest misses one, grants one they do not search, or grants one for writing.

## Rationale

- **Read-only, one folder per app.** An import only reads, and never changes the other app's files. A grant per id is the narrowest Flatpak offers.
- **The ids come from the core.** The importers are the one list of where each app keeps its data; the test holds the manifests to it.

## Consequences

- A new importer, or a new Flatpak id of a known app, adds a grant to both manifests in the same change, or the packaging test fails.
- The Flathub linter refuses each grant as `finish-args-flatpak-appdata-folder-<id>-ro-access`. `build-aux/flatpak/lint-exceptions.json` lists the four for both IDs, and the request to Flathub before the first submission asks for them with this ADR's reason.

## Alternatives considered

- **The document portal.** It hands over one file the user picks, and these apps keep a folder of files per project.
- **`--filesystem=~/.var/app:ro`.** Every Flatpak app's data, for four folders.
- **Leaving Flathub builds out.** Users of the Flatpak build would see an import step that finds nothing.
