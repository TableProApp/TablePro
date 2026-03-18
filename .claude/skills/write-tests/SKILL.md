---
name: write-tests
description: >
  Write regression/unit tests for TablePro. Pre-loaded with all test conventions,
  helpers, patterns, and directory structure. Eliminates codebase exploration.
  Use when asked to write tests, add test coverage, or create regression tests
  for a commit, feature, or bug fix.
---

# TablePro Test Writing Guide

Everything needed to write tests without exploring the codebase.

## Workflow

1. **Understand what changed** — read the commit diff or relevant source file(s).
2. **Identify test category** — pure logic, @MainActor, async, parsing (see patterns below).
3. **Write tests** using subagents with `isolation: "worktree"`. Launch in parallel for independent files.
4. **Lint** — `swiftlint lint --strict <test-files>`.

---

## Framework: Swift Testing

```swift
import Foundation
import Testing
@testable import TablePro
```

Import order: `Foundation` → `Testing` → `@testable import TablePro` (alphabetical, `@testable` last).

NOT XCTest. No `XCTAssert*`, no `XCTestCase`, no `setUp()`/`tearDown()`.

---

## File Template

```swift
//
//  ComponentNameTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("Component Name")
struct ComponentNameTests {
    // MARK: - Section

    @Test("Describe what behavior is verified")
    func descriptiveCamelCaseName() {
        let result = SomeType.doSomething()
        #expect(result == expected)
    }
}
```

---

## Assertions

```swift
#expect(condition)                    // basic truth
#expect(a == b)                       // equality
#expect(a != b)                       // inequality
#expect(array.isEmpty)                // empty check
#expect(array.count == 3)             // count
#expect(value != nil)                 // non-nil
#expect(value == nil)                 // nil
#expect(!condition)                   // negation
#expect(a === b)                      // identity (same reference)
Issue.record("msg")                   // non-fatal diagnostic (guard-let fallback)
```

### SQL Assertions (from SQLTestHelpers)

```swift
normalizeSQL(_ sql: String) -> String                   // collapse whitespace, trim
expectSQLContains(_ sql: String, _ substring: String)   // normalized case-insensitive contains
expectSQLEquals(_ actual: String, _ expected: String)    // normalized equality
```

### Guard + Issue.record Pattern

```swift
guard let tab = tabManager.tabs.first else {
    Issue.record("Expected a tab to be added")
    return
}
#expect(tab.tableName == "users")
```

### Pattern Matching for Enums

```swift
if case .find(let collection, let filter, _) = operation {
    #expect(collection == "users")
} else {
    Issue.record("Expected .find operation")
}
```

---

## @MainActor Rules

### REQUIRES @MainActor on the test struct:

These types are declared `@MainActor` in source — test struct MUST also be `@MainActor`:

| Type | Location |
|------|----------|
| `MainContentCoordinator` | Views/Main/ |
| `DataChangeManager` | Core/ChangeTracking/ |
| `AnyChangeManager` | Core/ChangeTracking/ |
| `StructureChangeManager` | Core/SchemaTracking/ |
| `QueryTabManager` | Models/ |
| `FilterStateManager` | Models/ |
| `ConnectionToolbarState` | Models/ |
| `MultiRowEditState` | Models/ |
| `NativeTabRegistry` | Core/Services/ |
| `RowOperationsManager` | Core/Services/ |
| `TabPersistenceService` | Core/Services/ |
| `SQLEditorCoordinator` | Views/Editor/ |
| `SQLCompletionAdapter` | Views/Editor/ |
| `SidebarViewModel` | ViewModels/ |
| `DatabaseSwitcherViewModel` | ViewModels/ |
| `AIChatViewModel` | ViewModels/ |
| `DatabaseManager` | Core/Database/ |
| `VimEngine` | Core/Vim/ |
| `VimKeyInterceptor` | Core/Vim/ |
| `AppSettingsManager` | Core/Storage/ |
| `LicenseManager` | Core/Services/ |
| `ExportService` | Core/Services/ |
| `ImportService` | Core/Services/ |

