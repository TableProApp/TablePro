# TablePro × macOS HIG Audit

**Status**: Audit complete (2026-05-01). Refactor pending.
**Scope**: Full audit of TablePro against Apple macOS Human Interface Guidelines.
**Goal**: Identify every incorrect/non-native pattern. Refactor in dev stage before public release.

## Why this audit

TablePro is a native macOS database client. CLAUDE.md commits to "native only — no cross-platform abstractions". A `Cmd+N` review on 2026-05-01 found:

- `Cmd+N` labeled "Manage Connections" — violates HIG "Cmd+N = New X"
- `CommandGroup(replacing: .newItem)` removes the default "New Window" entirely
- Behavior is `openOrFront()` (show window), not "create new"

If one shortcut is wrong, others likely are too. We're in dev stage. Fix it all now, not after release.

## Headline numbers

**174 findings** across 4 domains:

| Report | P0 | P1 | P2 | Total |
|--------|----|----|----|-------|
| [01 — Menus & Shortcuts](01-menus-shortcuts.md) | 13 | 30 | 27 | 70 |
| [02 — Windows & Interactions](02-windows-interactions.md) | 8 | 19 | 11 | 38 |
| [03 — Chrome & Visual](03-chrome-visual.md) | 18 | 17 | 7 | 42 |
| [04 — System & Document](04-system-document.md) | 7 | 11 | 6 | 24 |
| **Total** | **46** | **77** | **51** | **174** |

P0 = broken native contract (will trip native users immediately).
P1 = non-idiomatic (works, but not how Apple/competitors do it).
P2 = polish (label wording, ellipsis, separator placement).

## Cross-cutting themes

Findings cluster around 5 root issues. Fixing each one collapses many leaf items.

### T1 — No Apple document model

TablePro hand-rolls SQL-file editing on top of `QueryTab` + manual `NSWindow.representedURL`/`isDocumentEdited` wiring. No `NSDocument`, `FileDocument`, or `DocumentGroup`. This single gap causes:

- No Open Recent (01-File-menu, 04-system)
- No auto-save / Versions / Time Machine (04-system)
- No Revert / Duplicate / Rename / Move To… in File menu (01-File, 04-system)
- Custom quit-review alert reimplements `NSDocument` (04-system, `AppDelegate.swift:99`)
- "Save Changes" instead of "Save" (01-File)
- Cmd+W close logic that can produce empty windows (02-windows)

**Fix**: Adopt `FileDocument` for `.sql` files, route through `DocumentGroup`. Apple gives the rest for free.

### T2 — Keyboard shortcut sweep

Five system-shortcut conflicts and several semantic mismatches in `KeyboardShortcutModels.swift`:

- `Cmd+N` → "Manage Connections" (HIG: "New X")
- `Cmd+D` → "Save as Favorite" (HIG: "Duplicate")
- `Cmd+Y` → app action (system: Quick Look)
- `Cmd+Option+Delete` → app action (system: Empty Trash)
- `Cmd+Ctrl+C` → app action (system: Color Picker)
- `Cmd+L` → app action (system: URL bar focus; also collides with `Cmd+Shift+L = Format Query`)

Plus missing Find submenu (Cmd+G / Cmd+Shift+G / Use Selection / Jump), no Cmd+1…9 tab quick-jump, label inconsistencies ("Toggle X" vs "Show/Hide X").

**Fix**: One sweep PR: rebind conflicts, add Find submenu, normalize labels.

### T3 — Custom chrome where standard exists

Visual chrome reimplements native components 80+ times:

- 80 sites of `.font(.system(size:))` — none scale with Dynamic Type
- `WelcomeButtonStyle`, `KeyboardHint` badges, `TagBadgeView` capsules, custom inspector pills, custom popover selection backgrounds
- Welcome window hides traffic lights and standard title bar
- Hard-coded `.yellow` / `.pink` literals instead of `Color(nsColor: .systemYellow)`

**Fix**: Mechanical removal in favor of `.bordered` / `.borderless` / semantic colors / `ContentUnavailableView` / system List selection.

### T4 — Modal patterns are wrong

Sheets stack on sheets in Export, Import, DatabaseSwitcher, ConnectionForm. License activation is called as a sheet from 6 different places. Every sheet containing a `TextEditor` or long form has no `minWidth`/`minHeight`. Destructive alerts use `.defaultAction` Return shortcut.

**Fix**: License activation → standalone panel (one window, six triggers). Replace nested sheets with inline state or `NavigationStack` push. Add resize bounds to every sheet. Default-Cancel on destructive prompts.

### T5 — Settings architecture is dated

`SettingsView.swift` uses pre-Sonoma `TabView` toolbar with 9 tabs. macOS 14 standard (System Settings, Xcode 15, Notes) is `NavigationSplitView` with sidebar + detail.

**Fix**: Migrate `Settings { TabView { ... } }` → `Settings { NavigationSplitView { ... } }`.

## Recommended PR sequence

Order matters: T1 first because it kills 6+ P0s on its own. T2 is mechanical and unblocks a clean menu structure. T3-T5 can run in parallel after.

