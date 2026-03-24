# Sequel-Ace vs TablePro — Deep Comparative Analysis

> Generated: 2026-03-22 | Sequel-Ace v5.2.0 | TablePro (current main)

---

## 1. Project Overview

| Aspect           | Sequel-Ace                                 | TablePro                                           |
| ---------------- | ------------------------------------------ | -------------------------------------------------- |
| **Type**         | macOS database client (MySQL/MariaDB only) | macOS database client (multi-database)             |
| **Origin**       | Fork of Sequel Pro (~20+ years lineage)    | Built from scratch                                 |
| **Language**     | ~75% Objective-C, ~25% Swift               | 100% Swift                                         |
| **UI Framework** | AppKit + Interface Builder (XIB/NIB)       | SwiftUI + AppKit interop                           |
| **Min macOS**    | 12.0 (Monterey)                            | 14.0 (Sonoma)                                      |
| **Architecture** | Universal Binary (arm64 + x86_64)          | Universal Binary (arm64 + x86_64)                  |
| **Distribution** | Mac App Store + Homebrew (free)            | Direct download + Sparkle auto-update (commercial) |
| **License**      | MIT (open-source)                          | Proprietary (commercial)                           |

---

## 2. Database Support

| Database   | Sequel-Ace                     | TablePro                         |
| ---------- | ------------------------------ | -------------------------------- |
| MySQL      | Yes (native SPMySQL.framework) | Yes (plugin, CMariaDB)           |
| MariaDB    | Yes (via MySQL driver)         | Yes (plugin, CMariaDB)           |
| PostgreSQL | No                             | Yes (plugin, CLibPQ)             |
| Redshift   | No                             | Yes (via PostgreSQL plugin)      |
| SQLite     | No\*                           | Yes (plugin, Foundation sqlite3) |
| Redis      | No                             | Yes (plugin, CRedis)             |
| MongoDB    | No                             | Yes (plugin, CLibMongoc)         |
| ClickHouse | No                             | Yes (plugin, URLSession HTTP)    |
| SQL Server | No                             | Yes (plugin, CFreeTDS)           |
| Oracle     | No                             | Yes (plugin, OracleNIO SPM)      |
| DuckDB     | No                             | Yes (plugin, CDuckDB)            |

\*Sequel-Ace uses FMDB/SQLite internally for query history storage, not as a user-facing database driver.

**Key Difference:** Sequel-Ace is deeply specialized for MySQL/MariaDB. TablePro supports 11 database types through a modular plugin architecture.

---

## 3. Architecture Comparison

### 3.1 Application Architecture

| Aspect                   | Sequel-Ace                                    | TablePro                                                 |
| ------------------------ | --------------------------------------------- | -------------------------------------------------------- |
| **Pattern**              | Classic MVC (Cocoa)                           | MVVM + Coordinator                                       |
| **Document Model**       | SPDatabaseDocument (monolithic, ~6,665 lines) | MainContentCoordinator (split across 7+ extension files) |
| **Window Model**         | NSDocument-based, custom SPWindow             | Native macOS window tabs (tabbingIdentifier)             |
| **State Management**     | NSNotificationCenter + delegates              | Combine/ObservableObject + SwiftUI bindings              |
| **Dependency Injection** | IBOutlets + manual wiring                     | Protocol-based + environment objects                     |

### 3.2 Driver/Plugin Architecture

**Sequel-Ace:**

- Monolithic driver: SPMySQL.framework (custom Objective-C framework wrapping libmysqlclient)
- No plugin system for database drivers
- Bundle system exists but for user scripts/commands only (TextMate-style)
- QueryKit.framework for SQL query building (another custom framework)
- C libraries shipped as dynamic libraries (libmysqlclient.24.dylib, libssl.3.dylib, libcrypto.3.dylib)

**TablePro:**