```swift
@Suite("Data Change Manager")
@MainActor
struct DataChangeManagerTests {
    @Test("Records cell change")
    func recordsCellChange() {
        // ...
    }
}
```

### Does NOT require @MainActor:

Pure logic types, generators, parsers, models, extensions, utilities:

- `SQLStatementGenerator`, `FilterSQLGenerator`, `SQLEscaping`
- `MongoDBStatementGenerator`, `MongoShellParser`, `BsonDocumentFlattener`
- `RedisStatementGenerator`, `RedisCommandParser`, `RedisKeyNamespace`, `RedisQueryBuilder`
- `CompletionEngine`, `SQLContextAnalyzer`, `SQLKeywords`
- All model structs (`TableFilter`, `PaginationState`, `ColumnInfo`, etc.)
- All extensions (`String+`, `Date+`, etc.)
- `SSHConfigParser`, `ConnectionURLParser`
- `SchemaStatementGenerator`
- `SQLFormatterService`, `SQLParameterInliner`

```swift
@Suite("SQL Escaping")
struct SQLEscapingTests {
    @Test("Single quotes doubled")
    func singleQuotesDoubled() {
        // ...
    }
}
```

### Tip: If the test creates ANY @MainActor type (even just `QueryTabManager()` as a dependency), the test struct needs `@MainActor`.

---

## Async Tests

Only needed for types with async methods. NOT required for sync @MainActor types.

```swift
@Suite("Sidebar ViewModel")
@MainActor
struct SidebarViewModelTests {
    @Test("Load tables populates list")
    func loadTablesPopulatesList() async throws {
        let vm = makeSUT()
        vm.loadTables()
        try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        #expect(!vm.isLoading)
    }
}
```

### Throws Tests

```swift
@Test("Parses find with filter")
func parsesFind() throws {
    let op = try MongoShellParser.parse("db.users.find({})")
    // ...
}
```

---

## Cleanup Patterns

### Coordinator teardown (always defer)

```swift
let coordinator = makeCoordinator()
defer { coordinator.teardown() }
```

### Singleton registry (always defer unregister)

```swift
NativeTabRegistry.shared.register(windowId: windowId, ...)
defer { NativeTabRegistry.shared.unregister(windowId: windowId) }
```

### Value types — no cleanup needed

Structs, enums, generators — no cleanup.

---

## Test Directory Mapping

| Source Path | Test Path |
|-------------|-----------|
| `TablePro/Core/Autocomplete/` | `TableProTests/Core/Autocomplete/` |
| `TablePro/Core/ChangeTracking/` | `TableProTests/Core/ChangeTracking/` |
| `TablePro/Core/Database/` | `TableProTests/Core/Database/` |
| `TablePro/Core/KeyboardHandling/` | `TableProTests/Core/KeyboardHandling/` |
| `TablePro/Core/MongoDB/` | `TableProTests/Core/MongoDB/` |
| `TablePro/Core/Redis/` | `TableProTests/Core/Redis/` |
| `TablePro/Core/SchemaTracking/` | `TableProTests/Core/SchemaTracking/` |
| `TablePro/Core/Services/` | `TableProTests/Core/Services/` |
| `TablePro/Core/SSH/` | `TableProTests/Core/SSH/` |
| `TablePro/Core/Storage/` | `TableProTests/Core/Storage/` |
| `TablePro/Core/Utilities/` | `TableProTests/Core/Utilities/` |
| `TablePro/Core/Validation/` | `TableProTests/Core/Validation/` |
| `TablePro/Core/Vim/` | `TableProTests/Core/Vim/` |
| `TablePro/Extensions/` | `TableProTests/Extensions/` |
| `TablePro/Models/` | `TableProTests/Models/` |
| `TablePro/Models/Schema/` | `TableProTests/Models/Schema/` |
| `TablePro/ViewModels/` | `TableProTests/ViewModels/` |
| `TablePro/Views/Editor/` | `TableProTests/Views/Editor/` |
| `TablePro/Views/History/` | `TableProTests/Views/History/` |
| `TablePro/Views/Main/` + `Extensions/` | `TableProTests/Views/Main/` |
| `TablePro/Views/Results/` | `TableProTests/Views/Results/` |

