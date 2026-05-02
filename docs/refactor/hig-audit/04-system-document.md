# 04 — System & Document Model Audit

**Agent**: system-document-auditor
**Scope**: `TablePro/` target only. Document model, file associations, Open/Save panels, Undo/Redo, Find/Replace, Settings, About, Services, Notifications, Sparkle, Dock, sandbox/entitlements, Quick Look, localization.
**Date**: 2026-05-01
**Conclusion**: TablePro hand-rolls a partial document model on top of `QueryTab` and `NSWindow.representedURL`/`isDocumentEdited`. Core Apple infrastructure for documents is missing: no `NSDocument`/`FileDocument`, no Open Recent menu, no auto-save, no Versions, no Revert/Duplicate/Rename/Move To, no Quick Look, no Services. The bridge that does exist works, but every feature Apple gives you for free has to be reimplemented or ignored.

---

## P0 — Broken native contracts

### [P0] No document model — SQL files are not first-class documents
- **File**: `TablePro/TableProApp.swift:628`, `TablePro/Models/Query/QueryTabState.swift:257`, `TablePro/Core/Services/Infrastructure/SQLFileService.swift:1`
- **Current**: SQL files are loaded into `TabQueryContent.query` (a plain `String`) tracked by `sourceFileURL` + `savedFileContent`. The dirty state is computed by string comparison at `QueryTabState.swift:266`. There is no `NSDocument`, no `FileDocument`/`ReferenceFileDocument`, no `DocumentGroup`. `TableProApp.body` declares only a `Settings { }` scene; main windows are AppKit-imperative. Search confirms zero usages of `NSDocument`/`FileDocument`/`DocumentGroup` (only one comment mention at `AlertHelper.swift:139`).
- **HIG says**: "Documents — Use the document architecture so people can save, open, rename, move, duplicate, revert, and version their files using the same controls they use in every other macOS app." Apple's File menu items (Save, Save As, Duplicate, Rename, Move To, Revert To, Save All, Open Recent) come for free with `NSDocumentController` and `NSDocument`. Hand-rolled document tracking is the canonical reason apps fail HIG review.
- **Native examples**: TextEdit (`NSDocument`), Xcode (`SourceCodeDocument`), Pages, Numbers, Keynote, BBEdit, Nova, Tot.
- **Fix**: Introduce a `SQLDocument: ReferenceFileDocument` (reference-typed because `QueryTab` is mutable and shared with the data grid). Migrate the SQL-file lifecycle out of `MainContentCommandActions.openSQLFile()` / `saveFileAs()` / `saveFileToSourceURL()` / the `.openSQLFiles` Notification, and let SwiftUI's `DocumentGroup` (or a parallel AppKit `NSDocumentController` registration) own Open / Save / Save As / Revert / Duplicate / Rename / Move To / Open Recent for `.sql` files. Connection-bound query tabs that aren't backed by a file remain `QueryTab` only — the document layer wraps the file-bound tabs.
- **Effort**: L

### [P0] Open Recent menu is missing
- **File**: `TablePro/TableProApp.swift:197-293` (File menu uses `CommandGroup(replacing: .newItem)` and `CommandGroup(after: .newItem)`), `TablePro/Core/Services/Infrastructure/TabRouter.swift:322` (`openSQLFile` never registers recents).
- **Current**: No "Open Recent ▶" submenu anywhere in the File menu. `noteNewRecentDocumentURL` is never called in the entire codebase. SQL files opened from the open panel, drag-drop, Finder Open With, and `tablepro://` URLs never appear in Open Recent.
- **HIG says**: "Open Recent — Most apps that work with documents should provide an Open Recent menu" (HIG → File management). The menu is auto-populated when the app uses `NSDocumentController`, or by calling `NSDocumentController.shared.noteNewRecentDocumentURL(_:)` on every successful open. macOS adds the standard "Clear Menu" item automatically.
- **Native examples**: TextEdit, Xcode, Preview, Pages, BBEdit. Every native document-based app on macOS.
- **Fix**: After moving to `NSDocument`/`ReferenceFileDocument` (P0 above) this comes for free. Until then, call `NSDocumentController.shared.noteNewRecentDocumentURL(url)` from `TabRouter.openSQLFile(_:)`, the SQL `NSOpenPanel` callback in `MainContentCommandActions.openSQLFile()`, and `application(_:open:)` in `AppDelegate.swift:17`. Add `CommandGroup(after: .newItem) { OpenRecentMenu() }` (custom subview that reads `NSDocumentController.shared.recentDocumentURLs`) so the menu actually renders in the SwiftUI command tree.
- **Effort**: M (S if folded into the NSDocument migration).