- `.tableplugin` bundles loaded at runtime by PluginManager
- TableProPluginKit shared framework defines `PluginDatabaseDriver` protocol
- PluginDriverAdapter bridges plugin drivers to app's `DatabaseDriver` protocol
- C bridges per plugin (CMariaDB, CLibPQ, CFreeTDS, CLibMongoc, CRedis, CDuckDB)
- Static libraries (.a files) downloaded from GitHub Releases
- 11 Xcode targets (app + tests + PluginKit + 8 plugins)

### 3.3 Query Editor

**Sequel-Ace:**

- `SPTextView` — Custom NSTextView subclass (~3,865 lines)
- Hand-built SQL syntax highlighting via NSTextStorage
- Custom autocomplete (SPNarrowDownCompletion)
- Bracket highlighting (SPBracketHighlighter)
- Code snippets with mirroring
- SQL tokenizer (SPSQLTokenizer, flex-based lexer SPEditorTokens.l)

**TablePro:**

- CodeEditSourceEditor (SPM, tree-sitter based)
- SQLEditorCoordinator bridges all features
- Tree-sitter syntax highlighting (handled by CESS)
- CompletionEngine with SQLCompletionAdapter
- SQLContextAnalyzer for context-aware completion
- Vim key interceptor, inline AI suggestions

### 3.4 Data Grid

**Sequel-Ace:**

- `SPCopyTable` → `SPTableView` → NSTableView (Objective-C subclass chain)
- SPDataStorage wraps SPMySQLStreamingResultStore
- Inline cell editing with SPFieldEditorController
- Pagination via ContentPaginationViewController
- SPRuleFilterController for visual query builder

**TablePro:**

- DataGridView (NSTableView wrapped in SwiftUI)
- Identity-based update guard to prevent redundant reloads
- RowBuffer (class) avoids CoW on large arrays
- Generation counter pattern prevents out-of-order result flashes
- RowBuffer eviction keeps only 2 most recently-executed tabs in memory

---

## 4. Feature Comparison

### 4.1 Connection Management

| Feature                 | Sequel-Ace                                  | TablePro                                                     |
| ----------------------- | ------------------------------------------- | ------------------------------------------------------------ |
| Standard TCP/IP         | Yes                                         | Yes                                                          |
| Unix Socket             | Yes                                         | N/A (multi-db)                                               |
| SSH Tunneling           | Yes (full, with dedicated tunnel assistant) | Yes                                                          |
| SSL/TLS                 | Yes (certificate config)                    | Yes                                                          |
| AWS IAM Auth            | Yes (with MFA token)                        | No                                                           |
| Keychain Storage        | Yes                                         | Yes (ConnectionStorage)                                      |
| Color-coded Connections | Yes (7 colors)                              | Yes                                                          |
| Favorites/Groups        | Yes (tree-based, SPFavoriteNode)            | Yes                                                          |
| Connection Pooling      | Yes                                         | Yes (DatabaseManager)                                        |
| Health Monitoring       | Yes (keep-alive ping)                       | Yes (ConnectionHealthMonitor, 30s ping, exponential backoff) |
| Auto-reconnect          | Yes (retry logic)                           | Yes (exponential backoff)                                    |

### 4.2 Query Features

| Feature                | Sequel-Ace                        | TablePro                                      |
| ---------------------- | --------------------------------- | --------------------------------------------- |
| SQL Editor             | Yes (SPTextView, ~3.8K lines)     | Yes (CodeEditSourceEditor, tree-sitter)       |
| Syntax Highlighting    | Yes (NSTextStorage-based)         | Yes (tree-sitter)                             |
| Autocomplete           | Yes (SPNarrowDownCompletion)      | Yes (CompletionEngine + SQLCompletionAdapter) |
| Bracket Matching       | Yes (SPBracketHighlighter)        | Yes (CESS built-in)                           |
| Query Favorites        | Yes (SPQueryFavoriteManager)      | Yes                                           |
| Query History          | Yes (SQLiteHistoryManager, FTS)   | Yes (QueryHistoryStorage, SQLite FTS5)        |
| Multi-query Execution  | Yes (range detection)             | Yes                                           |
| MySQL Help Integration | Yes (showMySQLHelpForCurrentWord) | No                                            |
| Code Snippets          | Yes (with mirroring)              | No                                            |
| Vim Mode               | No                                | Yes (VimKeyInterceptor)                       |
| AI Suggestions         | No                                | Yes (InlineSuggestionManager)                 |
| Multi-cursor           | No                                | Yes (CodeEditSourceEditor)                    |

