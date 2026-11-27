# 0028: Per-shortcut rebinding

- **Status**: Accepted; reverses the "id, not a copy of the keys" and "no per-key editor on Windows" parts of [0025](0025-setup-guide-and-shortcut-presets.md)
- **Date**: 2026-11-27

## Context

[0025](0025-setup-guide-and-shortcut-presets.md) gave Windows shortcut presets from the core ([core 0058](../../../core/docs/decisions/0058-shortcut-presets-from-one-file.md)) and recorded two decisions: store the preset id, not a copy of the keys, and ship no per-key editor. The macOS app has both a preset and a recorder that rebinds one command at a time, its customs in `KeyboardSettings` in UserDefaults; the core only ever serves presets. Windows now gets the recorder too.

## Decision

- **The customs live in the app, not the core.** `AppSettings.ShortcutOverrides` maps an action to a chord text (`ctrl+alt+r`), or `""` for a removed binding, through the existing `ModelJson` source-gen context into `settings.json`. The core adds nothing: it still serves presets only.
- **Precedence: overrides over preset over defaults.** `Keymap.Resolve(preset, overrides)` resolves the preset as before, then lays the overrides on top. An assigned chord wins its key and displaces any other movable command a press in its scope reaches; the cleared sentinel drops a command's key. A switch of preset re-resolves with the same overrides, so a custom stays put while every other key follows the new preset.
- **The recorder validates at record time with the same gates as the preset.** `Keymap.Classify` runs `RefusalOf` (the 0025 Win32 rules: Ctrl+Alt, Alt with a letter or digit, a bare non-function key, the menu-only punctuation, a key a Fixed command or the editor holds). A refused chord never stores, so a stored custom always round-trips through `EditorKey.VirtualKeyOf` and fires as a `KeyboardAccelerator`. A chord another command already holds returns `Reassign`, and the page asks before taking it, rather than letting `Resolve` displace it silently.
- **A page, not a dialog.** `KeyboardShortcutsView` is swapped into `NavigationView.Content` with a back affordance, as `SetupView` and Settings are (0025 rejects a dialog on width). Settings' shortcut card becomes a drill-in to it; the preset picker moves onto the page. `DisplaySettings` re-resolves on an override change as it does on a preset change, so the menus, tooltips and editor follow at once.

## Rationale

- **App-side, like macOS.** The customs are the user's and device-local; the core has no field for them and the storage round-trips through the existing settings file.
- **One set of gates.** Reusing the preset's refusals is the only way a recorded chord cannot become a shown-but-dead shortcut: WinUI has no app-global key monitor, so the recorder rides a focused control and must reject at record time what the accelerator layer would drop.

## Consequences

- A custom survives a preset switch; Restore defaults clears the customs and the keys fall back to the preset.
- `settings.json` carries a new `shortcutOverrides` object; an entry for an unknown or unbindable command is dropped by `Normalized`.

## Alternatives considered

- **Store the keys a preset gives and edit those.** 0025 rejected it: a fixed preset would not reach users, and it conflates two concerns. Overrides over a live preset keep both.
- **A ContentDialog editor.** 0025's width argument stands.