### [P0] No auto-save, no Versions, no "Edited" Time Machine integration
- **File**: `TablePro/Views/Main/MainContentCommandActions.swift:420-436` (`saveFileToSourceURL`), `TablePro/Models/Query/QueryTabState.swift:257`.
- **Current**: SQL files are saved only when the user explicitly invokes Save (`Cmd+S`) or accepts the unsaved-changes alert on tab close. `applicationShouldTerminate` (`AppDelegate.swift:99`) shows a custom warning and discards on quit. There is no auto-save timer, no `NSDocument.autosavesInPlace`, no `NSFileVersion` snapshots, no Time Machine "Browse All Versions…" support.
- **HIG says**: "Documents — Modern apps should auto-save documents and integrate with Versions so people can recover earlier states." `NSDocument.autosavesInPlace` returning `true` enables auto-save, the dirty-dot in the close button, the proxy icon's "Locked / Edited / Last opened" tooltip, and the File ▸ Revert To ▸ Browse All Versions… menu.
- **Native examples**: TextEdit, Pages, Notes, Xcode (project files), BBEdit, Tot. Apple's HIG explicitly contrasts "modern" apps (auto-save) against "legacy" apps with manual save dialogs.
- **Fix**: Resolve via the `ReferenceFileDocument` migration (P0 first finding). For SQL files, opt into `NSDocument.autosavesInPlace` (free with `ReferenceFileDocument`) and remove the custom unsaved-changes alert in `closeTab()` / `applicationShouldTerminate`. Keep the custom alert only for non-document state (data-grid edits, structure edits) which don't have a backing file.
- **Effort**: L (folded into NSDocument migration).

### [P0] File menu lacks Revert / Duplicate / Rename / Move To
- **File**: `TablePro/TableProApp.swift:204-293`.
- **Current**: The custom File menu provides only New Tab, New View, Open Database, Open File, Save Changes, Save As, Close Tab, Export/Import. Missing: Duplicate (`Cmd+Shift+S` in the Apple-standard layout), Rename…, Move To…, Revert To ▸ Last Saved / Browse All Versions…, Save All. These items are auto-inserted by `NSDocument` and required by HIG for document-based apps.
- **HIG says**: "File menu" lists File ▸ Save, Save As, Save All, Duplicate, Rename, Move To, Revert To as the standard set. Removing them silently from a document-based app breaks user muscle memory across the OS.
- **Native examples**: TextEdit, Pages, Numbers, Xcode. Even simple document apps like Tot include Duplicate / Rename / Move To.
- **Fix**: Once SQL files become `NSDocument`-backed, these items appear automatically. If we choose to keep the hand-rolled model, manually add these items to `CommandGroup(after: .newItem)` and wire them to `NSDocumentController` selectors (`saveDocument:`, `duplicateDocument:`, `renameDocument:`, `moveDocument:`, `revertDocumentToSaved:`).
- **Effort**: S if going via NSDocument; M otherwise.

