# 0026: The setup guide's hero and selectable cards

- **Status**: Accepted
- **Date**: 2026-11-25

## Context

[0025](0025-setup-guide-and-shortcut-presets.md) built the guide from `SettingsCard`s: clickable cards that were the commands on the first steps, a plain list of check boxes for the apps found, and a theme ComboBox. The maintainer judged it too classic on 2026-11-25 and asked every app for one composition: a hero per step, choices as cards with icons, the apps' own icons, "Step N of 4" and a prominent primary button. The flow, the `SetupGuide` model, the import and its handoff rules and the presets stay as 0025 has them.

## Decision

This supersedes 0025's Steps bullet ("cards are the commands there and the step has no Continue") and its probe bullet. The rest of 0025 stands.

- **Hero.** Each step opens with its art (the app icon on step 1, a symbol on steps 2 to 4), "Step N of 4" (`SetupStepLabel`), the title (`SetupTitle`) and one sentence. Step numbers are fixed: Origin 1, Import 2, First connection 3, Options 4, so a flow that skips a step shows the real index. The title is a polite live region named "{title}, step N of 4", and a step change moves the keyboard focus to the step's list. While an app is read or reviewed the hero is compact: that app's icon, the panel's title, no sentence.
- **Cards.** Every choice and every app is a `ListViewItem` in one style (`SetupCardItemStyle`): the card fill and stroke, 8 px corners, a 40 px icon column, a strong title and a secondary detail. Hover, pressed, selected, focus and the multi-select check box are the ListView's own; only its pointer-over and pressed brushes are set to the card fills, since the item draws them in place of its background.
- **Origin and First connection select.** A click selects a card and Continue commits it; a double tap on the selected card does both. Origin starts on Start fresh, and a selected card cannot be cleared, so Continue always has a target. On First connection, selecting records the choice at once, so Skip runs it.
- **The probe selects, never moves.** The guide always opens on Origin. Apps found within `SetupGuide.ProbeLimit` select Import from another app unless the user chose first (changed the card or pressed Continue), and its detail names them (`SetupFoundApps`); Continue goes on to Import (core 0057, Steps).
- **Import.** The apps found are a multi-select list, ticked as the core says; an app not on this PC is never a card and is named on one line under the cards, while an app that could not be read stays a card with its reason. The primary is Continue with nothing ticked, "Import n connections" when the ticked apps' counts add up to more than none, and Import otherwise.
- **App icons.** Read from the `DisplayIcon` of the app's Uninstall entry (per user, then per machine, both registry views), drawn by the shell at the card's size, cached per app; any failure keeps the glyph. No other app's icon ships with TablePro.
- **Options.** The app theme is a row of tiles, each a small window drawn with that theme's own brushes, the System tile half light and half dark; shortcuts and Vim stay `SettingsCard`s. The finish button names the ending: Open connection, Show connections, Add connection, Open sample or Done.
- **Motion.** A step change slides the column 28 px from the side the user is going and fades it in over 250 ms, and does nothing when Windows has animations off.

## Rationale

- **A selected card and one primary button.** The primary is always there, so every step reads the same and Tab always ends on it; with cards as commands the first step had none.
- **ListView items, not `SettingsCard`s.** Selection, multi-select check boxes, focus, Narrator's selection state and arrow keys come from the control. A `SettingsCard` has none of them.
- **The installer's icon.** The core has no icon for another app, and shipping one would be shipping that app's artwork.

## Consequences

- `SetupGuideTests` clicks `SetupPrimary` after each card.
- `SetupSource_{App}` exists only for apps on this PC; `SetupNotFound` names the rest.
- `SetupThemeBox` is the tile list, with `SetupTheme_Light`, `SetupTheme_Dark` and `SetupTheme_System`.

## Alternatives considered

- **`ItemsView` tiles for the apps, each opening its own review.** Imports would stop being one queue the user ticks once.
- **`PipsPager` or a stepper for the steps.** A pager for paged content, shown disabled as an indicator; "Step N of 4" says the same in words.
- **A centered hero.** Fluent left-aligns text in a page; the guide follows Settings.