| # | PR | Theme | Effort | Kills | Notes |
|---|----|-------|--------|-------|-------|
| 1 | Adopt `FileDocument` + `DocumentGroup` for SQL files | T1 | L (multi-day) | ~6 P0, ~5 P1 | Foundation. Unlocks Open Recent, auto-save, Revert, quit-review for free. |
| 2 | Keyboard shortcut sweep (system conflicts + labels) | T2 | M | 6 P0, 8 P1 | Mostly mechanical. Touches `KeyboardShortcutModels.swift` + menu bindings. |
| 3 | Find submenu + Window menu completeness | T2 | S | 2 P0, 3 P1 | Add Cmd+G / Cmd+Shift+G / Cmd+E. Add "Show All Tabs", "Move Tab to New Window", "Merge All Windows". |
| 4 | Cmd+W close logic fix + tab close edge cases | T1/T2 | M | 1 P0 | Fix inverted single-tab close that produces empty windows. |
| 5 | Drop nested sheets across Export/Import/DB-switcher/ConnectionForm | T4 | L | 3 P0, 4 P1 | Cross-cutting. Each module needs its own refactor. |
| 6 | License activation → standalone `NSPanel` | T4 | M | 1 P0, 1 P1 | Six call sites today. One panel, six triggers. |
| 7 | Welcome window native chrome | T3 | M | 4 P0, 3 P1 | Restore title bar + traffic lights, drop `WelcomeButtonStyle`, drop `KeyboardHint`. |
| 8 | Typography sweep: 80 hard-coded sizes → semantic styles | T3 | M | 1 P0, 4 P1 | Mechanical, do per-folder. |
| 9 | Settings migration: `TabView` → `NavigationSplitView` | T5 | M | 1 P0, 2 P1 | Match macOS 14 System Settings. |
| 10 | Drop custom chrome: capsules, pills, KeyboardHint, TagBadgeView | T3 | M | 4 P0, 3 P1 | After PR 7 lands. |
| 11 | RightSidebar → Inspector (rename + restructure) | T3 | M | 2 P0, 2 P1 | Move mode picker, drop ALL CAPS section titles. |
| 12 | Sidebar filter search field + reduce min-width | T3 | S | 1 P0, 1 P1 | Add search above table list. |
| 13 | Empty states → `ContentUnavailableView` | T3 | M | 1 P0 | One pass across Welcome, Results, History, Editor placeholders. |
| 14 | Accessibility pass (icon-only labels, hints, reduce motion) | T3 | M | 3 P0, 1 P1 | Icon-only buttons need `.accessibilityLabel`. Welcome transition needs `accessibilityReduceMotion`. |
| 15 | Sheet sizing + destructive alert defaults | T4 | S | 2 P1 | Add `min/idealWidth` and `min/maxHeight` to sheets with editors. Set `hasDestructiveAction = true` everywhere. |
| 16 | Backspace vs forward Delete audit | T2 | S | 1 P1 | Replace `.onKeyPress(.delete)` with the `\u{7F}\u{08}` charset. |
| 17 | About panel: ship `Credits.rtf`, drop hand-built links | — | S | 1 P1 | Stop overriding `applicationDidFinishLaunching` for about. |
| 18 | Drag-out from data grid (TSV/HTML to clipboard/drag) | T4 | M | 1 P0 | Drop same-table-only check. |
| 19 | QuickSwitcher → floating panel; add Cmd+1…9 tab quick-jump | T2 | M | 1 P1 | Standalone panel anchored above key window. |
| 20 | Polish/P2 sweep | — | S | 51 P2 | Labels, ellipses, ALL CAPS, separator placement. Last. |

**Out of scope for this audit (separate decisions)**:
- Mac App Store / sandboxing (`ENABLE_APP_SANDBOX = NO`) — flagged in 04-system but is a parallel-project decision, not a refactor.
- Mac Catalyst / iOS — covered in iOS roadmap.
- `UNUserNotificationCenter` for query/sync events — flagged in 04-system, not blocking.
- Quick Look extension for `.sql` — nice-to-have, defer.

## Top 10 P0s by user-visible impact

If we shipped today, these are what an Apple-fluent user would notice in the first 30 minutes:

1. **Cmd+N opens "Manage Connections"** instead of creating something — `KeyboardShortcutModels.swift:460`, `TableProApp.swift:198`
2. **No Open Recent menu** — completely missing — `TableProApp.swift:204`
3. **No auto-save / no Revert / no Duplicate / no Rename / no Move To** — File menu is incomplete — `TableProApp.swift:204-256`
4. **Cmd+W can produce an empty window** — close logic inverted — `TabWindowController.swift`
5. **Cmd+D bound to "Save as Favorite", not "Duplicate"** — `KeyboardShortcutModels.swift`
6. **Cmd+Y / Cmd+Option+Delete / Cmd+Ctrl+C / Cmd+L collide with system shortcuts** — `KeyboardShortcutModels.swift`
7. **Welcome window has no traffic lights or standard title bar** — `WelcomeWindowFactory`
8. **80 hard-coded font sizes** — nothing scales with Dynamic Type — across `Views/`
9. **Sheets stack on sheets** — Export, Import, DatabaseSwitcher, ConnectionForm — multiple files in `Views/`
10. **Icon-only buttons missing `.accessibilityLabel`** — VoiceOver reads them as "Button" — across `Views/`

## How to use this document

- **Each PR**: pick one row from the sequence table. The detail file (`01`-`04`) has the exact `file:line` and fix.
- **Mark progress**: tick off rows in the sequence table as PRs land.
- **Don't bulk-merge**: each PR is bounded so review stays human-sized.
- **Don't drop P2s**: they're polish, but they accumulate. Schedule PR 20 for end-of-stream.

## Audit metadata

- Run on 2026-05-01 with 4 specialist agents in parallel: `menu-shortcut-auditor`, `window-interaction-auditor`, `chrome-visual-auditor`, `system-document-auditor`.
- Audit team: `~/.claude/teams/hig-audit/`. Task list: `~/.claude/tasks/hig-audit/`.
- Source pinned at branch `feat/raycast-integration`, commit `2f5b4f8e`.
- Auditors were read-only; no source files were modified during the audit.