### [P0] Cmd+G / Cmd+Shift+G (find next/previous) not wired
- **File**: `TablePro/TableProApp.swift:430-435`, `TablePro/Views/Editor/EditorEventRouter.swift:93`.
- **Current**: `Cmd+F` shows the find panel via `EditorEventRouter.shared.showFindPanelForKeyWindow()`. There is no menu item or shortcut for Find Next (`Cmd+G`) or Find Previous (`Cmd+Shift+G`). Search confirms zero usages of `performTextFinderAction`, `findNext`, or `findPrevious` selectors in the project.
- **HIG says**: The Find submenu in the Edit menu must include Find… (`Cmd+F`), Find Next (`Cmd+G`), Find Previous (`Cmd+Shift+G`), Use Selection for Find (`Cmd+E`), and Jump to Selection (`Cmd+J`). All five are auto-installed when the app implements the standard `NSTextFinder` responder chain. CodeEditTextView's `TextView` already implements these.
- **Native examples**: TextEdit, Xcode, Safari, Mail, Pages, BBEdit. Every text editor on macOS.
- **Fix**: Replace the custom `Cmd+F` button with a SwiftUI `CommandGroup(replacing: .textEditing)` that exposes the standard Find submenu, or add explicit Buttons for findNext / findPrevious / useSelectionForFind / jumpToSelection that send `#selector(NSTextFinder.performAction(_:))` (or the responder-chain wrappers). CodeEdit's TextView responds to `performTextFinderAction(_:)` via `NSTextFinderClient`; route through the responder chain.
- **Effort**: S

### [P0] Edit menu lacks Find Next / Find Previous / Use Selection for Find / Jump to Selection
- **File**: `TablePro/TableProApp.swift:427-457`.
- **Current**: The "Find" Button at line 430 is the only item in the Find area, replacing nothing — there's no submenu structure. SwiftUI's default Find submenu (which would have all five items) is suppressed because the app declares `CommandGroup(after: .pasteboard)` with a single `Button("Find...")`.
- **HIG says**: Same as above; standard Find submenu must include all five items.
- **Native examples**: TextEdit, Xcode, BBEdit.
- **Fix**: Restructure as `CommandGroup(replacing: .textEditing)` + `CommandMenu("Find") { ... }` containing all five canonical entries, or stop suppressing the default Find submenu and only override the items we need.
- **Effort**: S (combine with the previous item).

### [P0] AppDelegate's custom unsaved-changes alert duplicates `NSDocument` semantics, fights auto-save
- **File**: `TablePro/AppDelegate.swift:99-118`.
- **Current**: `applicationShouldTerminate` walks `MainContentCoordinator.hasAnyUnsavedChanges()` and shows a single warning sheet ("You have unsaved changes / Quitting will discard these changes") with destructive "Quit Anyway".
- **HIG says**: For document apps, Apple owns the quit-with-unsaved-documents flow (`NSDocumentController.reviewUnsavedDocuments(...)`), iterating each unsaved document with the standard "Save / Cancel / Don't Save" dialog. Auto-save apps don't need this alert at all — they auto-save on quit.
- **Native examples**: TextEdit, Pages, Numbers, Xcode all let `NSDocumentController` handle quit review.
- **Fix**: After NSDocument migration, delete this alert and let `NSDocumentController` handle quit review. Keep a custom alert only for non-document state (uncommitted data-grid / structure edits) and present it through `NSApplication.reply(toApplicationShouldTerminate:)`.
- **Effort**: S after document migration; otherwise leave but add per-document iteration.

---

## P1 — Non-idiomatic

### [P1] Settings window uses old `TabView` toolbar style (pre-macOS 13)
- **File**: `TablePro/Views/Settings/SettingsView.swift:17-66`.
- **Current**: `SettingsView` is a `TabView { ... .tabItem { Label("...", systemImage: "...") } ... }` with a fixed `.frame(width: 720, height: 500)` and 9 tabs (General, Appearance, Editor, Keyboard, AI, Terminal, Integrations, Plugins, Account). This renders as the legacy toolbar-tabbed Preferences window.
- **HIG says**: macOS Sonoma (14) and later use the Settings sidebar/detail layout (`NavigationSplitView` style), matching the system Settings app. SwiftUI's `Settings { }` scene supports both, but `TabView` with `.tabItem` modifiers locks you to the old style. With nine sections, the toolbar gets cramped — the sidebar style is what System Settings, Xcode 15, and Mail now use.
- **Native examples**: Xcode 15 Settings, System Settings, Mail Settings, Notes Settings, Things 3.
- **Fix**: Refactor `SettingsView` into a `NavigationSplitView` with a fixed sidebar listing the nine sections and a detail pane swapping in each section view. Keep the `@AppStorage("selectedSettingsTab")` binding so deep-links from `LaunchIntentRouter` and `AppDelegate.handlePluginsRejected` still navigate to the right pane.
- **Effort**: M