### 4.3 Data Viewing & Editing

| Feature                  | Sequel-Ace                               | TablePro                           |
| ------------------------ | ---------------------------------------- | ---------------------------------- |
| Table Data Grid          | Yes (SPCopyTable/NSTableView)            | Yes (DataGridView/NSTableView)     |
| Cell Editing             | Yes (inline + sheet-based)               | Yes (inline)                       |
| BLOB Handling            | Yes (hex view, image preview, QuickLook) | Yes                                |
| JSON Formatting          | Yes (SPJSONFormatter)                    | Yes                                |
| Geometry Data View       | Yes (SPGeometryDataView)                 | No                                 |
| Bit Field Editor         | Yes (visual bit toggles)                 | No                                 |
| Row Add/Duplicate/Delete | Yes                                      | Yes                                |
| Pagination               | Yes (ContentPaginationView)              | Yes                                |
| Filtering                | Yes (rule-based SPRuleFilterController)  | Yes                                |
| Copy as CSV/SQL/Tab      | Yes (SPCopyTable built-in)               | Yes                                |
| Change Tracking          | Manual                                   | Yes (DataChangeManager, undo/redo) |

### 4.4 Schema Management

| Feature                | Sequel-Ace                                  | TablePro |
| ---------------------- | ------------------------------------------- | -------- |
| View Table Structure   | Yes (SPTableStructure)                      | Yes      |
| Edit Columns           | Yes                                         | Yes      |
| Create Table           | Yes                                         | Yes      |
| View CREATE Syntax     | Yes                                         | Yes      |
| Triggers               | Yes (SPTableTriggers)                       | Yes      |
| Relations/Foreign Keys | Yes (SPTableRelations)                      | Yes      |
| Indexes                | Yes (SPIndexesController)                   | Yes      |
| User Management        | Yes (SPUserManager with Core Data)          | No       |
| Server Variables       | Yes (SPServerVariablesController)           | No       |
| Process List           | Yes (SPProcessListController, kill queries) | No       |

### 4.5 Export/Import

| Feature     | Sequel-Ace                  | TablePro                     |
| ----------- | --------------------------- | ---------------------------- |
| CSV Export  | Yes                         | Yes (plugin)                 |
| JSON Export | Yes                         | Yes (plugin)                 |
| SQL Export  | Yes (51KB implementation)   | Yes (plugin)                 |
| XML Export  | Yes                         | No                           |
| PDF Export  | Yes                         | No                           |
| HTML Export | Yes                         | No                           |
| Dot Export  | Yes (graph visualization)   | No                           |
| XLSX Export | No                          | Yes (plugin)                 |
| CSV Import  | Yes (with field mapping UI) | No (separate plugin planned) |
| SQL Import  | No                          | Yes (plugin)                 |
| MQL Import  | No                          | Yes (plugin, MongoDB)        |

### 4.6 Administrative Features

| Feature           | Sequel-Ace                  | TablePro |
| ----------------- | --------------------------- | -------- |
| User Management   | Yes (full GRANT management) | No       |
| Process List      | Yes (with kill capability)  | No       |
| Server Variables  | Yes (view/filter)           | No       |
| Database Copy     | Yes (SPDatabaseCopy)        | No       |
| Database Rename   | Yes (SPDatabaseRename)      | No       |
| Table Duplication | Yes (with data option)      | No       |
| Console/Query Log | Yes (SPConsoleMessage)      | Yes      |

