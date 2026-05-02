# Chrome & Visual Audit (TablePro target)

**Scope**: toolbar, sidebar, inspector, controls, typography, color, dark mode, accessibility, iconography.
**Source baseline**: `feat/raycast-integration` @ 2026-05-01.
**Method**: read-only static review of `TablePro/Views/**`, `TablePro/Theme/**`, `TablePro/Core/Services/Infrastructure/MainWindowToolbar.swift`, `MainSplitViewController.swift`, `TabWindowController.swift`. Compared against macOS HIG and stock Apple apps (Finder, Mail, Notes, Xcode, System Settings, Music).

Findings ordered by severity. Single-line summary table at the end.

---

## P0 — Broken native contract

### [P0] Hard-coded `font(.system(size: …))` everywhere instead of system text styles
- **File**: 80 occurrences across `TablePro/Views/`. Hottest spots: `Views/RightSidebar/EditableFieldView.swift:94,98,109,118`, `Views/RightSidebar/FieldEditors/JsonEditorView.swift:23,34`, `Views/RightSidebar/FieldEditors/BlobHexEditorView.swift:25,36,56,62`, `Views/Connection/WelcomeWindowView.swift:373,408,517`, `Views/Connection/WelcomeConnectionRow.swift:22,37,48`, `Views/Connection/WelcomeLeftPanel.swift:24`, `Views/Settings/AISettingsView.swift:165`, `Views/Settings/LinkedFoldersSection.swift:132`, `Views/Settings/ThemePreviewCard.swift:53`, `Views/Toolbar/ConnectionSwitcherPopover.swift:213,218,229,238`, `Views/Sidebar/FavoriteRowView.swift:15,27`, `Views/Connection/ConnectionSidebarHeader.swift:95,99,121`.
- **Current**: Sizes are pinned to absolute points (often `.system(size: 9)`, `.system(size: 11)`, `.system(size: 32)`, `.system(size: 24, weight: .semibold)`). Many of these clusters are inspector field labels and badges sized at 9 pt — below the macOS minimum readable size, and they do not scale with the user's system text size or accessibility "Larger Text" pref.
- **HIG says**: "Use system fonts and built-in text styles whenever possible" and "Support Dynamic Type." Prefer semantic styles (`.body`, `.callout`, `.caption`, `.caption2`, `.subheadline`, `.headline`, `.title`, `.title3`) so text scales with the user's preferred reading size and matches the rest of the OS. Direct point sizes are reserved for very narrow cases (e.g. art-directed empty-state hero icons).
- **Native examples**: Mail, Notes, Xcode, Finder all render row text at `.body` / `.subheadline` and headers at `.headline`; nothing in stock chrome uses 9 pt text.
- **Fix**: Replace `.font(.system(size: 9))` etc. with semantic styles. Mapping: `9` → `.caption2`, `10–11` → `.caption`, `12–13` → `.subheadline` or `.callout`, `14–16` → `.body`, `17+` → `.title3`/`.title2`. For badge text use `.caption2.weight(.medium)`. Hero icons in empty states are fine as `.system(size: 32)` only when paired with Apple's own `ContentUnavailableView` (which already uses 32 pt). Audit each call: most can drop the explicit size entirely.
- **Effort**: M

### [P0] Inspector pane labelled "Inspector" but built as a second sidebar with full custom chrome
- **File**: `TablePro/Core/Services/Infrastructure/MainSplitViewController.swift:133-138`, `TablePro/Views/RightSidebar/UnifiedRightPanelView.swift:30-67`, `TablePro/Views/RightSidebar/RightSidebarView.swift`.
- **Current**: The right pane is correctly created with `NSSplitViewItem(inspectorWithViewController:)` (good — that gives the right vibrancy). But the content view starts with a custom `Picker(.segmented)` "Details / AI Chat" tab strip at the top inside the pane (`UnifiedRightPanelView.swift:33-40`). HIG inspectors place mode pickers in the toolbar above the pane, not inside it. The folder name `Views/RightSidebar/` and the type name `RightSidebarView` also encode the wrong mental model — it is an inspector, not a second sidebar.
- **HIG says**: "Inspectors" — "Place an inspector on the trailing side of the window. People can show or hide an inspector to display additional details about an item." Mode switches for an inspector belong on the inspector toolbar accessory, mirroring Xcode (File / History / Quick Help) and Pages (Format / Document).
- **Native examples**: Xcode inspector tab strip lives in the inspector toolbar accessory above the divider. Pages, Numbers, Keynote put the Format/Document switcher in the toolbar above the inspector pane. Finder's Get Info inspector has no inline mode picker.
- **Fix**: Move the Details / AI Chat segmented control out of `UnifiedRightPanelView.body` and into a `NSToolbarItem` in `MainWindowToolbar.swift` aligned over the inspector pane (use `inspectorTrackingSeparator` and place the picker after it). Rename `Views/RightSidebar/` → `Views/Inspector/`, `RightSidebarView` → `InspectorView`, `UnifiedRightPanelView` → `InspectorContentView`, `RightPanelState` → `InspectorState`. Constants like `com.TablePro.rightPanel.isPresented` (`MainSplitViewController.swift:468`) → `com.TablePro.inspector.isPresented` (use a migration read of the old key one time so user state is preserved).
- **Effort**: M

### [P0] Welcome window hides title bar and clears window background — non-standard chrome
- **File**: `TablePro/Core/Services/Infrastructure/WelcomeWindowFactory.swift:42-48`.
- **Current**: `styleMask = [.titled, .closable, .fullSizeContentView]`, `titleVisibility = .hidden`, `titlebarAppearsTransparent = true`, `isOpaque = false`, `backgroundColor = .clear`, miniaturize and zoom buttons hidden. The result is a frameless, non-zoomable window — Cmd+M and the green button are gone, and the title bar is invisible to drag/double-click-to-zoom. The view itself draws `.background(.background)` (`WelcomeWindowView.swift:34`), so the transparent NSWindow background is doing nothing useful.
- **HIG says**: macOS windows have standard title bars and the standard traffic-light cluster. Hiding the zoom and minimize buttons is reserved for modal panels (sheets, settings, alerts). A welcome window is a regular window — Apple's stock Welcome to Xcode and Welcome to Numbers both have a normal title bar and the full close-min-zoom triplet (zoom is disabled, not hidden, on Welcome to Xcode).
- **Native examples**: Welcome to Xcode, Welcome to Pages, Welcome to Numbers — standard title bar, full traffic-light triplet.
- **Fix**: Remove `titleVisibility = .hidden`, `titlebarAppearsTransparent = true`, `isOpaque = false`, `backgroundColor = .clear`, and the two `standardWindowButton(_:)?.isHidden = true` lines. Keep `.fullSizeContentView` only if the design genuinely extends content under the title bar; otherwise drop it too. Set a real `window.title` (`String(localized: "Welcome to TablePro")` is already there).
- **Effort**: S