### [P1] `applicationShouldTerminateAfterLastWindowClosed` not implemented; closing all windows shows Welcome instead of quitting
- **File**: `TablePro/AppDelegate.swift:172-184`.
- **Current**: `windowWillClose(_:)` posts `.mainWindowWillClose` and re-opens the Welcome window when the last main window closes. Apple's standard pattern for menu-bar/utility apps that want to keep running after closing all windows is to override `applicationShouldTerminateAfterLastWindowClosed`. For a document app, the convention is the opposite: closing the last window does **not** quit (the app stays in the dock to handle drag-drop / Open Recent).
- **HIG says**: "Document-based apps should keep running after the last document closes; users open another via File ▸ Open Recent or by dragging onto the Dock icon." TablePro behaves correctly (stays running) but achieves it through a custom Welcome-window springback, which is its own non-native pattern (see `02-windows-interactions.md` for details).
- **Native examples**: TextEdit, Pages — closing the last window leaves the app running; the Dock icon stays bouncy and `applicationShouldHandleReopen` shows the Open dialog.
- **Fix**: After document migration, remove the Welcome-springback. Implement `applicationShouldTerminateAfterLastWindowClosed → false` and rely on `applicationShouldHandleReopen` (already present at `AppDelegate.swift:27`) to surface the Welcome window when the user clicks the Dock icon.
- **Effort**: S

### [P1] Hand-rolled Save Changes alert duplicates `NSDocument`'s built-in behavior
- **File**: `TablePro/Core/Utilities/UI/AlertHelper.swift:130-163`, `TablePro/Views/Main/MainContentCommandActions.swift:327-350`.
- **Current**: `confirmSaveChanges` builds an `NSAlert` with "Save / Cancel / Don't Save" buttons and a custom `Cmd+D` for "Don't Save". The button order and shortcut are correct (commit at `2f5b4f8e` style — comment at line 139 even references the convention). But the alert is built manually for each call site rather than letting `NSDocument.canClose(withDelegate:...)` handle it.
- **HIG says**: `NSDocument` provides this dialog, with the correct localization in 30+ languages, the correct destructive-action styling, and the correct return mapping. Apps that re-implement this alert get subtly different behavior from system apps (and have to maintain translations).
- **Native examples**: TextEdit, Pages, Xcode.
- **Fix**: Keep `AlertHelper.confirmSaveChanges` only for non-document state (data-grid / structure edits). Route file-dirty checks through `NSDocument.canClose(withDelegate:...)`.
- **Effort**: S after document migration.

### [P1] No iCloud Drive / ubiquitous documents, despite iCloud entitlement
- **File**: `TablePro/TablePro.entitlements:7-15`.
- **Current**: The entitlements file enables `com.apple.developer.icloud-container-identifiers` and CloudKit, but no `NSUbiquitousContainers` Info.plist key is set and no document presenter / file coordinator code exists. iCloud is wired up only for connection sync.
- **HIG says**: If you ship a document type and use iCloud, also expose iCloud Drive so users can store SQL files in iCloud. Either remove the iCloud entitlement scope or wire it to documents.
- **Native examples**: TextEdit (iCloud Drive container), Pages, Numbers.
- **Fix**: After NSDocument migration, add `NSUbiquitousContainers` to Info.plist with a `NSUbiquitousContainerIsDocumentScopePublic = YES` entry so SQL files appear in `~/Library/Mobile Documents/com~TablePro~iCloud/Documents/`. Or scope the iCloud entitlement strictly to the connection-sync container.
- **Effort**: S