### 4.7 Unique to Each

**Sequel-Ace Only:**

- MySQL-specific admin tools (user management, process list, server variables)
- Bundle/script system (TextMate-style extensibility)
- AWS IAM/RDS authentication with MFA
- Geometry data visualization
- Bit field visual editor
- AppleScript support
- PDF/HTML/XML/Dot export
- CSV import with field mapping UI
- Database copy/rename operations
- 18-language localization

**TablePro Only:**

- Multi-database support (11 database types)
- Plugin architecture for extensible drivers
- SwiftUI-based modern UI
- Vim mode in editor
- AI-powered inline suggestions
- Multi-cursor editing (via CodeEditSourceEditor)
- Tree-sitter syntax highlighting
- Redis key tree navigation
- MongoDB query builder
- XLSX export
- Sparkle auto-update
- Tab persistence with snapshot/restore
- RowBuffer memory optimization (eviction policy)

---

## 5. UI & Design

### 5.1 UI Technology

| Aspect                | Sequel-Ace                                                 | TablePro                                          |
| --------------------- | ---------------------------------------------------------- | ------------------------------------------------- |
| **Primary Framework** | AppKit + Interface Builder                                 | SwiftUI + AppKit interop                          |
| **Interface Files**   | 30 XIBs + 1 Storyboard                                     | SwiftUI views (code-only)                         |
| **SwiftUI Usage**     | None (pure AppKit)                                         | Primary UI framework                              |
| **Custom Controls**   | SPSplitView, SPWindow, SPTableView, SPTextView             | DataGridView (NSTableView wrapper), SQLEditorView |
| **Theming**           | NSAppearance (light/dark/system) + color assets (17 sets)  | SQLEditorTheme + TableProEditorTheme adapter      |
| **Editor Themes**     | Customizable via preference pane (export/import/duplicate) | Built-in theme system                             |

### 5.2 Window Architecture

**Sequel-Ace:**

- Single main window (MainWindow.xib, 1200x630 default)
- Horizontal SPSplitView: left panel (table navigator) + right panel (NSTabView with 7 tabs)
- Tabs: Structure, Content, Relations, Triggers, Custom Query, Indexes, Extended Info
- NSToolbar for navigation
- Preference window: toolbar-based 6-pane switcher

**TablePro:**

- Native macOS window tabs (each tab = separate NSWindow in tab group)
- MainContentView (SwiftUI) with sidebar + content area
- MainContentCoordinator split across 7+ extension files
- EditorTabBar (pure SwiftUI) for query tabs within each connection

### 5.3 Localization

| Aspect            | Sequel-Ace                                                                       | TablePro                             |
| ----------------- | -------------------------------------------------------------------------------- | ------------------------------------ |
| **Languages**     | 18 (en, ar, cs, de, eo, es, fr, it, ja, pt, pt-BR, ru, tr, vi, zh-Hans, zh-Hant) | 2 (en, vi via Localizable.xcstrings) |
| **Format**        | .strings files (~3,530 strings)                                                  | Localizable.xcstrings (Xcode 15+)    |
| **Documentation** | N/A (app-only)                                                                   | Mintlify docs (en + vi)              |

---

## 6. Build System & CI/CD

### 6.1 Build Configuration

| Aspect                | Sequel-Ace                                                       | TablePro                                                 |
| --------------------- | ---------------------------------------------------------------- | -------------------------------------------------------- |
| **Project Type**      | .xcodeproj (3 sub-projects)                                      | .xcodeproj (11 targets)                                  |
| **Targets**           | 4 (app, tests, xibPostprocessor, tunnelAssistant)                | 11 (app, tests, PluginKit, 8 plugins)                    |
| **SPM Dependencies**  | 6 (Alamofire, AppCenter, FMDB, PLCrashReporter, SnapKit, OCMock) | 3 (CodeEditSourceEditor, Sparkle, OracleNIO)             |
| **Custom Frameworks** | 3 (SPMySQL, QueryKit, ShortcutRecorder)                          | 1 (TableProPluginKit)                                    |
| **C Libraries**       | Dynamic (.dylib): libmysqlclient, libssl, libcrypto              | Static (.a): libmariadb, libpq, etc. via download script |
| **pbxproj Version**   | Standard                                                         | objectVersion 77 (filesystem-synced groups)              |

