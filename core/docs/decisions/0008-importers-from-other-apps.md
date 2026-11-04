# 0008: Importers from other apps live in the core

- **Status**: Accepted
- **Date**: 2026-11-03

## Context

The macOS app imports saved connections and saved queries from six other database clients, in Swift under `apple/TablePro/Core/Services/Export/ForeignApp/`, with its review in `TableProImport`. The core had no importer, so the Linux app could not import from another app, and the Windows app offers only TablePro's own file until the importers reach the core.

## Decision

`tablepro-foreign-import` (`core/crates/foreign-import`) holds every importer, where each app keeps its files on macOS, Linux and Windows, and the review that maps what it read onto the core's connection library with the macOS duplicate handling. The macOS app keeps its Swift importers until it moves to the core.

## Rationale

- **One record shape.** An importer yields `ForeignConnection` records in the shape of the macOS app's exported connection: TablePro's engine names, the macOS SSL modes and colours. Each platform's library maps that one shape, so an importer is written once.
- **Platform services come in from the app.** `ForeignAppDirs` is a value: the home folder and the config and data directories, which a Flatpak build takes from `HOST_XDG_*`. `ForeignHost` answers whether an app is installed and hands over the keychain another app saved its passwords in. Linux and Windows pass `PlainHost`, which has neither.
- **Passwords.** `PasswordSource::AppFiles` apps keep them in their own files under a fixed key, which the core decrypts on every platform. `PasswordSource::Keychain` apps keep them in a keychain, which only macOS lets another app read, and only after the user allows it. A KeePass file an app keeps beside its settings is read on every platform.
- **Losses are said, not hidden.** `PasswordOutcome::LeftInKeychain` says passwords stayed in the other app's keychain, and `Stopped` that the user refused a keychain prompt or the store was locked. Each review row carries `RowNote`s: an engine no driver opens, a missing key or certificate file, an SSL mode the core maps to a stricter one (Preferred to Require, Verify CA to Verify Full), and every field it cannot keep. A saved query the core library cannot hold, such as one that belongs to no connection, gets a `QueryAvailability` that says why.
- **Duplicates as on macOS.** A row matches a saved connection by host, port, database and user, trimmed and ignoring case. It starts unchecked and offers Add as Copy, Replace only when the saved one connects the same way, and Keep Existing when the row brings saved queries. `ConnectionStore::add_imported_blocking` writes the plan only if the library is still the one reviewed, makes group paths in place, and never lets an entry take another's name.
- **Each importer owns its locations.** A `locations` module per app lists the places it searches on each platform, with the source that settles each one. Where an app can live in several places on Linux (the XDG directory, the default one, a Flatpak's or a Snap's copy), the copy changed last wins.

## Consequences

- TablePro's Flatpak cannot read another Flatpak's `~/.var/app` folder, which `--filesystem=home` leaves out, and adds no grant for it ([Linux ADR 0008](../../../linux/docs/decisions/0008-flatpak-sandbox-permissions.md)). Distribution packages read those folders.
- Some Windows passwords need host hooks the Windows app adds with its importer flow: DPAPI for a KeePass main key marked `CRYPT_32`, and Credential Manager for an app that keeps its key there. Until then the review reports those passwords as left behind.
- The core library keeps each saved query under one connection with no folder or keyword, so a query that belongs to no connection is listed and not imported, and folders and keywords are dropped.
- The core fixes several defects the Swift importers still have; the pull request that added this crate lists them. The macOS app takes the fixes when it moves to the core.

## Alternatives considered

- **A crate per app.** Six crates that share the record, the assembly, the SQL file walker and the review, for no boundary the apps need.
- **Reading other apps' keyrings in the core.** A platform service, and inside a Flatpak the Secret portal shows an app only its own items.
- **Flatpak grants for each app's `~/.var/app` folder.** Broader access for a one-time import, and a lint exception Flathub would have to grant per app.
