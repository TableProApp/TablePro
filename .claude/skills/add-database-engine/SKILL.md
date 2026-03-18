---
name: add-database-engine
description: >
  Guided implementation for adding a new database engine to TablePro.
  Pre-loaded with all integration points, file locations, patterns, and
  the complete checklist derived from Redis implementation experience.
  Use when asked to add support for a new database type (e.g., Cassandra, DynamoDB, ClickHouse).
autoTrigger:
  - "add.*database.*support"
  - "new.*database.*engine"
  - "implement.*driver"
---

# Add New Database Engine to TablePro

Complete guide for adding a new database engine, based on the Redis implementation (35 files, 103+ integration points across 41 files).

## Overview: What a New Engine Requires

| Layer | Files to Create | Files to Modify |
|-------|----------------|-----------------|
| C Bridge (if native lib) | `CNewDB/` module | `project.pbxproj`, `Libs/` |
| Connection | `NewDBConnection.swift` | — |
| Driver | `NewDBDriver.swift`, `+ResultBuilding.swift` | `DatabaseDriver.swift` |
| Core Utilities | `NewDBCommandParser.swift`, `NewDBQueryBuilder.swift`, `NewDBStatementGenerator.swift` | — |
| Models | — | `DatabaseConnection.swift`, `ExportModels.swift`, `QueryTab.swift` |
| Services | — | `ColumnType.swift`, `SQLDialectProvider.swift`, `TableQueryBuilder.swift`, `ExportService.swift`, `ImportService.swift`, `SQLEscaping.swift`, `FilterSQLGenerator.swift` |
| Change Tracking | — | `DataChangeManager.swift`, `SQLStatementGenerator.swift` |
| Coordinator | `MainContentCoordinator+NewDB.swift` | `MainContentCoordinator.swift`, `+Navigation.swift`, `+TableOperations.swift`, `+SidebarSave.swift` |
| Views | — | `ConnectionFormView.swift`, `TableProToolbarView.swift`, `SidebarView.swift`, `DataGridView.swift`, `ExportDialog.swift`, `FilterPanelView.swift`, `SQLEditorView.swift`, `HighlightedSQLTextView.swift`, `SQLReviewPopover.swift`, `TypePickerContentView.swift`, `StructureRowProvider.swift` |
| AI | — | `AISchemaContext.swift`, `AIPromptTemplates.swift`, `AIChatPanelView.swift` |
| Other | — | `ContentView.swift`, `MainContentView.swift`, `Theme.swift`, `ConnectionURLParser.swift`, `ConnectionURLFormatter.swift`, `SQLParameterInliner.swift`, `SchemaStatementGenerator.swift` |
| Tests | `NewDBTests/` directory | `TestFixtures.swift`, `DatabaseTypeTests.swift` |
| Docs | `docs/databases/newdb.mdx`, `docs/vi/databases/newdb.mdx` | `docs/docs.json`, `docs/databases/overview.mdx`, `docs/vi/databases/overview.mdx` |
| Build | `scripts/build-newdb-lib.sh` (if native) | `scripts/ci/prepare-libs.sh`, `scripts/build-release.sh` |

---

## Phase 1: Foundation (C Bridge + Connection + Driver)

### 1a. C Bridge (only if using a C library)

Create `TablePro/Core/Database/CNewDB/`:
```
CNewDB/
├── CNewDB.h              # Umbrella header
├── module.modulemap       # Swift module map
└── include/
    └── newdb/             # C library headers
```

**module.modulemap pattern:**
```c
module CNewDB {
    umbrella header "CNewDB.h"
    export *
    link "newdb"           // Links against libNewDB.a
}
```

**Build static libs** — create `scripts/build-newdb-lib.sh`:
- Build for arm64 and x86_64 separately
- Create universal binary with `lipo -create`
- Output to `Libs/libnewdb_universal.a`

**Update Xcode project** — add to `project.pbxproj`:
- Add CNewDB files to project
- Add `Libs/libnewdb*.a` to Link Binary With Libraries
- Add header search paths

### 1b. Connection Class

**Create:** `TablePro/Core/Database/NewDBConnection.swift`

Pattern from `RedisConnection.swift`:
```swift
import Foundation
import OSLog
import CNewDB  // if C bridge

final class NewDBConnection: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "NewDBConnection")

    private let host: String
    private let port: Int
    // ... connection parameters

    func connect() throws { ... }
    func disconnect() { ... }
    func execute(_ command: String) throws -> NewDBReply { ... }
}
```

