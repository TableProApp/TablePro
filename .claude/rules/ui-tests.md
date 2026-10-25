---
paths:
  - "apple/TableProUITests/**/*"
  - "apple/TestPlans/UI.xctestplan"
---

# UI tests

The UI plan holds end-to-end flows only. Swift Testing rules, isolation and shared helpers are in `.claude/rules/tests.md`.

## What earns a UI flow

- A UI flow is an end-to-end user flow that runs deterministically. Everything else is a unit test, preferably on the real view in a window.
- The UI plan stays at 17 minutes or less on CI. A new flow has to fit in that budget.
- Verify a click, drag or focus behavior with XCUITest, never with synthetic `CGEvent`s posted into the user's session.

## The UI plan

- `apple/TestPlans/UI.xctestplan`: timeouts on, 180 s default and 300 s maximum per case, no code coverage, `retryOnFailure` with `maximumTestRepetitions` 2, so a failed case runs once more.
- A case that passed only on the retry is a flake. Fix it in the same PR, or open an issue for it. `verify.sh` lists it and CI annotates it (`.claude/skills/fix-issue/references/verification-apple.md`, Reading CI).
- The plan has no language keys: `launchApp` passes them as launch arguments.

## The harness

- Every suite subclasses `UITestCase` (`apple/TableProUITests/Support/UITestCase.swift`), the only launch path that names a sandbox. The SwiftLint rule `ui_test_base_class` fails `XCUIApplication()` or `: XCTestCase` anywhere else.
- The sandbox is one folder per checkout under `$TMPDIR/TableProUITests/`, recreated for each test. Teardown terminates every launched app before deleting it, because the app writes on the way down.
- `continueAfterFailure` is false. A failed test attaches each launched app's element tree as `element-tree-<n>`.
- An interruption monitor answers a system privacy alert, since XCTest's own handler misses macOS 26's local-network alert.
- `launchApp(environment:arguments:)` sets `TABLEPRO_UI_TESTING`, the sandbox variable, and `-AppleLanguages (en) -AppleLocale en_US`.
- A defaults override works only as a launch argument, never in `environment`: the argument domain is read first and never written. `-SUEnableAutomaticChecks YES` pins a Sparkle setting that way.
- `launchWithFixture` seeds a SQLite session on the six-table "Fixture" database (`UITestFixture`) and waits until the object browser lists something. A `TABLEPRO_UI_TEST_OPEN_*` variable in `environment` skips the session restore.
- `ConnectionSeed` defaults to the fixture SQL, Safe Mode `silent` and one `SELECT 1;` tab. A seed with `isOpen: false` is saved but never restored.
- Other launchers: `launchWithFixtureTable`, `launchWithDataFile`, `launchWithConnectionShare`, `launchOpeningURL`.

## Driving the app