### 6.2 Testing

| Aspect             | Sequel-Ace                                                                                       | TablePro                                    |
| ------------------ | ------------------------------------------------------------------------------------------------ | ------------------------------------------- |
| **Test Files**     | 32 (~6,288 lines)                                                                                | Multiple (XCTest)                           |
| **Languages**      | Mixed ObjC + Swift                                                                               | Swift only                                  |
| **Mock Framework** | OCMock                                                                                           | None (protocol-based mocking)               |
| **Test Areas**     | AWS auth, string utils, JSON formatting, table filtering, sorting, DB operations, SSL validation | Redis key tree, query builders, model tests |

### 6.3 CI/CD

| Aspect              | Sequel-Ace                                      | TablePro                                        |
| ------------------- | ----------------------------------------------- | ----------------------------------------------- |
| **CI Platform**     | GitHub Actions (macOS 15, Xcode 16.2)           | GitHub Actions                                  |
| **Trigger**         | Pull requests                                   | v\* tags                                        |
| **Automation**      | Fastlane (version bump, changelog, PR creation) | Shell scripts (build-release.sh, create-dmg.sh) |
| **Release**         | App Store via Fastlane                          | DMG/ZIP + Sparkle signatures                    |
| **Crash Reporting** | AppCenter + PLCrashReporter                     | None (Sparkle only)                             |

### 6.4 Code Quality

| Aspect                    | Sequel-Ace                                | TablePro                                                |
| ------------------------- | ----------------------------------------- | ------------------------------------------------------- |
| **Linter**                | SwiftLint (lenient: file_length disabled) | SwiftLint (strict: warn 1200, error 1800) + SwiftFormat |
| **Function Body Limit**   | 120 lines                                 | 160 warn / 250 error                                    |
| **Cyclomatic Complexity** | 20                                        | 40 warn / 60 error                                      |
| **Line Length**           | Disabled                                  | 120 (SwiftFormat), 180 warn / 300 error (SwiftLint)     |
| **Force Unwrap**          | Opt-in warning                            | Banned                                                  |

---

## 7. Code Quality & Technical Debt

### 7.1 Sequel-Ace Pain Points

1. **Massive Files:**
    - SPDatabaseDocument.m: ~6,665 lines (god object)
    - SPConnectionController.m: ~180KB
    - SPCustomQuery.m: ~173KB / 3,870 lines
    - SPTableContent.m: ~198KB
    - SPTextView.m: ~3,865 lines
    - DBView.xib: 542KB (monolithic interface file)

2. **Mixed Language Complexity:**
    - Bridging header required (Sequel-Ace-Bridging-Header.h)
    - ObjC/Swift interop overhead
    - 177 header files to maintain

3. **Tightly Coupled Components:**
    - SPDatabaseDocument manages everything (connection, views, toolbar, state, undo)
    - IBOutlet-based wiring between components
    - NSNotificationCenter for cross-component communication (hard to trace)

4. **Legacy Patterns:**
    - Manual memory management patterns (even with ARC)
    - XIB-based UI (harder to diff, merge conflicts)
    - ThirdParty/ directory with vendored code (RegexKitLite, MGTemplateEngine, etc.)

### 7.2 TablePro Advantages

1. **Clean Separation:** Plugin system isolates database-specific code
2. **Modern Swift:** No ObjC interop complexity, protocol-oriented
3. **SwiftUI:** Declarative UI, code-only (easy to diff/review)
4. **Coordinator Pattern:** Split across extension files, manageable sizes
5. **Performance-Conscious:** NSString O(1) length, RowBuffer eviction, generation counters