### [P0] Custom `WelcomeButtonStyle` rolls its own bordered button look
- **File**: `TablePro/Views/Connection/WelcomeLeftPanel.swift:91-107`.
- **Current**: `WelcomeButtonStyle` builds a `RoundedRectangle(cornerRadius: 8)` filled with `Color(nsColor: .controlBackgroundColor)` (or `.quaternaryLabelColor` when pressed), 16/12 padding, leading-aligned. This is a re-implementation of `.bordered` / `.borderedProminent` with non-standard pressed states (controls normally darken, not switch background colors).
- **HIG says**: "Buttons" — use system button styles (`.bordered`, `.borderedProminent`, `.borderless`, `.plain`, `.link`). Stock buttons get pressed-state animation, focus ring, accent color, accessibility behavior, and dark-mode treatment for free.
- **Native examples**: Welcome to Xcode "Create New Project / Clone Repository / Open Existing Project" rows use stock `.bordered` `.controlSize(.large)` buttons. System Settings sidebar entries use stock `NSTableView` selection.
- **Fix**: Delete `WelcomeButtonStyle`. Replace `.buttonStyle(WelcomeButtonStyle())` with `.buttonStyle(.bordered)` `.controlSize(.large)`, leading-align with `.frame(maxWidth: .infinity, alignment: .leading)`. If the design needs the asymmetric padding, file it as a P2 polish ticket — most likely the stock control covers it.
- **Effort**: S

### [P0] `KeyboardHint` builds custom kbd badges instead of using `Text(verbatim:)` with the system pattern
- **File**: `TablePro/Views/Connection/WelcomeLeftPanel.swift:109-128`.
- **Current**: Wraps "⌘N" inside a `RoundedRectangle(cornerRadius: 3)` filled with `.quaternaryLabelColor`. macOS does not draw keyboard shortcut "kbd" pills anywhere in the system — shortcuts in menus are drawn as plain text in the trailing column, and inline shortcuts in tooltips/help are plain text.
- **HIG says**: "Keyboard shortcuts" — show shortcuts with the standard symbol glyphs, in a regular tooltip, status bar, or as the trailing menu accessory. macOS does not use shortcut badges as decorative chrome.
- **Native examples**: Notes "Pinned ⌘P" banner is plain text. Spotlight footer is plain text. Quick Look footer is plain text.
- **Fix**: Drop the rounded rectangle background. Render as `Text("⌘N").font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)` followed by the label. Better: replace the entire bottom strip with the standard Welcome window pattern — a footer line of plain affordances ("Show this window when TablePro starts" toggle is what stock Apple welcome windows use).
- **Effort**: S

### [P0] `TagBadgeView` renders its own capsule pill in the toolbar
- **File**: `TablePro/Views/Toolbar/TagBadgeView.swift:21-35`.
- **Current**: `Text(name).font(.subheadline.weight(.medium)).padding(8/4).background(Capsule().fill(tag.color.color.opacity(0.2)))`. Lives in the principal toolbar item and competes visually with the connection name and DB version. Capsule chrome is not a system pattern in NSToolbar.
- **HIG says**: "Toolbars" — keep items concise and visually consistent. Use the toolbar's title/subtitle, the principal item, or a `.bordered` button. Decorative tinted pills do not appear in stock toolbars.
- **Native examples**: Xcode toolbar shows scheme + run destination as plain text + chevron. Mail toolbar shows mailbox name as title. None paint a colored pill behind status text.
- **Fix**: For `production`-style emphasis, use the existing principal item's window subtitle (`window.subtitle = …`, already wired in `MainSplitViewController.swift:165`) or a small `Image(systemName:)` glyph. If a colored marker is essential, render a 6 pt `Circle().fill(tag.color)` adjacent to the connection name — that mirrors the Finder tag dot and the connection list dot already used in `ConnectionSwitcherPopover`.
- **Effort**: S

### [P0] Inspector field rows use Capsule pills with hard-coded systemOrange "truncated" badge
- **File**: `TablePro/Views/RightSidebar/EditableFieldView.swift:108-124`.
- **Current**: Type badge `Text(...).font(.system(size: 9, weight: .medium)).background(.quaternary).clipShape(Capsule())` and a "truncated" badge with `.foregroundStyle(Color(nsColor: .systemOrange))` plus 15% systemOrange background. 9 pt is below readable size and not a HIG style.
- **HIG says**: Use `.caption` / `.caption2` semantic styles. For status indicators that need color, use SF Symbols with semantic foregroundStyle (`.tint`, system colors via SwiftUI not NSColor).
- **Native examples**: Xcode build log uses `Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)` next to plain text. Calendar uses small dots, not pills, for tags.
- **Fix**: Replace `font(.system(size: 9, weight: .medium))` with `.font(.caption2.weight(.medium))`. Replace the orange capsule with a leading `Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)` glyph + plain text. Apply the same treatment to the type badge — drop the capsule and render `.foregroundStyle(.tertiary)` text.
- **Effort**: S