File naming: `ComponentNameTests.swift`

---

## TestFixtures (Helpers/TestFixtures.swift)

Factory methods with sensible defaults:

```swift
// Database
TestFixtures.makeConnection(id: UUID(), name: "Test", database: "testdb", type: .mysql)
TestFixtures.allDatabaseTypes  // [.mysql, .mariadb, .postgresql, .sqlite, .redshift, .mongodb, .redis]

// Table schema
TestFixtures.makeTableInfo(name: "test_table", type: .table)
TestFixtures.makeColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true)
TestFixtures.makeEditableColumn(name: "id", dataType: "INT", isNullable: false, autoIncrement: false, isPrimaryKey: false)
TestFixtures.makeEditableIndex(name: "idx_test", columns: ["id"], isUnique: false, isPrimary: false)
TestFixtures.makeEditableForeignKey(name: "fk_test", columns: ["id"], refTable: "ref_table", refColumns: ["id"])
TestFixtures.makeForeignKeyInfo(name: "fk_user", column: "user_id", referencedTable: "users", referencedColumn: "id")

// Change tracking
TestFixtures.makeCellChange(row: 0, col: 0, colName: "column", old: nil, new: "value")
TestFixtures.makeRowChange(row: 0, type: .update, cells: [], originalRow: nil)

// Filtering
TestFixtures.makeTableFilter(column: "id", op: .equal, value: "1", secondValue: nil, rawSQL: nil)

// Query results
TestFixtures.makeQueryResultRows(count: 10, columns: ["id", "name", "email"])
TestFixtures.makeInMemoryRowProvider(rowCount: 3, columns: ["id", "name", "email"])

// History
TestFixtures.makeHistoryEntry(id: UUID(), query: "SELECT 1", connectionId: UUID(), databaseName: "testdb", executionTime: 0.05, rowCount: 10, wasSuccessful: true)
```

---

## Common Setup Patterns

### MainContentCoordinator

```swift
private func makeCoordinator(database: String = "db_a", type: DatabaseType = .mysql) -> MainContentCoordinator {
    let connection = TestFixtures.makeConnection(database: database, type: type)
    return MainContentCoordinator(
        connection: connection,
        tabManager: QueryTabManager(),
        changeManager: DataChangeManager(),
        filterStateManager: FilterStateManager(),
        columnVisibilityManager: ColumnVisibilityManager(),
        toolbarState: ConnectionToolbarState()
    )
}

// Usage:
let coordinator = makeCoordinator()
defer { coordinator.teardown() }
```

### NativeTabRegistry

```swift
let windowId = UUID()
let connectionId = UUID()
let tab = TabSnapshot(
    id: UUID(), title: "test", query: "SELECT 1",
    tabType: .table, tableName: "users", isView: false, databaseName: "testdb"
)
NativeTabRegistry.shared.register(windowId: windowId, connectionId: connectionId, tabs: [tab], selectedTabId: tab.id)
defer { NativeTabRegistry.shared.unregister(windowId: windowId) }
```

### SQLStatementGenerator

```swift
private func makeGenerator(
    tableName: String = "users",
    columns: [String] = ["id", "name", "email"],
    primaryKeyColumn: String? = "id",
    databaseType: DatabaseType = .mysql
) -> SQLStatementGenerator {
    SQLStatementGenerator(
        tableName: tableName,
        columns: columns,
        primaryKeyColumn: primaryKeyColumn,
        databaseType: databaseType
    )
}
```

### Mock DatabaseDriver (for integration tests)