- A command with a key equivalent: `typeShortcut(_:)` with an `AppShortcut` case. A menu click goes through XCUITest's menu traversal, which can stall 10 s.
- A command without one: `menuItem(_:under:in:)`, clicked without probing first, since resolving the item opens its menu. Database menu titles resolve under their menu; the SwiftLint rule `ui_menu_query_scope` fails `app.menuBars.menuItems[...]` for them.
- Never click an item low in a long menu. On the 1024x768 runner the menu scrolls under the pointer and the click lands on another item. Read `isEnabled` with the menu open, press Escape, then send the key equivalent.
- A contextual menu item: `contextMenuItem(_:in:)`, which takes the hittable match. Never match a contextual menu by identifier or with `app.menus.firstMatch`.
- Wait with `UITestPoll.until` or `waitToExist`, never `waitForExistence`, whose first check comes about a second late.
- Wait for `isHittable` (`waitUntilHittable`) before clicking in a pane that animates open. The element exists while it slides in, the click goes nowhere, and nothing fails until later. Assert the click's own result before what it renders.
- Scope every query to the window or sheet that owns the element. An app-rooted query walks the whole tree, which takes minutes beside a loaded grid, and can match a copy elsewhere: `app.buttons["OK"]` once matched the Touch Bar's. Windows and sheets are direct children, so use `window(_:in:)` or `children(matching:)`.
- A link-styled SwiftUI button is not in `buttons`. Query `descendants(matching: .any)` by identifier and wait on `isHittable`.
- A SwiftUI `Form` field has no title of its own. Give the leaf control an `.accessibilityIdentifier` and query that; the container rule is in `.claude/rules/ui-lifecycle.md`. Settings toggles are `Switch` elements, not checkboxes.
- The SQL editor's identifier sits on the SwiftUI wrapper and never reaches the text view: use `editorTextView(in:)`. `typeQuery(_:in:)` retypes until the text arrives, since keys typed before the editor installs its monitor are lost.
- Keyboard focus: `holdsKeyboardFocus(_:)`, never `hasFocus`, which raises through KVC.
- Scroll at a point inside the content, never the window, whose scroll lands on the title bar. `scrollUntilHittable(_:in:timeout:)` centres the element step by step.
- A synthesized scroll is not a trackpad gesture. Run a scroll test against the code before your fix once, to see it fail.
- A control in the results status bar can sit under the sidebar on the 1024 pt runner while its frame says otherwise. Switch result views from View > Result View: `showResultView(_:in:)`, `showData(in:window:)`, `showStructure(in:window:)`.

## The grid

- Every grid read and click goes through `FixtureGrid` (`cell`, `value`, `waitForValue`, `clickCell`, `editCell`, `clickHeader`) or `gridPoint(in:of:dy:)`.
- `dataGrid(in:)` matches the main table, `data-grid`, which publishes every column. The frozen pane laid over its leading edge, `data-grid-frozen`, is hidden from accessibility.
- `FixtureGrid` matches a cell by the identifier `data-grid-cell`, the leaf that carries the value, not the AXCell wrapper AppKit puts around it, and by the label `Row r, column c: `. Both count from 1: `r` is the row number on screen, page offset included, and `c` the column's display position, so hiding or moving a column renumbers the ones after it.
- A plain `clickHeader` sorts by that column alone and flips it on the next click; `clickHeader(_:modifiers: .option)` adds it as another key. A right-click opens the header or cell menu and never moves the selection.
- `FixtureFile.rows` and `FixtureFile.execute` read and write the fixture database directly, to set up or check data without the UI.
- Never call `click()` on a grid element. Rows and cells read as obscured by their columns, a row element has an empty frame so an offset click lands on the window's close button, and a header never becomes hittable. The app side is in `.claude/rules/data-grid.md`.
- A point offset from the grid measures from its top edge, above the header. Take `dy` from a row's frame (`row.frame.midY - grid.frame.minY`); a small constant hits the header and opens the column menu.
- `gridPoint` starts right of the object browser, which overlaps the grid on the 1024 pt runner.
- Wait for `waitForClickableRows(in:)` before a coordinate click. A grid enters the tree before its query returns, and a point taken off an empty frame posts at infinity.

## Known failures

- A flow that fails only on the CI runner, for a reason you cannot establish, gets `XCTExpectFailure` with the reason and an issue link, not a guessed fix. The other known-failure forms are in `.claude/rules/tests.md`.

## Running on this Mac

- The UI plan needs Automation Mode. When it is off, `verify.sh` reports INCONCLUSIVE; the remedy is in `.claude/skills/fix-issue/references/verification-apple.md`, INCONCLUSIVE.
- Never pass `CODE_SIGNING_ALLOWED=NO` to a local `build-for-testing` for the UI plan: macOS kills the unsigned runner before it connects. CI passes it and is fine.
- XCUITest cannot start while another TablePro is running: every case fails after a 60 s terminate timeout. Never quit the user's app. Record the run INCONCLUSIVE and let CI run it.

## Diagnosing

- Read the failed case's `element-tree-<n>` attachment first. Add `print(window.debugDescription)` for one diagnostic run only: on a loaded grid it costs minutes.
- CI evidence (the recording, synthesized events, element trees): `.claude/skills/fix-issue/references/verification-apple.md`, Reading CI.