### [P0] `ConnectionSwitcherPopover` rolls its own keyboard-driven list selection
- **File**: `TablePro/Views/Toolbar/ConnectionSwitcherPopover.swift:46-180`.
- **Current**: Manual `selectedIndex: Int`, manual `listRowBackground(RoundedRectangle.fill(Color(nsColor: .selectedContentBackgroundColor)))` for the focused row, manual onKeyPress handlers for ↑/↓/Enter/Esc/Ctrl-J/Ctrl-K. The List is `.listStyle(.sidebar)` but is being rendered inside a popover, where it does not get sidebar vibrancy.
- **HIG says**: Use the system `List(selection:)` binding for keyboard-driven selection. The system manages focus ring, selection background color (light/dark/high-contrast), full keyboard access, and announces row changes to VoiceOver.
- **Native examples**: Spotlight, Raycast (which mirrors Spotlight), Xcode "Open Quickly", System Settings sidebar all use system list selection — none paint their own selection rectangle.
- **Fix**: Switch to `List(selection: $selectedConnectionId)` + `.onKeyPress(.return) { /* connect */ }`. Remove the `listRowBackground` override and `selectedIndex` state. Use `.listStyle(.inset)` (`.sidebar` is wrong inside a popover). Rows become regular `Button { ... } label: { connectionRow(...) }.buttonStyle(.borderless)`.
- **Effort**: M

### [P0] `ConnectionSwitcherPopover` uses non-semantic `alternateSelectedControlTextColor` for highlighted-row text
- **File**: `TablePro/Views/Toolbar/ConnectionSwitcherPopover.swift:207, 214, 219, 228, 232, 238, 244`.
- **Current**: Every text/icon inside the row branches on `isHighlighted` and substitutes `Color(nsColor: .alternateSelectedControlTextColor)` for foreground. This works for default selection background but breaks under high-contrast and accent color changes (e.g. system accent set to multicolor or a light accent on dark mode).
- **HIG says**: Let SwiftUI/system handle selected-row foregroundStyle. `List` flips foreground to selected-text automatically when a row is selected.
- **Native examples**: Stock List rows show foreground inversion automatically — no app branches on `isHighlighted` to flip text color.
- **Fix**: Once the manual selection is replaced (see previous finding), drop all `isHighlighted ? Color(nsColor: .alternateSelectedControlTextColor) : .primary/.secondary` branches. Plain `.primary` / `.secondary` will invert correctly under selection.
- **Effort**: S (folds into the previous fix)

### [P0] No `Customize Toolbar…` menu item even though user customization is allowed
- **File**: `TablePro/Core/Services/Infrastructure/MainWindowToolbar.swift:53` (`allowsUserCustomization = true`); `TablePro/TableProApp.swift` View menu has no Customize Toolbar entry.
- **Current**: `allowsUserCustomization = true` on the NSToolbar, so right-click → Customize Toolbar works. But there is no `View > Customize Toolbar…` menu item, which is the stock entry point users look for.
- **HIG says**: "Toolbars" — when a toolbar is customizable, expose a Customize Toolbar… item in the View menu.
- **Native examples**: Mail, Finder, Safari, Xcode all expose `View > Customize Toolbar…`.
- **Fix**: Add `Button("Customize Toolbar…") { NSApp.sendAction(#selector(NSWindow.runToolbarCustomizationPalette(_:)), to: nil, from: nil) }` to the `CommandGroup(after: .sidebar)` block in `TableProApp.swift:460-541`. No keyboard shortcut (Apple does not assign one).
- **Effort**: S

### [P0] Toolbar shows icon-only by default but no `displayMode` preference; users cannot switch to icon+label
- **File**: `TablePro/Core/Services/Infrastructure/MainWindowToolbar.swift:52`.
- **Current**: `managedToolbar.displayMode = .iconOnly` — fixed. Combined with `autosavesConfiguration = false` (line 54), users cannot persist a different choice. The customization palette still offers Icon Only / Icon and Text / Text Only, but selections are dropped on next launch.
- **HIG says**: Toolbars must persist user customizations. A toolbar that does not autosave is a hostile pattern — repeated re-customization is required after every relaunch.
- **Native examples**: Mail, Finder, Xcode toolbars all autosave display mode and item arrangement.
- **Fix**: `autosavesConfiguration = true`. Drop the explicit `displayMode = .iconOnly` (use the default which respects user pref) or move it behind a one-time "first run" default applied through UserDefaults. Verify that the per-window-instance unique identifier (`NSToolbar(identifier: "com.TablePro.main.toolbar.\(UUID())")`) is intentional — autosave with a per-instance UUID will not persist; if autosave is desired, switch to a stable identifier and address the tab-group sharing issue noted in the comment at lines 47-49 differently (e.g. a single toolbar config shared by all tab windows is what stock apps do).
- **Effort**: M

### [P0] Sidebar list uses `.listStyle(.sidebar)` but search field lives outside the sidebar's vibrancy region
- **File**: `TablePro/Views/Sidebar/SidebarView.swift:183-241` (List), search field is in `MainSplitViewController.swift:120` via `SidebarContainerViewController`.
- **Current**: SidebarContainerViewController wraps the SwiftUI List inside an NSSplitViewItem(sidebarWithViewController:), which gives correct sidebar vibrancy. But there is no search field in the sidebar itself — connection-list search lives in the Welcome window. In-sidebar search affordance ("Filter tables") is missing entirely; the only filter input on the inspector field list (`RightSidebarView.swift:220-226`) uses `NativeSearchField` (good).
- **HIG says**: "Sidebars" — for table-of-contents sidebars (Mail mailboxes, Xcode navigators, Finder), a search/filter field at the top of the sidebar is the established pattern when the list can grow long. With dozens-to-hundreds of tables in a typical schema, this is needed.
- **Native examples**: Xcode Project navigator has a filter field at the bottom. Mail has search at the top. Finder doesn't use one for sidebar but Xcode is the closer analogue.
- **Fix**: Add a `NativeSearchField` at the top of the sidebar's List inside `SidebarView.tablesContent`, bound to `viewModel.searchText` (already exists in the view model — only the input field is missing in the in-window sidebar). Match the Welcome window's search field control size.
- **Effort**: S