### 1c. Driver

**Create:** `TablePro/Core/Database/NewDBDriver.swift`

Must conform to `DatabaseDriver` protocol. Key methods:
```swift
final class NewDBDriver: DatabaseDriver {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .disconnected
    var serverVersion: String?

    // Required protocol methods:
    func connect() async throws
    func disconnect()
    func testConnection() async throws -> Bool
    func applyQueryTimeout(_ seconds: Int) async throws
    func execute(query: String) async throws -> QueryResult
    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult
    func fetchRowCount(query: String) async throws -> Int
    func fetchRows(query: String, offset: Int, limit: Int) async throws -> QueryResult
    func fetchTables() async throws -> [TableInfo]
    func fetchColumns(table: String) async throws -> [ColumnInfo]
    func fetchAllColumns() async throws -> [String: [ColumnInfo]]
    func fetchIndexes(table: String) async throws -> [IndexInfo]
    func fetchTableMetadata(table: String) async throws -> TableMetadata?
    func fetchDatabases() async throws -> [String]
    func switchDatabase(_ name: String) async throws
    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo]
    func fetchTriggers(table: String) async throws -> [TriggerInfo]
}
```

**Create:** `TablePro/Core/Database/NewDBDriver+ResultBuilding.swift`

For non-SQL databases, build virtual table results:
```swift
extension NewDBDriver {
    func buildBrowseResult(items: [...]) -> QueryResult {
        // Map native data to columns/rows/columnTypes
        QueryResult(
            columns: ["col1", "col2", ...],
            rows: mappedRows,
            columnTypes: [.text(rawType: "String"), ...],
            affectedRows: count,
            metadata: nil
        )
    }
}
```

**Column types for custom badges** — use rawType to customize `ColumnType.badgeLabel`:
```swift
// In ColumnType.swift badgeLabel:
case .text(let rawType):
    return rawType == "NewDBRaw" ? "custom-label" : "string"
```

---

## Phase 2: Model & Enum Integration

### 2a. DatabaseType enum

**File:** `TablePro/Models/DatabaseConnection.swift` (~line 100)

Add case to `DatabaseType`:
```swift
case newdb = "NewDB"
```

Then update ALL switch statements on DatabaseType. Search with:
```
Grep pattern="switch.*self|case \\.mysql" path="TablePro/"
```

Properties to add in `DatabaseType`:
- `iconName` → asset name
- `displayName` → localized display name
- `defaultPort` → default connection port
- `quoteIdentifier(_:)` → identifier quoting style
- `connectionURLScheme` → URL scheme for connection strings

### 2b. DatabaseConnection

Add any engine-specific connection properties (e.g., `redisDatabase: Int` for Redis).

### 2c. ExportModels

**File:** `TablePro/Models/ExportModels.swift`
- Add export format support or exclusions for the new engine

### 2d. QueryTab

**File:** `TablePro/Models/QueryTab.swift`
- Add any engine-specific tab properties (e.g., `columnEnumValues` for Redis Type dropdown)

---

## Phase 3: Core Services

### 3a. ColumnType badges

**File:** `TablePro/Core/Services/ColumnType.swift`
- Add rawType-based badge overrides in `badgeLabel` computed property

### 3b. SQLDialectProvider

**File:** `TablePro/Core/Services/SQLDialectProvider.swift`
- Add dialect for the new engine (keywords, functions, operators)

### 3c. TableQueryBuilder

**File:** `TablePro/Core/Services/TableQueryBuilder.swift`
- Add query building logic for browsing tables/data

### 3d. SQLEscaping

**File:** `TablePro/Core/Database/SQLEscaping.swift`
- Add escaping rules for the new engine's syntax

### 3e. FilterSQLGenerator

**File:** `TablePro/Core/Database/FilterSQLGenerator.swift`
- Add filter generation for the new engine

### 3f. Import/Export Services

**Files:** `ExportService.swift`, `ImportService.swift`
- Add support or explicit exclusion for the new engine

---

## Phase 4: Change Tracking

### 4a. Statement Generator

For SQL databases, modify `SQLStatementGenerator.swift`.

