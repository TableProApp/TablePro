# UI/UX Audit — TablePro

Audit date: 2026-03-31

## Critical

- [x] ~~**No close confirmation for unsaved edits**~~ — already implemented in `MainContentCommandActions.swift:305-326`
- [x] **Onboarding strings not localized** — fixed in 948edbfd
- [x] **Empty result state missing** — fixed in 948edbfd
- [x] **Import button enabled when preview fails** — fixed in 85d66dfb
- [x] **License activation load fails silently** — fixed in d8b328e6

## High

- [x] **No query progress for non-ClickHouse** — fixed in 5a09f70b (shows "Executing..." text)
- [x] **Pagination has no loading indicator** — fixed in 948edbfd
- [x] **Filter preset name conflict not checked** — fixed in 85d66dfb
- [ ] **Filter warning icon has no tooltip** — yellow triangle on mismatched preset, no explanation (`FilterPanelView.swift:130-134`)
- [x] **No "Reset to Defaults" in most settings** — fixed in 5a09f70b (added to General settings)
- [x] **AI model fetch error has no retry button** — fixed in 85d66dfb
- [x] **Connection test success fades too fast** — fixed in 5a09f70b (shows "Connected" text)
- [x] ~~**SSH fields have hardcoded labels**~~ — already auto-localized (SwiftUI view literals)

## Medium

- [ ] **Hardcoded font sizes in Onboarding** — uses `24`, `48`, `22` instead of theme typography (`OnboardingContentView.swift:95,164,168`)
- [x] **Hardcoded orange shadow color** — fixed in 709105f8
- [ ] **No editor font size adjustment** — Explain view has zoom, SQL editor doesn't (`QueryEditorView.swift`)
- [ ] **No "Run Selection" in editor** — must execute entire query (`QueryEditorView.swift`)
- [x] **No Format Selection in context menu** — fixed in d8b328e6
- [ ] **Export dialog fixed size** — `720x500`, doesn't adapt to smaller screens (`ExportDialog.swift:84`)
- [x] **Export format picker has no descriptions** — fixed in 709105f8
- [ ] **No success toast for small operations** — filter preset save, theme duplicate are silent (`FilterPanelView.swift`, `ThemeEditorView.swift`)
- [x] **Pro features not labeled in Settings** — fixed in 709105f8
- [x] ~~**Sidebar empty state not context-sensitive**~~ — already uses `tableEntityName()` per database type
- [x] **Column header tooltips missing** — fixed in d8b328e6
- [x] ~~**No keyboard shortcut hints on pagination**~~ — already has `.help("Previous Page (⌘[)")`

## Low

- [ ] No drag-and-drop for connections between groups (`WelcomeWindowView.swift`)
- [ ] No SSH key file drag-into-field (`ConnectionFormView.swift`)
- [ ] No tab drag-to-reorder
- [ ] No settings search (`SettingsView.swift`)
- [ ] No error categorization — syntax vs connection vs permission (`InlineErrorBanner.swift`)
- [x] No "Copy Error" button on error banner — fixed in d8b328e6
- [ ] No column type validation for SQL reserved words in Create Table (`CreateTableView.swift`)
- [ ] WelcomeConnectionRow lacks VoiceOver `.accessibilityElement()` (`WelcomeConnectionRow.swift:19-61`)
- [x] ~~Filter SQL preview sheet has no Copy button~~ — already exists in `SQLPreviewSheet.swift`