### [P0] Settings layout uses `TabView` (legacy macOS 12 pattern), not the modern System Settings sidebar style
- **File**: `TablePro/Views/Settings/SettingsView.swift:18-65`.
- **Current**: `TabView` with 9 `tabItem`s (General, Appearance, Editor, Keyboard, AI, Terminal, Integrations, Plugins, Account). Renders the macOS 12-style horizontal tab strip across the top of the Preferences window. Frame fixed at 720×500.
- **HIG says**: macOS 14+ recommends the System Settings pattern: `NavigationSplitView` with sidebar of categories on the left and the active section on the right, `formStyle(.grouped)`, scrollable content. Apple converted every first-party app to this pattern in the macOS Sonoma cycle.
- **Native examples**: System Settings (Sonoma+), Xcode Settings (15+), Notes Settings, Mail Settings, Reminders Settings — all use sidebar + detail. None ship the horizontal tab bar anymore.
- **Fix**: Convert `SettingsView` to `NavigationSplitView { List(selection: $selectedTab) { … } } detail: { switch selectedTab { … } }`. Each tab becomes a sidebar row with `Label("General", systemImage: "gearshape")`. Drop the fixed 720×500 frame (System Settings windows are resizable). Inner section views already use `Form().formStyle(.grouped)` (see `GeneralSettingsView.swift:30, 95`) so they drop in unchanged.
- **Effort**: M

### [P0] Settings tabs use `.font(.system(size: 32))` empty-state hero icons across multiple panes
- **File**: `Views/Settings/LicenseActivationSheet.swift:22`, `Views/Settings/Sections/MCPAuditLogView.swift:81`, `Views/Settings/Plugins/InstalledPluginsView.swift:297`, `Views/Settings/Plugins/BrowsePluginsView.swift:232`, `Views/Connection/OnboardingContentView.swift:153`, `Views/Connection/ConnectionImportSheet.swift:64,125`, `Views/Connection/ImportFromApp/ImportFromAppSheet.swift:65`, `Views/DatabaseSwitcher/DropDatabaseSheet.swift:26`.
- **Current**: Multiple settings/sheet panes hand-roll the empty state pattern with hard-coded 32 pt SF Symbols + secondary text + tertiary description.
- **HIG says**: macOS 14+ ships `ContentUnavailableView` (and `ContentUnavailableView.search`). It scales correctly with Dynamic Type, supports the standard description+actions layout, and is what stock apps now use for empty states.
- **Native examples**: Photos "No Photos in Library", Mail "No Mailbox Selected", Notes "No Notes" — all `ContentUnavailableView`. `SidebarView.swift:160-174` already uses `ContentUnavailableView` correctly; settings/sheets did not get the same treatment.
- **Fix**: Replace each ad-hoc empty state with `ContentUnavailableView(label, systemImage:, description:)`. Drop the manual VStack + `.font(.system(size: 32))` pattern.
- **Effort**: M

### [P0] App appearance picker still custom-rolled instead of using `Picker(.segmented)`
- **File**: `TablePro/Views/Settings/AppearanceSettingsView.swift:60-65`.
- **Current**: Uses `.pickerStyle(.segmented)` which is correct, but at the top of the Appearance pane outside any Form. Modern System Settings puts the Appearance toggle in the General pane via `Picker` with the three-image `Light / Dark / Auto` row inside a Form section — the segmented placement at the top of an HSplitView is non-standard.
- **HIG says**: "Pickers" — group settings inside a `Form` so they pick up the standard inset list look in Settings.
- **Native examples**: System Settings → Appearance: three-image picker in a Form section.
- **Fix**: After `SettingsView` is migrated to `NavigationSplitView` (previous P0), put the appearance picker inside a `Section` of a `Form().formStyle(.grouped)` rather than free-floating above an `HSplitView`.
- **Effort**: S

### [P0] `.help(...)` strings duplicated as `.accessibilityLabel(...)` on icon-only toolbar/sidebar buttons; many icon-only buttons have NO `.accessibilityLabel`
- **File**: `Views/Toolbar/SafeModeBadgeView.swift:27-28` (good — both set), `Views/Toolbar/TagBadgeView.swift:33-34` (good). `Views/Sidebar/RedisKeyTreeView.swift:84,100` (no accessibilityLabel), `Views/Settings/AISettingsView.swift:126` (no accessibilityLabel), `Views/Settings/LinkedFoldersSection.swift:91` (no accessibilityLabel), `Views/Connection/ConnectionColorPicker.swift:23` (no accessibilityLabel), `Views/Connection/ConnectionTagEditor.swift:199` (no accessibilityLabel), `Views/Results/ResultTabBar.swift:49,60` (no accessibilityLabel), `Views/Connection/WelcomeWindowView.swift:186-210` (good — both set). Toolbar buttons in `MainWindowToolbar.swift` rely solely on `.help(...)` — VoiceOver does NOT read `.help`; it reads `.accessibilityLabel`.
- **Current**: 23 `Image(systemName:)` invocations across `Toolbar/`, `Sidebar/`, `RightSidebar/` plus many more in main views. Buttons using `.buttonStyle(.plain)` with bare `Image` labels render as icons-only and need an explicit `.accessibilityLabel`.
- **HIG says**: "Accessibility" — every interactive element must announce itself to VoiceOver. `.help()` is the tooltip text, not the accessibility label. They are separate properties (and on many SF Symbol-only buttons should match).
- **Native examples**: Mail toolbar buttons (Reply, Forward, Move) all have `accessibilityLabel` — verifiable via VoiceOver in Mail.
- **Fix**: Mechanical pass: every `Button { … } label: { Image(systemName: …) }` or every Label-based icon-only `Button` needs `.accessibilityLabel(String(localized: "…"))`. Where help text already exists, the same string usually works. `MainWindowToolbar.swift` toolbar buttons render via `Label("Refresh", systemImage:)` so SwiftUI synthesizes a label from the title — those are OK. The popovers and inline plain buttons are not.
- **Effort**: M

### [P0] `Image` glyphs lack `.accessibilityHidden(true)` when label text fully describes the row
- **File**: `Views/Sidebar/FavoriteRowView.swift:14-30` is correct (`.accessibilityHidden(true)` on the star, globe, keyword glyphs and `.accessibilityElement(children: .combine)` on the row). Most other rows do NOT do this, e.g. `Views/Connection/WelcomeConnectionRow.swift:20-50` (no `.accessibilityElement(children: .combine)`, status icons not hidden), `Views/Toolbar/ConnectionSwitcherPopover.swift:206-249`, `Views/Toolbar/ConnectionStatusView.swift:74-83`.
- **Current**: VoiceOver navigates through every glyph in a row separately ("image, image, MySQL Local, image, …") instead of reading the row as a single labelled element.
- **HIG says**: "Accessibility" — combine decorative children into one element with a meaningful label.
- **Native examples**: Mail account rows announce as a single sentence ("iCloud, 17 unread messages, account").
- **Fix**: Wrap row content in `.accessibilityElement(children: .combine)` and mark decorative glyphs `.accessibilityHidden(true)`. Apply systematically across `WelcomeConnectionRow`, the row builder in `ConnectionSwitcherPopover.connectionRow`, `ConnectionStatusView.databaseNameLabel`, `ConnectionSidebarHeader`.
- **Effort**: M