### [P1] About panel hand-builds links into Credits — should ship `Credits.rtf`
- **File**: `TablePro/TableProApp.swift:146-174`, `TablePro/Resources/`.
- **Current**: The "About TablePro" Button programmatically constructs an `NSAttributedString` with four links (Website / GitHub / Documentation / Sponsor) and passes it via `NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: ...])`. There is no `Credits.rtf` (or `.html`) in `Resources/` (verified with `find`).
- **HIG says**: The standard about panel reads `Credits.rtf` / `Credits.html` automatically when present. Ship the file in the bundle and let macOS render it. This also localizes (`Credits.rtf` per .lproj) without requiring `String(localized:)` plumbing for link labels.
- **Native examples**: Almost every native macOS app ships `Credits.rtf` (Xcode, Pages, Bartender, Tot).
- **Fix**: Move the four links into a `Credits.rtf` (or per-locale variants in `Resources/en.lproj/Credits.rtf`) and remove the inline construction. Keep just `NSApplication.shared.orderFrontStandardAboutPanel(options: [:])`.
- **Effort**: S

### [P1] `panel.message` strings hardcoded in English (localization regression)
- **File**: `TablePro/Views/Main/Extensions/MainContentCoordinator+SidebarActions.swift:140`, `TablePro/Views/Import/ImportDialog.swift:301`.
- **Current**: Two `NSOpenPanel` instances use hardcoded `panel.message = "Select SQL file to import"` and `"Select file to import"`. CLAUDE.md mandates `String(localized:)` for new user-facing strings; the rest of the codebase complies (`SQLFileService.swift:39,52`, `Plugins/InstalledPluginsView.swift:377`, `ERDiagramView.swift:286`).
- **HIG says**: All system-presented file panel messages should localize alongside the rest of the UI.
- **Fix**: Wrap both with `String(localized:)`.
- **Effort**: S

### [P1] No `UNUserNotificationCenter` usage — no notification for long queries, sync events, or update available
- **File**: codebase-wide (zero matches for `UNUserNotificationCenter`/`UNNotificationRequest`).
- **Current**: TablePro never delivers a user notification. Long queries finish silently (only the in-app status bar updates). Sync conflicts surface only inside the Settings panel. Sparkle uses its own in-app dialog, which is fine.
- **HIG says**: "Notifications — Use notifications for events the user might want to know about when your app isn't in front." A query that takes 30 seconds (default `confirm_destructive_operation` warns at 5 s in MCP) absolutely qualifies. The user might switch to another app while waiting.
- **Native examples**: Xcode (build complete), Mail (new messages), Calendar (alarms), Activity Monitor (high CPU), Time Machine (backup complete).
- **Fix**: Add `UNUserNotificationCenter.current().requestAuthorization(...)` lazily on the first long query (>10 s elapsed). When a query finishes while the app is not the frontmost, post a `UNMutableNotificationContent` with title="Query finished" and body="<rows> rows in <duration>". Same for sync conflicts. Hide behind a setting in General → Notifications. Don't request authorization at launch.
- **Effort**: M

### [P1] No Quick Look preview for `.sql` files
- **File**: `TablePro/Info.plist:11-105` declares `.sql` documents but there is no Quick Look generator (no `QuickLookThumbnailing` extension, no `QLPreviewPanel` integration).
- **Current**: Selecting a `.sql` file in Finder and pressing space shows the system-default plain-text preview (because `com.tablepro.sql` conforms to `public.plain-text`). It works because of the conformance, but it's the unstyled, monospace plain-text Quick Look — no syntax highlighting, no per-statement count, no theme.
- **HIG says**: Apps that own a document type should ship a Quick Look extension (or thumbnail extension) that renders previews matching the in-app appearance.
- **Native examples**: Xcode (`.swift` previews with syntax highlighting), Pages, Pixelmator Pro.
- **Fix**: Add a `Quick Look Preview` app extension target that renders the SQL with the same `SQLEditorTheme` palette via `CodeEditSourceEditor` in read-only mode. Lower priority than the document model itself.
- **Effort**: M

