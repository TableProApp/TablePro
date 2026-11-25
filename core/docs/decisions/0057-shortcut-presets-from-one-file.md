# 0057: Shortcut presets come from one file

- **Status**: Accepted
- **Date**: 2026-11-24

## Context

A user who moves from another database client brings its keys along. The macOS app keeps a key per command with user overrides; the Linux and Windows apps keep a fixed table each, with no way to change a key. The three apps share no names for their commands, and the same key means different things among them: Cmd+Enter runs the statement at the caret on macOS, and Ctrl+Enter runs the whole text on Linux and Windows. The maintainer decided on 2026-11-24 to ship a shortcut preset per import source on macOS, Linux and Windows, from data the core holds.

## Decision

`core/crates/core/keymaps.json` holds one preset per import source, keyed by `ForeignApp::id()`, with each binding named by the macOS `ShortcutAction` raw value of what it does. Each app maps those names to its own commands and applies one rule.

### The file

- `schemaVersion` 1, then `presets`: each with `id`, `name` (the importer's display name), `platforms` (where `ForeignApp::runs_on` is true) and `bindings`. Unknown fields fail the parse at every level.
- A binding has `action` and up to four chords: `key` for every platform, `mac`, `linux` and `windows`, and `derived`. macOS reads `mac`, else `key`; Linux `linux`, else `key`; Windows `windows`, else `key`. A row with no field for a platform has no binding there.
- Chords use VS Code's keybinding text: modifiers `ctrl`, `shift`, `alt`, `cmd`, written in that order, then the key by its VS Code name. `cmd` appears only in `mac`, and `ctrl` on macOS is Control. A shifted glyph is its base key with `shift`, and `enter` is Return.
- The actions are the macOS raw values `executeQuery`, `executeAllStatements`, `explainQuery`, `formatQuery`, `newTab`, `closeTab`, `showNextTab`, `showPreviousTab`, `refresh`, `newConnection`, `quickSwitcher`, `toggleTableBrowser`, `saveChanges`, `addRow`, `delete`, `duplicateRow`, `toggleFilters`, `find`, `findAndReplace`, `toggleHistory`, `cancelQuery` and `commitTransaction`, plus `discardChanges` and `showSettings`, which have no macOS command and resolve to nothing there.
- `derived` marks a row whose Linux and Windows chords were read as Ctrl for Cmd from a source that publishes only its macOS keys. macOS ignores it.

### What the data holds

`core/crates/core/tests/keymaps.rs` enforces every rule below.

- Keys a source app's own keymap gives, per platform; the `tableplus` preset's non-macOS rows are `derived`.
- No Ctrl or Cmd alone on C, V, X, Z or A.
- No bare key: every chord holds Ctrl, Alt or Cmd, or is a function key.
- No two bindings of a preset on one chord on one platform. Where a source gives one key to two commands, the editor command keeps it; else the command that holds it as TablePro's default; else the narrower one. The other row is left out.
- The `dbeaver`, `datagrip` and `dbx` presets run all statements with Ctrl+Shift+Enter on Linux and Windows, since their own key there is Alt+X, which those platforms refuse, or none.
- A Control chord a source binds on macOS stays Control.

### Reading it

- Rust: `tablepro_core::keymap` compiles the file in with `include_str!`. `presets()`, `preset_ids(platform)` and `preset(id, platform)` return `keymap.*` codes on failure. The Linux app calls it directly.
- FFI: `keymap_preset(id, platform)` and `keymap_presets(platform)`. The platform is always an argument, never the build target, so a test on any host reads Windows rows. The action crosses as its name, so a new action leaves the generated bindings alone.
- macOS bundles the file as a resource and decodes it in Swift until it links the core ([0010](0010-macos-on-the-core.md)).

### Applying it

- A preset row wins; a TablePro command it displaces is left with no key.
- A bare-key default, such as Linux's Escape to stop a run or Delete to delete rows, keeps its key, and the preset chord is added as a second trigger.
- Each app drops the rows its platform refuses and keeps the default for those commands: macOS its reserved and editor keys, GNOME's Super and Alt with a letter, Windows' Ctrl+Alt, Alt with a letter and punctuation on menu commands.
- macOS writes a preset once into the user's overrides, and Restore Defaults undoes it. Linux and Windows store the chosen id and work out the table live. Choosing TablePro means no preset.

## Rationale

- **One file.** The source apps' keys are the same facts on every platform; a table per app drifts. JSON is what every shared file in the repository uses, and Swift reads it with no new package.
- **Commands by what they do.** The same chord means different things across the three apps, so a preset says what a key does and each app maps that to its nearest command.
- **macOS raw values.** The macOS app has the most commands, and it maps the names with no table.
- **The preset wins.** A displaced command loses its key, and the wrong command never runs. It is the rule macOS overrides already follow.
- **An id on Linux and Windows.** Neither has a per-key editor to fill or show a flattened copy, and a fix to a preset reaches users.

## Consequences

- Some TablePro commands have no key under some presets; each app pins them in a golden test per preset.
- The `derived` rows rest on the source's statement that Ctrl stands in for Cmd, not on a measurement, and may need fixes.
- A new action is a Rust enum case, rows in the file and a mapping in each app.
- The Linux app builds its shortcuts dialog itself so it lists the keys in force, so AdwApplication no longer loads it (amends Linux ADR 0015, Consequences).
- The macOS, release and shipped CI suites run when the file changes; Linux and Windows already run on any core change.

## Alternatives considered

- **The preset loses a contested key.** The user's key would run another command; the worst case runs every statement in the editor.
- **A fallback key for a displaced command.** Every fallback would be a key we invent, with its own collision checks on three platforms.
- **A `primary` modifier for Cmd or Ctrl.** A source's macOS keys are not always its other keys with Cmd for Ctrl.
- **Overrides written once on Linux and Windows.** Nothing shows or edits them, and a fixed preset would not reach users who chose it.
