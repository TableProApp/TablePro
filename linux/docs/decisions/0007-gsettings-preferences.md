# 0007. Preferences and window geometry in GSettings

Date: 2026-09-15

## Status

Accepted.

## Context

Preferences lived in `~/.config/tablepro/preferences.json` and window
geometry in `window.json`, both hand-rolled: a `serde` struct, an atomic
write, and a process-wide cache to keep a spin button from re-parsing the
file on every tick.

That shape has three costs. Nothing propagates a change, so a new editor
font size never reached an already-open editor. The files are invisible
to `gsettings` and `dconf-editor`, which is where a GNOME user expects to
find them. And a schema-less JSON file has no ranges, so a page size of
zero or a negative retention was only caught, if at all, at the point of
use.

## Decision

`data/app.tablepro.TablePro.gschema.xml` holds every app-wide preference
and the window geometry. `tablepro_storage::AppSettings` wraps it in
typed accessors.

- Each key carries a summary, a description and, where it is bounded, a
  `<range>`. GSettings then rejects an out-of-range write rather than
  storing it, and `AppSettings` turns that refusal into
  `SettingsError::Write`.
- The four CSV option enums are schema enums with nicks, so `dconf-editor`
  shows `comma` rather than `0`.
- `query_timeout()` returns `Option<Duration>`; zero seconds means no
  timeout and the type says so.
- `AppSettings::open` looks the schema up through
  `SettingsSchemaSource::default()` first, because `gio::Settings::new`
  aborts the process when the schema is not installed.
- `AppSettings::with_backend` takes a schema directory and a backend, so
  tests compile the schema into a `TempDir` and run against
  `memory_settings_backend_new()` instead of the user's dconf database.

High-churn keyed data stays in files. Column widths, per-table filters and
workspace tabs are unbounded maps, which is not what GSettings is for.

## Consequences

- A setting change reaches every open view through
  `changed::<key>`, and a preference row binds with `gio::Settings::bind`
  instead of a read-modify-write cycle.
- `gsettings get app.tablepro.TablePro default-page-size` works, and so
  does resetting the app from the command line.
- The schema has to be installed for the app to start. Meson installs and
  compiles it; the GTK test suite points `GSETTINGS_SCHEMA_DIR` at the
  build tree. Under Flatpak, GSettings writes a per-app keyfile inside
  `~/.var/app`, so no dconf hole is needed.
- `preferences.json` and `window.json` are not migrated. A development
  build keeps its own settings path anyway, and the clean break is
  recorded in the PR description.