### [P1] App is unsandboxed — blocks Mac App Store distribution and trips off-store warnings
- **File**: `TablePro/TablePro.entitlements:19-22`, `TablePro.xcodeproj/project.pbxproj:2272,2350` (`ENABLE_APP_SANDBOX = NO`).
- **Current**: `com.apple.security.app-sandbox = false`. `com.apple.security.cs.disable-library-validation = true` (needed for plugin loading from outside the bundle). Hardened Runtime is on (`ENABLE_HARDENED_RUNTIME = YES`).
- **HIG says**: "Distributing your app — Mac App Store apps must be sandboxed." This is a roadmap concern, not a HIG bug per se, but it's the single biggest gap between TablePro and TablePlus/Postico/Sequel Ace (all sandboxed-when-needed). The root cause for unsandboxed-ness is plugin loading — `.tableplugin` bundles outside the app bundle can't be loaded under sandbox.
- **Native examples**: TablePlus (sandboxed App Store build, unsandboxed direct build), Postico (sandboxed), Sequel Ace (sandboxed).
- **Fix**: Out of scope for this audit, but flagged: a sandbox-eligible build would need plugins to be signed Apple-distributed app extensions (or accept the no-third-party-plugins limitation in the App Store variant). The MCP server / SSH tunnel / network DB drivers all need sandbox-permitted entitlements (`com.apple.security.network.client`, `com.apple.security.files.user-selected.read-write`, etc.). The disable-library-validation entitlement is incompatible with the App Store. Track this as a separate "App Store readiness" project, not part of HIG refactor.
- **Effort**: L (parallel project)

### [P1] No Services menu integration
- **File**: codebase-wide (zero matches for `registerServicesMenuSendTypes`, `NSServicesMenu`, `writeSelection(to:`).
- **Current**: TablePro neither registers any service ("Run as Query in TablePro") nor accepts services from other apps (e.g., "Format selected SQL").
- **HIG says**: "Services menu — Provide services for the parts of your app that produce or consume data others might want." Optional, not required. Most database clients ignore services.
- **Native examples**: BBEdit ("New BBEdit Document Containing Selection"), TextEdit, Mail, Safari.
- **Fix**: Optional — provide an "Open in TablePro" service that takes selected SQL text, opens a new query tab on the active connection. Add `NSServices` keys to Info.plist and call `NSApp.servicesProvider = ServicesProvider()` from `applicationDidFinishLaunching`. Low priority compared to document model gaps.
- **Effort**: S (optional)

### [P1] Custom Cmd+W close-tab logic mixed with `applicationShouldTerminate` quit-review duplicates work
- **File**: `TablePro/Views/Main/MainContentCommandActions.swift:327-350`, `TablePro/AppDelegate.swift:99-118`.
- **Current**: Two separate code paths handle "save before going away" — `closeTab()` shows `confirmSaveChanges`, `applicationShouldTerminate` shows a different alert. They use different button orders, different copy, different shortcut bindings.
- **HIG says**: A document-based app delegates both flows to `NSDocumentController.reviewUnsavedDocuments(...)` for consistency.
- **Native examples**: TextEdit, Pages.
- **Fix**: Consolidate via `NSDocument.canClose(withDelegate:...)` (post-migration). Until then, share a single helper that produces the same alert copy/shortcuts.
- **Effort**: S after document migration.

---

## P2 — Polish

### [P2] `MainContentCommandActions.openSQLFile()` round-trips through NotificationCenter
- **File**: `TablePro/Views/Main/MainContentCommandActions.swift:558-563`, `TablePro/Views/Main/MainContentCommandActions.swift:786-795`.
- **Current**: `openSQLFile()` shows the panel, then posts `.openSQLFiles` with the URLs. The same actions object subscribes via `observeKeyWindowOnly(.openSQLFiles)` and routes to `TabRouter.shared.route(.openSQLFile(url))`. The Notification round-trip is unnecessary — just call the router directly.
- **HIG says**: N/A; this is internal architecture noise.
- **Fix**: Remove `openSQLFiles` Notification, call `TabRouter` directly from `openSQLFile()`. Notification is also posted from `AppDelegate.application(_:open:)` indirectly through `AppLaunchCoordinator` — pick one path.
- **Effort**: S

