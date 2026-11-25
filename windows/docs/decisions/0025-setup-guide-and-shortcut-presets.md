# 0025: The setup guide and shortcut presets

- **Status**: Accepted
- **Date**: 2026-11-25

## Context

[0004](0004-app-shell.md) put four Get started cards on the Connections page while the library was empty, and its Commands and keys section fixed every key: the menu bar's in XAML, the editor's in a `switch`, labels and tooltips in the strings. Core [0051](../../../core/docs/decisions/0051-a-setup-guide-shows-on-an-empty-library.md) gives every app one setup guide, gate and handoff, and core [0052](../../../core/docs/decisions/0052-shortcut-presets-from-one-file.md) one file of shortcut presets. The maintainer fixed the Windows shape on 2026-11-24: the guide is a page in the window, it replaces the Get started cards, Skip lands on a smaller empty page with New connection and Set up, and Settings, Editor has the preset next to Vim mode.

## Decision

The guide is `SetupView`, swapped into `NavigationView.Content` as Settings is, over the `SetupGuide` model in `TablePro.App.Model`. The keys are `Keymap.Commands` in the same project, with the preset `AppSettings.ShortcutPreset` names laid over them by `Keymap.Resolve`, and the app sets every accelerator, menu label, tooltip and editor key from the result. This supersedes 0004's first run (Connections page, first bullet) and its Commands and keys section, and makes the key table of [0002](0002-sql-editor-control.md) (Input) the TablePro preset.

### The guide

- The gate is core 0051's Windows rows, `SetupGuide.ShouldShow`: the first snapshot the Connections page reads at launch, with no connection (groups ignored, the sample counted) and `AppSettings.SetupGuideSeen` false, while the Connections page is in front. A launch that restored a workspace or opened a file shows the work, not the guide, and writes nothing. Help, Setup guide and the empty page's Set up card open it whatever the library holds.
- Steps: clickable `SettingsCard`s for where the user comes from (another app, a connections file, a new connection), since cards are the commands there and the step has no Continue; the import step; New connection or the sample, recorded and run at the end; then theme, shortcut preset and Vim, which apply at once as Settings does. The TitleBar's back button goes back from the second step shown, and from a review back to the apps to tick. Skip sits on every step.
- On opening, `SetupGuide.ProbeAsync` asks the core for `ForeignScanDepth.Presence` on the thread pool. An app found within 2 seconds moves a guide still untouched on its first step to the import step; a later answer is dropped. Entering the import step reads the full inventory.
- The import step ticks what the core says starts ticked; each ticked app is read, reviewed and imported in turn by `ImportFromAppPanel`, the content the Import from another app dialog hosts too, and each read checks the library the import before it left. An app with nothing checked, or whose read failed, is passed with Continue.
- Finish and Skip mark the guide seen and run the recorded choice, else the ids the guide's imports wrote: one connects, several are checked on the Connections page in selection mode, none stays there. Several open the Connections section and every group above them, clear a search that hides one and scroll to the first (`LibraryTree.Reveal`); other folds stay. Leaving the page any other way marks it seen and runs nothing. Closing the window is quitting and writes nothing.
- Import from another app ends the same way on its own outcome's ids.
- A file never connects: what it wrote is checked on the Connections page, one connection included (`SetupGuide.Handoff` with `ImportSource.FileOrLink`). Anyone could have sent it, and a connect can sign in with the user's Windows account: one SQL Server entry on the sender's host with Kerberos and TLS verification off would hand it the user's NTLM response with no prompt. This covers:
  - A connections file: File, Import connections, the Connections page's Import from file and the guide's file card share `ImportAsync`.
  - An app read from an export the user picks (`ForeignSource.PicksFile`, Navicat's `.ncx`), in the Import from another app dialog and in the guide's queue. `ForeignImportEnding.Source` carries it, and one such connection among the guide's imports makes the guide's ending a selection.
- No other route writes a connection from a file or a link: a `tablepro://connect` link opens a saved one, a share link opens a query tab, a database URL fills the connection form, `tablepro://import` opens nothing ([0018](0018-links-files-notifications-type-editors-and-json.md)), and a file from Explorer opens as a database or a query, unsaved.
- The source lists show why a source cannot be read, from the core's `Unreadable` code, and preselect the core's `Preselected` source. Passwords start on wherever the core offers them; saved queries start on when offered and counted.

### Keys

- `Keymap.Commands` lists every key with its owner and scope: a menu accelerator, the editor's own key (it runs before any accelerator) or a fixed key. Fixed: Ctrl+Z, Y, X, C, V and A, the grid keys, Ctrl+1 to 9, Ctrl+Tab, Ctrl+Shift+Tab, Ctrl+F4, F1, F10 and Alt+F4. The editor holds the rest of its keys, read from `TablePro.Editor.Model` as its `KeyDown` reads them: `EditorKeymap.IsBuiltIn`, its caret and text box keys (Backspace, Delete, the arrows, Home, End, Page Up, Page Down, Escape and F3 with any modifiers), and `EditorKeymap.Default` for its text commands, which no preset moves, as macOS keeps them built in.
- A preset row for a command Windows has wins its key; another command in a scope one press can reach loses that key. Rows Windows refuses are dropped and their command keeps its key: Ctrl+Alt (AltGr in some languages), Alt with a letter or digit (access keys), a bare key, the Windows key, `` ` `` `[` `]` `\` `'` on a menu command (WinUI refuses them as accelerators), a key a fixed command holds, a key the editor holds on a command a press in the editor reaches (the `tableplus` preset's Ctrl+Shift+Backspace for Discard changes), and any row for a fixed command. Every Windows bare-key default is a fixed text box or grid key, so core 0052's second trigger for a bare key never applies here. `KeymapTests` holds the result per preset.
- Each window sets its menu items' `KeyboardAccelerator` objects from the effective table on construction and on every settings change, since one accelerator cannot sit on two elements. Every keyed item gets `KeyboardAcceleratorTextOverride` from the table, a space for none, because WinUI keeps an item's old text when its accelerator goes.
- The editor reads its commands through `EditorKeymap` (`SqlEditor.Keymap`, set by `DisplaySettings`); caret and text box keys stay in its switch. The Edit menu and the editor's context menu call `SqlEditor.Run(EditorCommand)`, not the key, which under a preset may run something else.
- Key words (Ctrl, Shift, Enter, the join) are strings; tooltips that name a moved key are `TipWithKeys` filled from the table, and the find bar answers Find and Replace wherever the preset put them.

## Rationale

- **A page, not a dialog or a window.** 0004 keeps one window, a ContentDialog caps its width and blocks the import sheet and the password prompt, and the Win32 wizard guide asks for page-based wizards.
- **The id, not a copy of the keys.** Nothing here edits a key one by one, and a fix to a preset reaches users who chose it.
- **The command, not the key.** Replaying Ctrl+F after a preset moved Find would run whatever Ctrl+F does now.

## Consequences

- Some commands have no key under some presets: New connection under Beekeeper Studio, Navicat and DBX.
- With Vim on, Normal mode still takes its own Ctrl keys first ([0017](0017-vim-mode.md)), preset keys included.
- The UI tests write `setupGuideSeen` into each data folder and open the sample from Help; `SetupGuideTests` walks the guide with a screenshot per step.

## Alternatives considered

- **Keep the Get started cards beside the guide.** The same commands on two surfaces.
- **Store the keys a preset gives.** No editor for them on Windows, and a fixed preset would not reach users.
- **Accelerators on the tab command bars.** A button's accelerator adds its key to the default tooltip, and the keys would be registered twice.