### [P0] No respect for `accessibilityReduceMotion` on the welcome window's onboarding transition
- **File**: `TablePro/Views/Connection/WelcomeWindowView.swift:23-32`.
- **Current**: `withAnimation(.easeInOut(duration: 0.45)) { vm.showOnboarding = false }` plus `.transition(.move(edge: .leading))` / `.transition(.move(edge: .trailing))`. Always animates regardless of system Reduce Motion preference.
- **HIG says**: "Accessibility — Motion" — respect `Reduce Motion` and either replace slide/move with cross-fade or skip the transition entirely.
- **Native examples**: System Settings, Mail message list animations all check Reduce Motion before doing horizontal slides.
- **Fix**: `@Environment(\.accessibilityReduceMotion) private var reduceMotion` then `withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.45))`. Or use `.transition(reduceMotion ? .opacity : .move(edge: .leading))`.
- **Effort**: S

---

## P1 — Non-idiomatic

### [P1] `ConnectionStatusView` ignores the user-selected accent color for tag badges and DB type text
- **File**: `TablePro/Views/Toolbar/ConnectionStatusView.swift:42-83`.
- **Current**: Database info uses `ThemeEngine.shared.colors.toolbar.secondaryTextSwiftUI` rather than `.secondary`. The custom theme system overlays user-defined colors over what should be system semantic colors in chrome. Chrome (toolbar text, sidebar text) should track the system, not a per-theme override — themes are meaningful for the editor and data grid only.
- **HIG says**: Toolbars and sidebars use system label colors (`.primary`, `.secondary`, `.tertiary`, `.quaternary`) so they participate in the user's accent color choice and high-contrast pref.
- **Native examples**: Xcode allows editor themes but its toolbar/sidebar always use system colors.
- **Fix**: Replace `ThemeEngine.shared.colors.toolbar.secondaryTextSwiftUI` with `.secondary` and `tertiaryTextSwiftUI` with `.tertiary`. Drop the `ToolbarThemeColors` struct from `ThemeColors.swift:387-407` once unreferenced. Restrict `ThemeEngine` to editor + data grid colors.
- **Effort**: S

### [P1] `ExecutionIndicatorView` shows "--" placeholder text in toolbar when no query has run
- **File**: `TablePro/Views/Toolbar/ExecutionIndicatorView.swift:57-63`.
- **Current**: Static "--" rendered when `lastDuration == nil`, taking up width permanently.
- **HIG says**: Toolbars should not display empty placeholder content. If there's nothing to show, the item should be hidden or absent.
- **Native examples**: Xcode's progress indicator only appears during a build.
- **Fix**: Render `EmptyView()` (or simply `nil`) when `!isExecuting && lastDuration == nil && lastClickHouseProgress == nil`. The toolbar item width adjusts naturally.
- **Effort**: S

### [P1] `Form` pickers in settings re-declare `.pickerStyle(.menu)` instead of inheriting Form's default
- **File**: `Views/Settings/AISettingsView.swift:106, 262`.
- **Current**: Explicit `.pickerStyle(.menu)` set on Pickers inside a `Form().formStyle(.grouped)`. `.grouped` Forms already render Pickers as menu-style — the override is a no-op now and could mismatch Apple's Settings updates later.
- **HIG says**: Use Form defaults; let the form pick the right control style for the current style and platform.
- **Fix**: Remove `.pickerStyle(.menu)` calls inside `formStyle(.grouped)` Forms. Only override when the visual is intentionally different (e.g. `.segmented` for an inline 2-3-option binary choice).
- **Effort**: S

### [P1] `.font(.system(.subheadline, design: .monospaced))` mixed with semantic styles in toolbar
- **File**: `Views/Toolbar/ConnectionStatusView.swift:44`, `Views/Toolbar/ExecutionIndicatorView.swift:27, 31, 45, 51, 59`.
- **Current**: Database type/version + execution time use `.system(.subheadline, design: .monospaced)`. The tabular-figures-via-monospace approach is fine for changing numbers (execution duration) but applying it to "MySQL 8.0.35" in `ConnectionStatusView` looks like a debug HUD, not toolbar text.
- **HIG says**: Toolbars use system font with proportional digits unless live-updating numeric values benefit from monospaced digits. Use `.monospacedDigit()` for numbers, full `.monospaced` only for code-like content.
- **Native examples**: Xcode shows scheme name in proportional font, build progress numbers in monospaced digits via `.monospacedDigit()`.
- **Fix**: `ConnectionStatusView.databaseInfoSection`: drop `.monospaced`, use plain `.subheadline`. `ExecutionIndicatorView`: replace `.system(.subheadline, design: .monospaced).weight(.regular)` with `.subheadline.monospacedDigit()`.
- **Effort**: S

### [P1] Hard-coded sidebar / inspector min/max widths
- **File**: `TablePro/Core/Services/Infrastructure/MainSplitViewController.swift:122-138`.
- **Current**: `sidebarSplitItem.minimumThickness = 280`, `maximumThickness = 600`. `inspectorSplitItem.minimumThickness = 270`, `maximumThickness = 400`. The 280 sidebar minimum is large — Mail's mailbox sidebar can compress to 150 and Xcode's to 180. With long table names this is fine, but on smaller windows it eats too much detail width.
- **HIG says**: "Sidebars" — minimum widths around 150-200 are typical; 280 is unusually large.
- **Fix**: Drop minimums to 200/220 and let the user resize. Inspector minimum 270 is reasonable for the field editors but reconsider after the field-row design pass.
- **Effort**: S