### [P2] `application(_:open:)` doesn't note recent documents — even Drag-and-Drop / Open With opens are silent
- **File**: `TablePro/AppDelegate.swift:17-19`.
- **Current**: `application(_:open:)` forwards to `AppLaunchCoordinator.shared.handleOpenURLs(urls)` and never calls `NSDocumentController.shared.noteNewRecentDocumentURL`. Same gap on every other entry point. Already covered by P0 above; flagged here to ensure the fix touches every entry point.
- **Fix**: Single audit pass to ensure every entry point (open panel, Open With from Finder, drag onto Dock, drag onto window, `tablepro://` URL with file path, recent reopen) feeds through the same `noteNewRecentDocumentURL` hook.
- **Effort**: S

### [P2] `panel.title` is set on `NSOpenPanel` (deprecated API for sheets)
- **File**: `TablePro/Views/Settings/Plugins/InstalledPluginsView.swift:377`, `TablePro/Views/ERDiagram/ERDiagramView.swift:285`.
- **Current**: `panel.title = ...` is set on the open/save panel. As of macOS 11, `NSSavePanel.title` shows only when the panel is a window, not a sheet. For sheets (which is how these are presented via `beginSheetModal(for:)`), the title is ignored.
- **HIG says**: Use `panel.message` for the descriptive text on sheets; `panel.prompt` to override the default action button label ("Open" / "Save").
- **Fix**: Replace `panel.title` with `panel.message` (or remove if `panel.message` is already set). Trivial cleanup.
- **Effort**: S

### [P2] Dock right-click menu omits "New Tab" / "Open Recent" / per-window context
- **File**: `TablePro/AppDelegate.swift:194-236`.
- **Current**: `applicationDockMenu(_:)` returns "Show Welcome Window" + per-connection "Open Connection" submenu. Missing: "Open Recent ▶" (would auto-populate from `NSDocumentController.shared.recentDocumentURLs`), "New Query Tab" (only useful when a connection is active, but standard).
- **HIG says**: Dock menu entries should mirror commonly used menu items. Apple auto-merges "Open Recent" / "New Window" when present in the main menu of a document-based app — meaning a lot of this disappears for free after the document migration.
- **Fix**: After document migration, the Dock menu's recent-documents section is automatic. Add a "New Query Tab in <last connection>" item for active sessions.
- **Effort**: S

### [P2] No `applicationShouldHandleReopen` activation logging — silent no-op when Welcome already visible
- **File**: `TablePro/AppDelegate.swift:27-29`, `TablePro/Core/Services/Infrastructure/AppLaunchCoordinator.swift:224`.
- **Current**: `applicationShouldHandleReopen` returns whatever `AppLaunchCoordinator.handleReopen` returns. The reopen path opens the Welcome window. Standard behavior, but `WelcomeWindowFactory.openOrFront()` doesn't log when no main windows exist — minor observability gap.
- **Fix**: Add OSLog statement to make the path observable.
- **Effort**: S

### [P2] `WelcomeWindowFactory.openOrFront()` has no equivalent for the standard "show Open dialog when no docs" flow
- **File**: `TablePro/Core/Services/Infrastructure/AppLaunchCoordinator.swift:224`.
- **Current**: When the user reopens a document app with no windows, Apple's convention is to show the standard Open dialog (or recent-documents picker), not a custom Welcome panel. TablePro substitutes the Welcome window — fine for connection-first UX, but misses the case where the user really did just want to open a `.sql`.
- **HIG says**: `NSApplicationDelegateOpenUntitledFile` lets the app decide what "untitled" means. For database clients, the Welcome window is a reasonable answer.
- **Fix**: After document model exists, decide whether reopen=Welcome or reopen=Open Recent. Likely keep current behavior; flagged for awareness.
- **Effort**: N/A (decision)