For non-SQL databases, create a dedicated generator:
**Create:** `TablePro/Core/NewDB/NewDBStatementGenerator.swift`

Pattern from `RedisStatementGenerator.swift`:
```swift
struct NewDBStatementGenerator {
    static func generateInsert(...) -> String { ... }
    static func generateUpdate(...) -> String { ... }
    static func generateDelete(...) -> String { ... }
}
```

### 4b. DataChangeManager

**File:** `TablePro/Core/ChangeTracking/DataChangeManager.swift`
- Add engine-specific logic in `configureForTable` if needed
- Ensure `generateSQL()` routes to the correct statement generator

### 4c. Sidebar Save

**File:** `TablePro/Views/Main/Extensions/MainContentCoordinator+SidebarSave.swift`

CRITICAL: The right sidebar has `.keyboardShortcut("s", modifiers: .command)` which intercepts Cmd+S. The sidebar's `saveSidebarEdits()` must handle the new engine:

```swift
if connection.type == .newdb {
    // Generate engine-specific commands
    statements += generateSidebarNewDBCommands(...)
} else {
    // Existing SQL path
}
```

---

## Phase 5: Coordinator Integration

### 5a. MainContentCoordinator

**File:** `TablePro/Views/Main/MainContentCoordinator.swift`

Key integration points (search for `case .redis` to find all):

1. **~L381 explain prefix**: Add case for explain/analyze
2. **~L420 extractTableName**: Non-SQL engines need custom table name extraction
3. **~L1329 applyPhase1Result**: Set `isEditable`, `tableName`, `columnEnumValues`
4. **~L1361 configureForTable fallback**: Configure changeManager for engines without metadata

### 5b. Navigation

**File:** `TablePro/Views/Main/Extensions/MainContentCoordinator+Navigation.swift`
- Add navigation logic (sidebar click → query builder → browse data)

**Create:** `TablePro/Views/Main/Extensions/MainContentCoordinator+NewDB.swift`
- Engine-specific coordinator methods

### 5c. Table Operations

**File:** `TablePro/Views/Main/Extensions/MainContentCoordinator+TableOperations.swift`
- Add support for create/drop/rename operations

---

## Phase 6: Views & UI

### 6a. Connection Form

**File:** `TablePro/Views/Connection/ConnectionFormView.swift`
- Add engine-specific fields (e.g., database selector for Redis db0-db15)

### 6b. Toolbar

**File:** `TablePro/Views/Toolbar/TableProToolbarView.swift`
- Hide/show toolbar items based on engine capabilities
- Example: Redis hides Connection Switcher and Database Switcher buttons

### 6c. Menu Bar

**File:** `TablePro/TableProApp.swift`
- Disable irrelevant menu items (e.g., "Open Database..." for Redis)

### 6d. Data Grid

**File:** `TablePro/Views/Results/DataGridView.swift`
- Handle engine-specific cell editing rules
- Handle enum dropdown for custom column types

### 6e. Other Views

Files that commonly need `case .newdb` handling:
- `SidebarView.swift` — sidebar display logic
- `FilterPanelView.swift` — filter UI
- `ExportDialog.swift` — export options
- `SQLEditorView.swift` — editor configuration
- `HighlightedSQLTextView.swift` — syntax highlighting
- `SQLReviewPopover.swift` — SQL preview
- `TypePickerContentView.swift` — type picker
- `StructureRowProvider.swift` — structure view
- `MainEditorContentView.swift` — editor content area
- `ContentView.swift` — app layout
- `MainContentView.swift` — main view

---

## Phase 7: AI Integration

- `AISchemaContext.swift` — schema context for AI
- `AIPromptTemplates.swift` — prompt templates
- `AIChatPanelView.swift` — chat panel

---

## Phase 8: Utilities

- `ConnectionURLParser.swift` — parse connection URLs
- `ConnectionURLFormatter.swift` — format connection URLs
- `SQLParameterInliner.swift` — parameter inlining
- `SchemaStatementGenerator.swift` — schema DDL generation
- `SQLCompletionProvider.swift` — autocomplete
- `Theme.swift` — engine-specific theming

---

## Phase 9: Tests

Create test directory: `TableProTests/Core/NewDB/`

Required test files (pattern from Redis):
- `NewDBCommandParserTests.swift`
- `NewDBQueryBuilderTests.swift`
- `NewDBStatementGeneratorTests.swift`
- `ColumnTypeNewDBTests.swift`
- `ExportModelsNewDBTests.swift`