### [P1] Tag color badges in `WelcomeConnectionRow` use opacity-tinted rounded rectangle instead of system tag chip
- **File**: `TablePro/Views/Connection/WelcomeConnectionRow.swift:35-44`.
- **Current**: 9 pt text in a `RoundedRectangle(cornerRadius: 4).fill(tag.color.color.opacity(0.15))`. Both the size and the styling violate HIG.
- **HIG says**: For inline metadata in a list row, use semantic foregroundStyle (just colored text) or a 6-8 pt `Circle().fill(tag.color)` like Finder tags.
- **Native examples**: Finder tag dots in list view, Xcode's color labels in the source navigator (small color indicator + plain text label).
- **Fix**: Drop the rectangle background. Render as `HStack(spacing: 4) { Circle().fill(tag.color.color).frame(width: 6, height: 6); Text(tag.name).font(.caption).foregroundStyle(.secondary) }`.
- **Effort**: S

### [P1] `ConnectionSidebarHeader` button-as-menu uses bespoke chevron and 16 pt icon
- **File**: `TablePro/Views/Connection/ConnectionSidebarHeader.swift:89-129`.
- **Current**: A custom button-shaped row with `Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))`, `.buttonStyle(.plain)`, no `MenuStyle`. Behaves like `Menu` content but does not render as one.
- **HIG says**: Use `Menu { ... } label: { ... }` for popup menus. macOS draws the standard menu chevron and applies the proper press / hover states.
- **Native examples**: Mail "All Inboxes" header is a regular static label. Xcode scheme picker is `Menu` with default chrome.
- **Fix**: This view is currently unused (sidebar uses search/list, not a connection header) — verify with grep and delete. If kept, replace the custom HStack with `Menu { /* options */ } label: { /* current label */ }.menuStyle(.button).buttonStyle(.borderless)` and drop the manual chevron.
- **Effort**: S

### [P1] Theme system has parallel "ToolbarThemeColors" and "SidebarThemeColors" that mostly fall through to system colors
- **File**: `TablePro/Theme/ThemeColors.swift:349-407`.
- **Current**: `ToolbarThemeColors` and `SidebarThemeColors` exist but every field is optional and the resolved values fall through to `nil` (i.e. system semantic colors) for the bundled themes. Adds unnecessary surface area for chrome theming, which the app neither documents nor exposes in Settings.
- **HIG says**: Chrome should track the system. Theming the chrome is a power-user feature that needs a high-contrast and dark-mode test matrix.
- **Fix**: Remove `ToolbarThemeColors` and `SidebarThemeColors` from `ThemeColors.swift` and from any `ResolvedThemeColors` plumbing. Audit the editor theme JSON schema (used by the plugin registry — `PluginManager+Registration.swift:259`) and bump the schema version.
- **Effort**: S

### [P1] Inspector `Section` headers shout in ALL CAPS
- **File**: `TablePro/Views/RightSidebar/RightSidebarView.swift:78, 89, 102, 115`.
- **Current**: `Text("SIZE")`, `Text("STATISTICS")`, `Text("METADATA")`, `Text("TIMESTAMPS")` literal uppercase strings. SwiftUI `Form().formStyle(.grouped)` and `Section` already render headers in the system uppercase styling for grouped Form sections — by passing pre-uppercased strings the result is a double-uppercase title (CSS-style) on macOS Sonoma+.
- **HIG says**: Provide section titles in normal case and let the platform style apply. macOS 14 grouped Forms use small caps with system tracking.
- **Native examples**: System Settings / Network / Wi-Fi / Other Networks shows "Other Networks" in normal case; the platform applies the small-caps treatment.
- **Fix**: `Text("Size")`, `Text("Statistics")`, `Text("Metadata")`, `Text("Timestamps")`. Run through `String(localized:)`.
- **Effort**: S

### [P1] `ConnectionSwitcherPopover` headers use ALL CAPS too
- **File**: `TablePro/Views/Toolbar/ConnectionSwitcherPopover.swift:78, 111`.
- **Current**: `Text("ACTIVE CONNECTIONS")`, `Text("SAVED CONNECTIONS")`. Same issue as the inspector headers.
- **Fix**: Use natural case ("Active Connections", "Saved Connections"); when the popover is hosted in a List, the system applies the appropriate header treatment.
- **Effort**: S

### [P1] Onboarding hero icon at 48 pt; standard is 32 pt or via SF Symbol Hierarchical/Multicolor at the system text scale
- **File**: `TablePro/Views/Connection/OnboardingContentView.swift:153`.
- **Current**: `.font(.system(size: 48))` for hero icon.
- **HIG says**: Hero icons in welcome / onboarding views in stock Apple apps sit around 32-40 pt and use `Image(systemName:).symbolRenderingMode(.hierarchical)` for visual depth.
- **Native examples**: Welcome to Xcode hero is roughly 32 pt; System Settings sidebar avatar is 28 pt.
- **Fix**: Drop to 36 pt + `.symbolRenderingMode(.hierarchical)` plus accent color tinting via `.foregroundStyle(.tint)`.
- **Effort**: S

### [P1] Filter / Columns toggle in status bar uses `.toggleStyle(.button)` with internal HStack content (HIG anti-pattern)
- **File**: `TablePro/Views/Main/Child/MainStatusBarView.swift:165-183`.
- **Current**: A `Toggle(isOn: ...) { HStack { Image; Text("Filters"); Text("(count)") } }.toggleStyle(.button).controlSize(.small)`. The Toggle binding is a fake (the setter ignores the new value and calls `.toggle()` instead) — that's a code smell and a sign the control should be a regular `Button`.
- **HIG says**: `Toggle(.button)` is for a binary state. When the action is "open / close panel", a normal `Button` with `.bordered` and an active-state visual is more honest.
- **Native examples**: Xcode's Filter, Issues, Tests buttons in nav bars are plain buttons with active highlight.
- **Fix**: Replace with `Button { filterStateManager.toggle() } label: { Label("Filters", systemImage: ...) }.buttonStyle(.bordered).tint(filterStateManager.isVisible ? .accentColor : nil).controlSize(.small)`.
- **Effort**: S