### 7.3 Sequel-Ace Advantages

1. **Feature Maturity:** 20+ years of MySQL-specific features
2. **Admin Tools:** User management, process list, server variables
3. **Localization:** 18 languages vs TablePro's 2
4. **Battle-Tested:** Large community, extensive edge case handling
5. **Free/Open-Source:** MIT license, community contributions

---

## 8. Codebase Statistics

| Metric                   | Sequel-Ace                              | TablePro                                                    |
| ------------------------ | --------------------------------------- | ----------------------------------------------------------- |
| **Objective-C .m files** | ~160                                    | 0                                                           |
| **Objective-C .h files** | ~177                                    | 0                                                           |
| **Swift files**          | ~52                                     | Majority                                                    |
| **XIB/Storyboard files** | 31                                      | 0                                                           |
| **C bridge modules**     | 0 (dynamic libs)                        | 6 (CMariaDB, CLibPQ, CFreeTDS, CLibMongoc, CRedis, CDuckDB) |
| **Frameworks (custom)**  | 3 (SPMySQL, QueryKit, ShortcutRecorder) | 1 (TableProPluginKit)                                       |
| **SPM dependencies**     | 6                                       | 3                                                           |
| **Xcode targets**        | 4                                       | 11                                                          |
| **Test files**           | 32                                      | Multiple                                                    |
| **Supported databases**  | 2 (MySQL, MariaDB)                      | 11                                                          |
| **Supported languages**  | 18                                      | 2 (en, vi)                                                  |

---

## 9. What TablePro Can Learn from Sequel-Ace

### 9.1 Features Worth Considering

1. **MySQL Admin Tools** — User management, process list, server variable inspector
2. **Database Copy/Rename** — Administrative operations for supported databases
3. **Advanced BLOB Editing** — Hex view, bit field editor, geometry visualization
4. **Bundle/Script System** — User-extensible commands (TextMate-style)
5. **CSV Import with Field Mapping** — Visual column mapping UI
6. **AWS IAM Authentication** — For RDS connections
7. **More Export Formats** — PDF, HTML, XML for reporting
8. **AppleScript Support** — Automation for power users

### 9.2 Patterns to Avoid

1. **God objects** — SPDatabaseDocument (6,665 lines) manages everything
2. **Monolithic XIBs** — DBView.xib at 542KB is unmaintainable
3. **Mixed language** — ObjC/Swift bridging adds complexity without clear benefit
4. **Vendored dependencies** — ThirdParty/ directory with aging libraries
5. **Dynamic library shipping** — Static linking (TablePro approach) is more reliable
6. **Disabled linting rules** — file_length, line_length disabled defeats the purpose

### 9.3 Architecture Lessons

- TablePro's plugin system is far superior for multi-database support
- SwiftUI declarative UI is more maintainable than XIB-based approach
- Coordinator pattern with extensions (TablePro) scales better than monolithic document (Sequel-Ace)
- Static library linking (TablePro) is more portable than dynamic library shipping (Sequel-Ace)
- Protocol-oriented testing (TablePro) is simpler than OCMock-based mocking (Sequel-Ace)

---

## 10. Summary

**Sequel-Ace** is a mature, MySQL-specialized database client with deep admin capabilities and 20+ years of feature development. Its strength is MySQL feature completeness and community-driven localization (18 languages). Its weakness is architectural — a monolithic Objective-C codebase with massive god objects, tightly coupled components, and no database extensibility.

**TablePro** is a modern, multi-database client built with clean architecture principles. Its strength is the modular plugin system (11 databases), modern Swift/SwiftUI stack, and performance-conscious design. It trades MySQL admin depth for breadth of database support and a more maintainable codebase.

The projects target different market segments: Sequel-Ace serves MySQL power users who need deep admin tools (free), while TablePro serves developers who work across multiple databases and value modern UX (commercial).