---

## Summary table

| ID | Severity | Title | File anchor | Effort |
|----|----------|-------|-------------|--------|
| 04-01 | P0 | No `NSDocument` / `FileDocument` for SQL files | `TableProApp.swift:628`, `QueryTabState.swift:257` | L |
| 04-02 | P0 | Open Recent menu is missing entirely | `TableProApp.swift:197`, `TabRouter.swift:322` | M |
| 04-03 | P0 | No auto-save / Versions / Time Machine integration | `MainContentCommandActions.swift:420` | L |
| 04-04 | P0 | File menu missing Revert / Duplicate / Rename / Move To | `TableProApp.swift:204` | S (post-04-01) |
| 04-05 | P0 | Cmd+G / Cmd+Shift+G (find next/previous) not wired | `TableProApp.swift:430` | S |
| 04-06 | P0 | Find submenu missing Use Selection / Jump to Selection | `TableProApp.swift:427` | S |
| 04-07 | P0 | `applicationShouldTerminate` reimplements `NSDocument` quit-review | `AppDelegate.swift:99` | S (post-04-01) |
| 04-08 | P1 | Settings uses pre-Sonoma `TabView` toolbar style | `SettingsView.swift:17` | M |
| 04-09 | P1 | Welcome-springback non-native; should use `applicationShouldTerminateAfterLastWindowClosed` | `AppDelegate.swift:172` | S |
| 04-10 | P1 | Custom Save Changes alert duplicates `NSDocument` | `AlertHelper.swift:130` | S (post-04-01) |
| 04-11 | P1 | iCloud entitlement set but no document iCloud Drive support | `TablePro.entitlements:7` | S |
| 04-12 | P1 | About panel programmatic credits — should ship `Credits.rtf` | `TableProApp.swift:146` | S |
| 04-13 | P1 | Hardcoded English `panel.message` strings | `MainContentCoordinator+SidebarActions.swift:140`, `ImportDialog.swift:301` | S |
| 04-14 | P1 | No `UNUserNotificationCenter` for long queries / sync events | (codebase-wide) | M |
| 04-15 | P1 | No Quick Look extension for `.sql` files | `Info.plist:11`, no QL target | M |
| 04-16 | P1 | App is unsandboxed (App Store readiness, separate project) | `TablePro.entitlements:19` | L |
| 04-17 | P1 | No Services menu integration | (codebase-wide) | S (optional) |
| 04-18 | P1 | Cmd+W and quit-review use different alert copy | `MainContentCommandActions.swift:327`, `AppDelegate.swift:99` | S (post-04-01) |
| 04-19 | P2 | `openSQLFile` round-trips through Notification | `MainContentCommandActions.swift:558` | S |
| 04-20 | P2 | `application(_:open:)` doesn't note recent documents | `AppDelegate.swift:17` | S |
| 04-21 | P2 | `panel.title` set on sheet panels (ignored) | `InstalledPluginsView.swift:377`, `ERDiagramView.swift:285` | S |
| 04-22 | P2 | Dock menu omits Open Recent / New Tab | `AppDelegate.swift:194` | S |
| 04-23 | P2 | `applicationShouldHandleReopen` lacks OSLog tracing | `AppDelegate.swift:27` | S |
| 04-24 | P2 | Reopen flow shows Welcome instead of Open dialog (decision flag) | `AppLaunchCoordinator.swift:224` | N/A |

## Recommendation

The headline gap is the **document model**. Fixing 04-01 unlocks 04-02 (Open Recent), 04-03 (auto-save / Versions), 04-04 (File-menu items), 04-07 (quit review), 04-10 (Save Changes alert), 04-18 (Cmd+W consistency), and most of 04-22 in one stroke. Land that first, then mop up Find shortcuts (04-05, 04-06), Settings sidebar (04-08), and Credits.rtf (04-12).

The unsandboxed build (04-16) is the only item that affects strategic distribution (Mac App Store) and is a separate body of work that should be tracked outside this audit.