### [P1] Sidebar tag icon hard-codes `.foregroundStyle(.yellow)` and `.foregroundStyle(.pink)` for branding
- **File**: `TablePro/Views/Connection/WelcomeLeftPanel.swift:58` (`.pink`), `TablePro/Views/RightSidebar/EditableFieldView.swift:95` (`.yellow`).
- **Current**: Direct color literals (`.yellow`, `.pink`) bypass the system semantic palette.
- **HIG says**: Use `Color(nsColor: .systemYellow)`, `Color(nsColor: .systemPink)` so colors track the system accent and high-contrast preferences.
- **Native examples**: Sponsor / heart icons in App Store use `.tint` or `Color(nsColor: .systemPink)`.
- **Fix**: `.foregroundStyle(Color(nsColor: .systemYellow))`, `.foregroundStyle(Color(nsColor: .systemPink))`.
- **Effort**: S

### [P1] `.systemOrange.opacity(0.15)` background on truncated badge — system colors are not designed for opacity backgrounds
- **File**: `TablePro/Views/RightSidebar/EditableFieldView.swift:122`.
- **Current**: `.background(Color(nsColor: .systemOrange).opacity(0.15))` — system colors aren't intended to be tinted at low alpha; the result will not match a real status banner.
- **HIG says**: Use `.regularMaterial` or `.thinMaterial` plus a colored stroke / colored foreground, not opacity-tinted system colors.
- **Fix**: Drop the background entirely (foreground SF Symbol + plain text is enough), or use `.background(.thinMaterial)` and color the icon only.
- **Effort**: S

### [P1] Tab strip in inspector (Details / AI Chat) uses `Picker(.segmented)` rather than `inspectorMode` toolbar items
- **File**: `TablePro/Views/RightSidebar/UnifiedRightPanelView.swift:33-40`.
- **Current**: Inline segmented picker. (See P0 above for placement; this P1 covers control choice if placement stays.)
- **HIG says**: For 2-3 mode switches inside an inspector, a SF Symbol-based segmented picker is fine, but it should sit in the toolbar accessory above the inspector (Pages/Numbers pattern). If kept inline, prefer `Picker(...).pickerStyle(.segmented).labelsHidden().controlSize(.small)`.
- **Fix**: After moving to the toolbar (P0 fix), keep `.pickerStyle(.segmented)` since stock toolbar accessories also use it.
- **Effort**: folded into P0

### [P1] No `accessibilityHint` on icon-only toolbar buttons whose action is non-obvious
- **File**: `MainWindowToolbar.swift:340-350` (Quick Switcher), `:374-388` (Filters), `:393-407` (Preview SQL), `:411-430` (Results), `:448-459` (History).
- **Current**: `.help(...)` is set but no `.accessibilityHint`. For a button labelled "Filters" via SwiftUI Label, VoiceOver speaks "Filters, button" with no indication of what activating it does.
- **HIG says**: "Accessibility" — when a button's effect is not obvious from its label, add a hint that completes the sentence "Activates this control to..."
- **Fix**: Add `.accessibilityHint(String(localized: "Toggles the filter panel"))` etc. to each non-obvious icon button.
- **Effort**: S

### [P1] `Color.accentColor.opacity(0.4)` shadow on Welcome app icon
- **File**: `TablePro/Views/Connection/WelcomeLeftPanel.swift:20`.
- **Current**: `.shadow(color: Color.accentColor.opacity(0.4), radius: 20, x: 0, y: 0)` — branded glow effect.
- **HIG says**: Welcome window app icons in stock Apple apps do not have colored glow shadows. Drop shadows are reserved for elevation cues, not branding.
- **Native examples**: Welcome to Xcode app icon — no shadow.
- **Fix**: Remove the shadow modifier. If a subtle elevation is desired, use `.shadow(color: .black.opacity(0.15), radius: 6, y: 2)`.
- **Effort**: S

---

## P2 — Polish

### [P2] `font(.system(size: 9))` on the Pro/badge pill in Welcome screen content rows
- **File**: `TablePro/Views/Connection/WelcomeWindowView.swift:373` and elsewhere.
- **Current**: 9 pt is below readable size; tag/badge subscripts.
- **Fix**: Use `.caption2` (11 pt at default scale) and trust system text styles.
- **Effort**: S

### [P2] `Color(red:)` / `Color(.sRGB:)` literals — none found in `TablePro/Views/`
- **Status**: confirmed clean by grep; finding kept here as a positive note in the audit report. Editor theme stores hex strings in JSON (`ThemeColors.swift:20-29` etc.) which is acceptable since editor colors are user-customizable theme content, not app chrome. Keep `SQLEditorTheme` as the single source of truth for editor colors and ensure no leakage outside the editor.
- **Action**: none.

### [P2] Tooltip `.help()` strings inline keyboard shortcuts in the tooltip text
- **File**: `MainWindowToolbar.swift:269, 290, 309, 324, 345, 371, 386, 402, 426, 443, 457, 471, 487`.
- **Current**: e.g. `.help(String(localized: "Save Changes (⌘S)"))`. macOS automatically shows shortcuts in tooltips when the matching menu item exists with a keyboardShortcut — duplicating the shortcut in the help text causes a double-display.
- **HIG says**: Let the system render shortcuts; help text should be the action description only.
- **Fix**: Verify whether double-display occurs after the menu integration; if so, drop the inline " (⌘S)" suffixes. Otherwise leave but make sure the shortcut symbol matches the actual keyboard binding (which is user-customizable, so a hard-coded string can drift).
- **Effort**: S

### [P2] Onboarding/welcome `Spacer().frame(height: 48)` magic spacers
- **File**: `TablePro/Views/Connection/WelcomeLeftPanel.swift:46`.
- **Current**: Hard-coded vertical spacer to compose the layout. Magic numbers without origin in design tokens.
- **Fix**: Replace with VStack alignment + dynamic spacing or extract to a `Spacing` constant if this pattern repeats.
- **Effort**: S

### [P2] Missing `Image.symbolRenderingMode(.hierarchical)` on inspector / sidebar icons
- **File**: `Views/Sidebar/SidebarView.swift:148`, `Views/RightSidebar/RightSidebarView.swift:148, 164`.
- **Current**: SF Symbols render flat — no hierarchical depth.
- **HIG says**: SF Symbols offer monochrome, hierarchical, palette, and multicolor rendering modes. Hierarchical adds subtle visual hierarchy that stock apps consistently apply to status icons.
- **Fix**: `Image(systemName: ...).symbolRenderingMode(.hierarchical)` on status / non-glyph-button icons.
- **Effort**: S