```swift
private class MockDatabaseDriver: DatabaseDriver {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? = nil
    var tablesToReturn: [TableInfo] = []
    var fetchTablesCallCount = 0

    init(connection: DatabaseConnection = TestFixtures.makeConnection()) {
        self.connection = connection
    }

    // Implement all protocol methods with minimal stubs:
    func connect() async throws {}
    func disconnect() {}
    func testConnection() async throws -> Bool { true }
    func execute(query: String) async throws -> QueryResult { .empty }
    func fetchTables() async throws -> [TableInfo] {
        fetchTablesCallCount += 1
        return tablesToReturn
    }
    func fetchColumns(table: String) async throws -> [ColumnInfo] { [] }
    func fetchAllColumns() async throws -> [String: [ColumnInfo]] { [:] }
    func fetchIndexes(table: String) async throws -> [IndexInfo] { [] }
    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo] { [] }
    // ... stub remaining protocol methods
}
```

### SidebarViewModel (with Binding tuple pattern)

```swift
@MainActor
private func makeSUT(
    tables: [TableInfo] = [],
    fetcherTables: [TableInfo] = []
) -> (vm: SidebarViewModel, tables: Binding<[TableInfo]>, ...) {
    var tablesState = tables
    let tablesBinding = Binding(get: { tablesState }, set: { tablesState = $0 })
    let fetcher = MockTableFetcher(tables: fetcherTables)
    let vm = SidebarViewModel(tables: tablesBinding, ..., tableFetcher: fetcher)
    return (vm, tablesBinding, ...)
}
```

---

## Nested @Suite Pattern

Use nested `@Suite` only for utility classes with multiple distinct method groups (like `BsonDocumentFlattener`). Most tests use flat structure.

```swift
@Suite("BSON Document Flattener")
struct BsonDocumentFlattenerTests {
    @Suite("unionColumns")
    struct UnionColumnsTests {
        @Test("Empty array returns empty columns")
        func emptyArray() { ... }
    }

    @Suite("flatten")
    struct FlattenTests {
        @Test("Single document returns all values")
        func allColumnsPresent() { ... }
    }
}
```

---

## Database Type Parameterization

Test database-specific behavior with separate test methods per type:

```swift
@Test("MySQL uses backtick escaping")
func mysqlEscaping() {
    let gen = makeGenerator(databaseType: .mysql)
    // ...
}

@Test("PostgreSQL uses double-quote escaping")
func postgresqlEscaping() {
    let gen = makeGenerator(databaseType: .postgresql)
    // ...
}
```

Or iterate with `TestFixtures.allDatabaseTypes` for shared behavior:

```swift
@Test("All database types produce valid SQL")
func allTypesValid() {
    for dbType in TestFixtures.allDatabaseTypes {
        let gen = makeGenerator(databaseType: dbType)
        let result = gen.generateStatements(...)
        #expect(!result.isEmpty, "Failed for \(dbType)")
    }
}
```

---

## Test Design Rules

1. **One behavior per `@Test`.** Keep focused.
2. **`@Test("Human description")`** — always provide a description string.
3. **Cover edge cases:** empty input, nil, boundary values, error paths.
4. **For bug fixes:** write the test that WOULD HAVE caught the bug before the fix.
5. **No mocking frameworks.** Use real objects or hand-rolled protocol mocks.
6. **No network/DB calls.** Tests run offline. Test logic only.
7. **`defer` cleanup** for singletons and coordinators.
8. **`@MainActor`** on struct when testing ANY @MainActor type (see list above).
9. **No XCTest patterns.** No `setUp()`, no `XCTAssert*`, no `XCTestCase`.
10. **Factory helpers** — create `private func make*()` when setup is >3 lines and reused.

---

## Lint After Writing

```bash
swiftlint lint --strict <test-file-paths>
```

Common violations to avoid:
- Import order (alphabetical, `@testable` last)
- Line length (warn: 180, error: 300)
- Number separators (use `10_000` not `10000`)
- Sorted imports (`Foundation` before `Testing`)