Also update:
- `TableProTests/Models/DatabaseTypeTests.swift`
- `TableProTests/Helpers/TestFixtures.swift`

---

## Phase 10: Documentation

1. Create `docs/databases/newdb.mdx` and `docs/vi/databases/newdb.mdx`
2. Update `docs/docs.json` — add page to navigation
3. Update `docs/databases/overview.mdx` and `docs/vi/databases/overview.mdx`
4. Update `docs/features/import-export.mdx` if applicable

---

## Phase 11: Build & CI

1. Update `scripts/ci/prepare-libs.sh` — download/build native libs
2. Update `scripts/build-release.sh` — include new libs in release
3. Update `project.pbxproj` — add all new files to Xcode project

---

## Implementation Strategy

Use subagents with `isolation: "worktree"` for parallel work:

**Wave 1 (Foundation):** C Bridge + Connection + Driver (sequential, depends on each other)
**Wave 2 (Models — parallel):**
- Agent A: `DatabaseConnection.swift` + `DatabaseType` enum updates
- Agent B: `ColumnType.swift` + `ExportModels.swift`
- Agent C: Core utilities (Parser, QueryBuilder, StatementGenerator)

**Wave 3 (Integration — parallel):**
- Agent A: `MainContentCoordinator.swift` + extensions
- Agent B: `DataChangeManager.swift` + `SQLStatementGenerator.swift` + `SidebarSave.swift`
- Agent C: Services (`SQLDialectProvider`, `TableQueryBuilder`, `SQLEscaping`, `FilterSQLGenerator`)

**Wave 4 (Views — parallel):**
- Agent A: `ConnectionFormView.swift` + `TableProToolbarView.swift` + `TableProApp.swift`
- Agent B: `DataGridView.swift` + `SidebarView.swift` + `FilterPanelView.swift`
- Agent C: Remaining views (editor, export, structure, AI)

**Wave 5 (Tests + Docs — parallel):**
- Agent A: All test files
- Agent B: Documentation files

**Wave 6 (Build verification):**
```bash
xcodebuild -project TablePro.xcodeproj -scheme TablePro -configuration Debug build -skipPackagePluginValidation
xcodebuild -project TablePro.xcodeproj -scheme TablePro test -skipPackagePluginValidation
swiftlint lint --strict
```

---

## Lessons from Redis Implementation

1. **Sidebar Cmd+S intercepts menu bar Cmd+S** — the right sidebar's `.keyboardShortcut("s")` takes priority. `saveSidebarEdits()` must handle the new engine, not just the main save path.

2. **`extractTableName(from:)` returns nil for non-SQL** — preserve `tableName` from the tab for non-SQL engines instead of parsing SQL.

3. **`configureForTable` requires metadata** — non-SQL engines won't have `metadata?.primaryKeyColumn`. Add a fallback to manually configure the changeManager with a known primary key.

4. **Toolbar items with `.opacity(0)` still occupy space** — use conditional `if` to completely remove toolbar items, not `.opacity(0)` or `.hidden()`.

5. **xcodebuild and Xcode IDE use different DerivedData** — debug logging may not appear if building with one but running with the other.

6. **Every `switch` on `DatabaseType` must be updated** — there are 100+ switch sites. Use `Grep pattern="case \\.mysql" path="TablePro/"` to find them all.

7. **Column type rawType drives badge labels** — use custom rawType strings (e.g., "RedisRaw", "RedisInt") and override in `ColumnType.badgeLabel` rather than adding new enum cases.

8. **`.enumType` column type triggers dropdown picker** — set `columnEnumValues[columnName]` on the tab to populate the picker values.

---

## Quick Reference: File Count by Category

| Category | New Files | Modified Files |
|----------|-----------|----------------|
| Database Core | 3-5 | 2 |
| Models | 0 | 3-4 |
| Services | 0-1 | 6-8 |
| Change Tracking | 1 | 2-3 |
| Coordinator | 1 | 4-5 |
| Views | 0 | 12-15 |
| AI | 0 | 3 |
| Utilities | 0 | 4-6 |
| Tests | 5-8 | 2 |
| Docs | 2 | 4 |
| Build/CI | 1-2 | 2-3 |
| **Total** | **~15-20** | **~45-55** |