### [P2] `ContentUnavailableView` not used for inspector empty state — uses ad-hoc VStack
- **File**: `TablePro/Views/RightSidebar/RightSidebarView.swift:54-61`.
- **Current**: Already uses `ContentUnavailableView` (good!) but the icon "sidebar.right" isn't a great match — for an inspector that hosts row details / table info, `tablecells.badge.ellipsis` or `info.circle` is more semantic.
- **Fix**: Replace `systemImage: "sidebar.right"` with a more representative icon.
- **Effort**: S

### [P2] Settings tab order
- **File**: `TablePro/Views/Settings/SettingsView.swift:18-65`.
- **Current**: Order is General, Appearance, Editor, Keyboard, AI, Terminal, Integrations, Plugins, Account. Modern System Settings groups (1) account/identity at top, (2) appearance/general, (3) feature panes, (4) plugins/extensions.
- **Fix**: After the NavigationSplitView migration, reorder to General, Account, Appearance, Editor, Keyboard, Terminal, AI, Integrations, Plugins. (Account near top is the macOS norm.)
- **Effort**: S

---

## Summary

| ID | Severity | Area | Title | Effort |
|----|----------|------|-------|--------|
| CV-01 | P0 | Typography | Hard-coded font sizes; switch to semantic styles | M |
| CV-02 | P0 | Inspector | Mode picker inline; rename "RightSidebar" → "Inspector" | M |
| CV-03 | P0 | Welcome window | Restore standard title bar + traffic-light triplet | S |
| CV-04 | P0 | Controls | Drop `WelcomeButtonStyle`, use `.bordered` | S |
| CV-05 | P0 | Welcome | Drop `KeyboardHint` rounded-rect badges | S |
| CV-06 | P0 | Toolbar | Drop `TagBadgeView` capsule chrome | S |
| CV-07 | P0 | Inspector | Drop capsule pills, fix systemOrange badge | S |
| CV-08 | P0 | Popover | Use system List selection in `ConnectionSwitcherPopover` | M |
| CV-09 | P0 | Popover | Drop `alternateSelectedControlTextColor` color flips | S |
| CV-10 | P0 | Toolbar | Add `View > Customize Toolbar…` menu item | S |
| CV-11 | P0 | Toolbar | Enable `autosavesConfiguration`; fix per-instance UUID | M |
| CV-12 | P0 | Sidebar | Add filter search field above tables list | S |
| CV-13 | P0 | Settings | Migrate `TabView` Settings to `NavigationSplitView` | M |
| CV-14 | P0 | Empty states | Replace 32 pt hero VStacks with `ContentUnavailableView` | M |
| CV-15 | P0 | Settings | Move appearance picker into a Form section | S |
| CV-16 | P0 | Accessibility | Add missing `.accessibilityLabel` to icon-only buttons | M |
| CV-17 | P0 | Accessibility | Combine row children + hide decorative glyphs | M |
| CV-18 | P0 | Accessibility | Respect `accessibilityReduceMotion` in welcome transition | S |
| CV-19 | P1 | Color | Drop `ThemeEngine.toolbar` colors; chrome tracks system | S |
| CV-20 | P1 | Toolbar | Hide ExecutionIndicator placeholder when idle | S |
| CV-21 | P1 | Settings | Drop redundant `.pickerStyle(.menu)` inside `.grouped` Form | S |
| CV-22 | P1 | Typography | Use `.monospacedDigit()`, not `.monospaced`, for numbers | S |
| CV-23 | P1 | Sidebar | Reduce sidebar minimum width 280 → 200 | S |
| CV-24 | P1 | Welcome | Tag chip → tag dot in `WelcomeConnectionRow` | S |
| CV-25 | P1 | Sidebar | Replace `ConnectionSidebarHeader` custom button-as-menu with `Menu` (or delete if unused) | S |
| CV-26 | P1 | Theme | Remove `ToolbarThemeColors` / `SidebarThemeColors` from theme schema | S |
| CV-27 | P1 | Inspector | Section titles in normal case, not ALL CAPS | S |
| CV-28 | P1 | Popover | Section titles in normal case in `ConnectionSwitcherPopover` | S |
| CV-29 | P1 | Onboarding | Reduce hero icon from 48 pt to 36 pt + hierarchical | S |
| CV-30 | P1 | Status bar | Replace fake-Toggle filter button with real `Button` | S |
| CV-31 | P1 | Color | Replace `.yellow` / `.pink` literals with `Color(nsColor: .systemYellow/Pink)` | S |
| CV-32 | P1 | Inspector | Drop opacity-tinted systemOrange badge background | S |
| CV-33 | P1 | Accessibility | Add `accessibilityHint` to non-obvious icon buttons | S |
| CV-34 | P1 | Welcome | Drop accent-colored shadow on app icon | S |
| CV-35 | P2 | Typography | Replace 9 pt badge text with `.caption2` | S |
| CV-36 | P2 | Tooltip | Drop inline shortcut suffix from `.help()` strings | S |
| CV-37 | P2 | Welcome | Replace magic `Spacer().frame(height: 48)` | S |
| CV-38 | P2 | SF Symbols | Apply `.symbolRenderingMode(.hierarchical)` to status icons | S |
| CV-39 | P2 | Inspector | Replace `sidebar.right` empty-state icon with semantic glyph | S |
| CV-40 | P2 | Settings | Reorder tabs (Account near top) | S |

**Counts**: P0 = 18, P1 = 16, P2 = 6, total 40 actionable items.

The two largest themes are:
1. **Custom chrome where standard exists** — capsules, pills, custom buttons, custom selection backgrounds, custom kbd badges. The fix is mechanical removal in favor of `.bordered`, `.borderless`, semantic colors, and system-managed selection.
2. **Hard-coded typography** — 80 sites of `.font(.system(size: …))`, none of which scale with Dynamic Type. The fix is a pass replacing each with the closest semantic style.

Both unblock the deeper inspector / settings / welcome HIG migrations.
