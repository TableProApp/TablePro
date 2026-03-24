# What TablePro Can Learn from Sequel-Ace

> Analysis date: 2026-03-22 | Source: Deep codebase analysis of Sequel-Ace v5.2.0

This document captures actionable features, patterns, and architectural ideas from Sequel-Ace that could improve TablePro. Each item includes implementation notes, effort estimates, and priority ranking.

---

## Table of Contents

1. [Advanced Field Editor](#1-advanced-field-editor)
2. [Template-Driven Filter Operator System](#2-template-driven-filter-operator-system)
3. [CSV Import with Field Mapping](#3-csv-import-with-field-mapping)
4. [Database Admin Tools](#4-database-admin-tools)
5. [Streaming Result & Lazy Conversion](#5-streaming-result--lazy-conversion)
6. [Export Pipeline Improvements](#6-export-pipeline-improvements)
7. [Script/Command Extensibility](#7-scriptcommand-extensibility)
8. [Geometry Data Visualization](#8-geometry-data-visualization)
9. [SSH Tunnel Improvements](#9-ssh-tunnel-improvements)
10. [Design Patterns Worth Adopting](#10-design-patterns-worth-adopting)
11. [Priority Matrix](#11-priority-matrix)
12. [Implementation Tracking](#12-implementation-tracking)

---

## 1. Advanced Field Editor

**Status**: Not started
**Effort**: Medium | **Impact**: High
**Sequel-Ace reference**: `Source/Controllers/SubviewControllers/SPFieldEditorController.h/m`

### Current State (TablePro)

TablePro has basic cell editing — inline text editing in the data grid. No dedicated modal editor for complex data types.

### What Sequel-Ace Does

A 5-mode tabbed field editor sheet:

#### 1.1 Hex Editor

- Formatted hex dump: `ADDRESS  HEX_BYTES  ASCII_REPRESENTATION` (16 bytes/line)
- Non-printable bytes shown as `.`
- Bidirectional: binary data → hex display, hex input → binary data
- Supports MySQL `X'...'` syntax, `0x...` prefix, plain hex
- Lazy-loaded on demand (only renders when user clicks hex tab)

**Sequel-Ace reference**: `Source/Other/CategoryAdditions/SPDataAdditions.m` lines 331-544

**Implementation notes for TablePro**:
- SwiftUI view with `Canvas` or monospaced `Text` grid
- `Data` extension for hex formatting/parsing
- Editable hex input field with validation
- Could use existing `NSViewRepresentable` pattern for performance on large BLOBs

#### 1.2 Bit Field Editor

- 64 individual toggle buttons (one per bit)
- Synchronized representations: decimal, hexadecimal, octal text fields
- Bit operations: Set All, Clear All, Negate, Shift Left/Right, Rotate Left/Right
- NULL support with dedicated toggle

**Implementation notes for TablePro**:
- SwiftUI `Grid` layout with `Toggle` buttons (no need for 64 IBOutlets)
- `@State var bits: UInt64` as single source of truth
- Computed properties for decimal/hex/octal display
- Toolbar with operation buttons

#### 1.3 JSON Formatter

- Custom tokenizer preserving float precision and key ordering
- `NSJSONSerialization` rounds floats and reorders keys — Sequel-Ace avoids this
- Configurable indentation (tabs or 1-32 spaces)
- Format/unformat toggle (pretty-print ↔ compact)

**Sequel-Ace reference**: `Source/Other/Parsing/SPJSONFormatter.h/m`

**Implementation notes for TablePro**:
- Could use tree-sitter JSON grammar (already have tree-sitter via CESS)
- Or a custom Swift tokenizer that preserves numeric precision
- Integrate with existing CodeEditSourceEditor for syntax highlighting

#### 1.4 Image/BLOB Preview with QuickLook

- Detects file type from BLOB data (images, PDFs, audio, video, Word docs)
- Temp file creation + `QLPreviewPanel` for instant preview
- Drag-and-drop image import
- Paste from clipboard
- User-extensible type list via preferences (`EditorQuickLookTypes.plist`)

**Sequel-Ace reference**: `Resources/EditorQuickLookTypes.plist`

**Built-in preview types**:
| Type | Extension |
|------|-----------|
| Image | icns |
| Sound | m4a, mp3, wav |
| Movie | mov |
| PDF | pdf |
| HTML | html |
| Word | doc, docx |
| RTF | rtf |

**Implementation notes for TablePro**:
- Use `QLPreviewPanel` (AppKit) or `QuickLookPreview` (SwiftUI, macOS 13+)
- File type detection via `UTType` from first N bytes (magic bytes)
- Temp file in `NSTemporaryDirectory()` with alternating names to avoid cache

#### 1.5 Geometry Visualization

See [Section 8](#8-geometry-data-visualization) for dedicated coverage.

### Proposed TablePro Architecture

```
FieldEditorView (SwiftUI Sheet)
├── Picker: [Text, Hex, Image, JSON, Bit]
├── TextEditorTab
│   └── CodeEditSourceEditor (reuse existing)
├── HexEditorTab
│   └── HexDumpView (Canvas-based, monospaced)
├── ImagePreviewTab
│   └── QLPreviewPanel / QuickLookPreview
├── JSONEditorTab
│   └── CodeEditSourceEditor with JSON grammar
└── BitEditorTab
    └── BitFieldGrid (SwiftUI Grid + Toggle)
```

**Data flow**: Cell double-click → detect type → open appropriate tab → edit → validate → return to DataChangeManager.

---

## 2. Template-Driven Filter Operator System

**Status**: Not started
**Effort**: Medium | **Impact**: High
**Sequel-Ace reference**: `Source/Controllers/SubviewControllers/SPRuleFilterController.h/m`, `Resources/Plists/ContentFilters.plist`

### Current State (TablePro)

TablePro has basic text-based filtering. No type-aware operators, no visual rule builder, no nested AND/OR logic.

### What Sequel-Ace Does

#### 2.1 Operator Definition via Plist/JSON

Each filter operator is a template:

```json
{
  "MenuLabel": "contains",
  "NumberOfArguments": 1,
  "Clause": "LIKE $BINARY '%${}%'",
  "ConjunctionLabels": [],
  "Tooltip": "Searches for values containing the given text"
}
```

**Template placeholders**:
- `${}` → user argument (escaped, quoted)
- `$CURRENT_FIELD` → backtick-quoted column name
- `$BINARY` → `BINARY` keyword (if case-sensitive) or empty string

**Type-to-operator mapping**:

| Column Type | Operators |
|------------|-----------|
| `string` | =, ≠, LIKE, NOT LIKE, contains, starts with, ends with, REGEXP, IN, BETWEEN, IS NULL, IS NOT NULL, is empty |
| `number` | =, ≠, >, <, ≥, ≤, IN, LIKE, BETWEEN, IS NULL, IS NOT NULL |
| `date` | =, ≠, is after, is before, ≥, ≤, BETWEEN, IS NULL, IS NOT NULL |
| `spatial` | MBRContains, MBRWithin, MBRDisjoint, MBREqual, MBRIntersects, MBROverlaps, MBRTouches, IS NULL, IS NOT NULL |

#### 2.2 User-Extensible

- Custom operators saved globally (UserDefaults) or per-document
- Layering: bundled defaults → global custom → document custom
- Users can add operators without code changes

#### 2.3 Visual Rule Builder (NSRuleEditor)

- Nested AND/OR groups with visual indentation
- Per-rule enable/disable checkbox (tri-state hierarchy)
- Column selector → type-aware operator dropdown → argument fields
- Flattening pass eliminates redundant nesting before SQL generation

#### 2.4 Quick Filter Table

- Grid: one column per DB column, type filter directly
- Auto-detects operators from input: `">= 100"` → `field >= '100'`, `"NULL"` → `IS NULL`
- Same-row = AND, multiple-rows = OR
- DISTINCT and NEGATE toggles
- Live search mode (filter on every keystroke)
- Configurable default operator per session

#### 2.5 SQL Generation Pipeline

```
Rule Editor rows
  → Serialize to intermediate dict (filterClass, column, operator, values)
  → Flatten (merge redundant AND/OR groups)
  → Recursive SQL generation with proper parenthesization
  → SPTableFilterParser handles escaping and placeholder substitution
```

### Proposed TablePro Architecture

```
FilterOperators/
├── FilterOperatorDefinition.swift   // Codable struct matching template format
├── FilterOperatorRegistry.swift     // Loads from JSON, keyed by DatabaseType + column type
├── Dialects/
│   ├── mysql-filters.json
│   ├── postgresql-filters.json      // ILIKE, ~, ~*, SIMILAR TO, etc.
│   ├── sqlite-filters.json          // GLOB, LIKE (case-insensitive by default)
│   ├── mongodb-filters.json         // $regex, $gt, $lt, $in, etc.
│   └── redis-filters.json           // Pattern matching (MATCH)
├── FilterRuleBuilder.swift          // Visual rule builder (SwiftUI)
├── FilterQuickGrid.swift            // Column-per-column quick filter
├── FilterSQLGenerator.swift         // Template → SQL with proper escaping
└── FilterPresetManager.swift        // Save/load named filter presets
```

**Key design decisions**:
- JSON files per database dialect (not one giant plist)
- `DatabaseType` extension provides `filterDialect` property
- Plugin-extensible: plugins can bundle their own filter JSON
- Backward-compatible: existing text filter becomes a "quick filter" mode

---

## 3. CSV Import with Field Mapping

**Status**: Not started
**Effort**: Medium | **Impact**: High
**Sequel-Ace reference**: `Source/Controllers/DataImport/SPFieldMapperController.h/m`, `Source/Controllers/DataImport/SPDataImport.m`

### Current State (TablePro)

TablePro has CSV export (plugin) but no CSV import with field mapping UI.

### What Sequel-Ace Does

#### 3.1 Field Mapper UI

Visual column mapping interface:

| Source CSV Column | → | Target Table Column | Operator |
|---|---|---|---|
| `email_address` | → | `email` | Import |
| `full_name` | → | `name` | Import |
| (none) | → | `created_at` | Global Value: `NOW()` |
| `old_id` | → | `id` | Match (for UPDATE) |
| `legacy_field` | → | (skip) | Do Not Import |

**Alignment modes**:
- **By Name**: auto-match source→target by column name similarity
- **By Index**: map column 1→1, 2→2, etc.
- **Custom**: manual drag-and-drop or dropdown selection

#### 3.2 Import Methods

| Method | SQL | Use Case |
|--------|-----|----------|
| INSERT | `INSERT INTO ... VALUES (...)` | New rows |
| REPLACE | `REPLACE INTO ... VALUES (...)` | Upsert by primary key |
| UPDATE | `UPDATE ... SET ... WHERE match_col = match_val` | Update existing rows |

**Advanced options**: IGNORE, DELAYED, LOW_PRIORITY, HIGH_PRIORITY, ON DUPLICATE KEY UPDATE

#### 3.3 Global Values

- SQL expressions applied to all rows: `NOW()`, `CURDATE()`, `UUID()`
- Column references: `$1 + $2` (source column 1 + column 2)
- `$N` syntax triggers SQL mode (expression not quoted)

#### 3.4 Data Type Handling

- **Geometry fields**: WKT parsing for spatial types
- **Bit fields**: integer conversion
- **Nullable numerics**: NULL handling for empty strings
- **New table mode**: creates table from CSV structure with editable column types/names

#### 3.5 Streaming Import

- 1MB chunk-based file reading
- Background thread for processing
- `SPCSVParser` for row/cell parsing
- Progress bar shows bytes processed vs total
- Error handling: Ask/Ignore/Abort on per-row errors

### Proposed TablePro Architecture

```
ImportService/
├── CSVImportController.swift        // Main import coordinator
├── FieldMapperView.swift            // SwiftUI field mapping UI
├── FieldMapping.swift               // Mapping model (source index → target column)
├── ImportMethod.swift               // INSERT/REPLACE/UPDATE enum
├── GlobalValueExpression.swift      // SQL expression for unmapped columns
├── CSVChunkReader.swift             // Streaming 1MB chunk reader
└── ImportProgressTracker.swift      // Progress reporting
```

**Plugin integration**: Import could be a new plugin capability — `PluginDatabaseDriver` gains an optional `importRows(_:into:mapping:method:)` method with default implementation generating standard SQL.

---

## 4. Database Admin Tools

**Status**: Not started
**Effort**: Low-Medium | **Impact**: Medium

### 4.1 Process List Viewer

**Sequel-Ace reference**: `Source/Controllers/SubviewControllers/SPProcessListController.h/m` (801 lines)

**Features**:
- `SHOW [FULL] PROCESSLIST` with configurable auto-refresh (1s/5s/10s/30s/custom)
- Kill Query / Kill Connection (TiDB-aware: `KILL TIDB QUERY id`)
- Real-time filtering across all columns (Id, User, Host, Db, Command, Time, State, Info)
- Save process list to file
- Toggle Process ID column, toggle full process list mode

**Implementation notes for TablePro**:
- Simple SwiftUI `Table` + `Timer.publish` for auto-refresh
- Add to `PluginDatabaseDriver` protocol: `func getProcessList() async throws -> [[String: String]]`
- Database-specific: MySQL (`SHOW PROCESSLIST`), PostgreSQL (`pg_stat_activity`), Redis (`CLIENT LIST`)
- Could be a floating panel or a tab in the main view

**Estimated effort**: 2-3 days (UI + protocol method + MySQL/PostgreSQL implementations)

### 4.2 Server Variables Inspector

**Sequel-Ace reference**: `Source/Controllers/SubviewControllers/SPServerVariablesController.h/m` (~350 lines)

**Features**:
- `SHOW VARIABLES` with real-time search
- Copy name/value/both
- Save as `.cnf` file
- Read-only display

**Implementation notes for TablePro**:
- Even simpler than Process List — just a searchable table
- Add to protocol: `func getServerVariables() async throws -> [(name: String, value: String)]`
- Database-specific: MySQL (`SHOW VARIABLES`), PostgreSQL (`SHOW ALL`), Redis (`CONFIG GET *`)

**Estimated effort**: 1-2 days

### 4.3 User/Role Manager

**Sequel-Ace reference**: `Source/Controllers/SubviewControllers/SPUserManager.h/m` (>1000 lines)

**Features**:
- Tree view: user → user@host children
- 4 tabs: General, Global Privileges, Resources, Schema Privileges
- Grant/Revoke SQL generation from checkbox matrix
- MySQL 5.7.6+ vs pre-5.7.6 password handling
- MariaDB-specific privilege mapping

**Implementation notes for TablePro**:
- Complex, database-specific — lower priority
- Could be generalized: MySQL users/grants, PostgreSQL roles/privileges, Redis ACLs
- Significant effort per database type
- Consider: is this better as a dedicated admin tool or part of a database client?

**Estimated effort**: 1-2 weeks (per database type)

### 4.4 Database Copy/Rename

**Sequel-Ace reference**: `Source/Other/DatabaseActions/SPDatabaseCopy.h/m`, `SPTableCopy.h/m`

**Features**:
- Clone database: `SHOW CREATE TABLE` + `INSERT INTO ... SELECT` for each table
- FK-aware: disables `foreign_key_checks` during copy
- Table move via `ALTER TABLE ... RENAME`
- Preserves encoding/collation

**Implementation notes for TablePro**:
- Add to protocol: `func copyDatabase(from:to:withContent:)`, `func renameDatabase(from:to:)`
- MySQL: straightforward with SHOW CREATE TABLE
- PostgreSQL: `CREATE DATABASE ... TEMPLATE source_db` (simpler)
- Could add to right-click context menu on database sidebar

**Estimated effort**: 3-5 days

---

## 5. Streaming Result & Lazy Conversion

**Status**: Not started
**Effort**: High | **Impact**: Medium
**Sequel-Ace reference**: `Frameworks/SPMySQLFramework/Source/SPMySQLStreamingResultStore.h/m`, `Source/Other/CategoryAdditions/SPDataStorage.h/m`

### What Sequel-Ace Does

#### 5.1 Three-Tier Streaming

| Tier | Memory | Access | Use Case |
|------|--------|--------|----------|
| On-demand (`SPMySQLStreamingResult`) | O(1) | Sequential only | Simple queries |
| Buffered (`SPMySQLFastStreamingResult`) | O(k) | Sequential, freed after read | Large exports |
| Full cache (`SPMySQLStreamingResultStore`) | O(n) | Random O(1) | Data grid browsing |

#### 5.2 Custom Malloc Zone

```c
dataStorage = malloc_create_zone(64 * 1024, 0);  // 64KB dedicated heap
// ... store all row data in this zone ...
malloc_destroy_zone(dataStorage);  // Instant cleanup on reload
```

- All row data in isolated heap → zone-destroy on reload = instant cleanup (no per-object deallocation)
- Capacity doubling: 100 → 200 → 400 → ... rows

#### 5.3 Variable-Size Row Metadata

Dynamically chooses metadata width based on row data size:
- Row < 255 bytes → 1 byte per field offset (UCHAR)
- Row < 65535 bytes → 2 bytes per field offset (USHORT)
- Row ≥ 65535 bytes → 8 bytes per field offset (ULONG)

Saves ~50% metadata overhead for typical small rows.

#### 5.4 Lazy String Conversion

```
Raw MySQL row (char** pointers)
  → stored as raw bytes + field lengths in result store
  → NSString/NSData conversion ONLY when cell is accessed by UI
```

Avoids allocating String objects for cells never scrolled into view.

#### 5.5 Sparse Edit Overlay (SPDataStorage)

```
cellDataAtRow:column:
  if editedRows[rowIndex] exists:
    return editedRows[rowIndex][columnIndex]   // edited copy
  else:
    return streamingStore[rowIndex][columnIndex]  // original data
```

- `NSPointerArray editedRows` — only stores rows that user has edited
- Copy-on-edit: first edit copies row from streaming store
- Unloaded columns return `SPNotLoaded` sentinel (for lazy BLOB loading)

#### 5.6 Cached Method Pointers

```c
static inline id SPMySQLResultStoreGetRow(SPMySQLStreamingResultStore* self, NSUInteger rowIndex) {
    typedef id (*SPMSRSRowFetchMethodPtr)(...);
    static SPMSRSRowFetchMethodPtr SPMSRSRowFetch;
    if (!SPMSRSRowFetch) SPMSRSRowFetch = (SPMSRSRowFetchMethodPtr)[...];
    return SPMSRSRowFetch(...);
}
```

Bypasses Objective-C message dispatch in tight loops (data grid scrolling).

### Applicability to TablePro

TablePro's `RowBuffer` already handles some of this, but could benefit from:

1. **Lazy string conversion** — store raw `Data` from database drivers, convert to `String` only when `DataGridView` requests the cell value. Biggest win for large result sets where user only scrolls through a fraction.

2. **Malloc zone isolation** — for the RowBuffer backing store. `malloc_create_zone` + `malloc_destroy_zone` on tab switch/reload is faster than deallocating thousands of individual arrays.

3. **Variable-width metadata** — if building a custom compact row format for RowBuffer.

4. **Sparse edit tracking** — instead of copying entire row arrays on edit, only store the diff. TablePro's `DataChangeManager` already tracks changes but the underlying row data could be more memory-efficient.

**Trade-off**: These are C-level optimizations that add complexity. Only worth it if profiling shows memory/performance issues with large result sets (100K+ rows).

---

## 6. Export Pipeline Improvements

**Status**: Not started
**Effort**: Medium | **Impact**: Medium
**Sequel-Ace reference**: `Source/Controllers/DataExport/SPExportController.h/m`, `Source/Controllers/DataExport/Exporters/`

### What Sequel-Ace Does Better

#### 6.1 NSOperation-Based Concurrent Export

```
SPExporter : NSOperation
├── SPCSVExporter
├── SPSQLExporter
├── SPXMLExporter
├── SPDotExporter
├── SPPDFExporter
└── SPHTMLExporter

NSOperationQueue handles concurrent multi-table exports
```

Each exporter runs as an independent operation — multiple tables export simultaneously.

#### 6.2 Streaming Export

- Uses `SPMySQLFastStreamingResult` — never buffers full table in memory
- Row-by-row write to output file
- Progress tracked by rows processed vs total

#### 6.3 Transparent Compression

- `SPFileHandle` wraps file I/O with gzip/bzip2 support
- `setCompressionFormat:` before writing — compression happens at write time
- No separate compression step needed

#### 6.4 Template-Based Filenames

Tokens for multi-file export:
- `{database}` → current database name
- `{table}` → current table name
- `{date}` → export date
- `{time}` → export time
- `{host}` → connection host

#### 6.5 Additional Export Formats

Formats TablePro doesn't have:
- **XML** — structured data with schema information
- **Dot/GraphViz** — database relationship diagrams (ER diagrams)
- **PDF** — formatted table data for printing/sharing
- **HTML** — styled table data for web viewing

### Proposed TablePro Improvements

1. **Concurrent export** — use Swift structured concurrency (`TaskGroup`) for multi-table export
2. **Streaming** — add `exportRows(streaming:)` to plugin protocol, iterate without buffering
3. **Compression** — add gzip option to export UI (use `Foundation.Data.compress`)
4. **Filename templates** — for multi-table/multi-file exports
5. **Dot/ER diagram export** — generate relationship graphs from foreign key metadata

---

## 7. Script/Command Extensibility

**Status**: Not started
**Effort**: Medium | **Impact**: Medium
**Sequel-Ace reference**: `Source/Controllers/Other/SPBundleManager.h/m`, `Source/Other/Utility/SABundleRunner.h/m`

### What Sequel-Ace Does

#### 7.1 Bundle System

Scripts stored as `.sequelbundle` directories:

```
MyCommand.sequelbundle/
├── info.plist          // metadata: name, scope, trigger, I/O config
└── command.sh          // executable script
```

#### 7.2 Execution Context

Scripts receive context via environment variables:
- `$SP_DATABASE_NAME` — current database
- `$SP_SELECTED_TABLE` — active table
- `$SP_QUERY_FILE` — path to temp file with current query/selection
- `$SP_QUERY_RESULT_FILE` — path to query result data
- `$SP_CURRENT_EDITED_COLUMN_NAME` — column being edited

Input delivered via stdin redirect from temp file.

#### 7.3 Output Disposition via Exit Code

| Exit Code | Action |
|-----------|--------|
| 200 | No action |
| 201 | Replace selection |
| 202 | Replace all content |
| 203 | Insert as text |
| 205 | Show as HTML in floating window |
| 207 | Show as text tooltip |
| 208 | Show as HTML tooltip |

#### 7.4 Scopes

Scripts bound to execution contexts:
- **QueryEditor** — runs with editor selection/content
- **DataTable** — runs with table row data
- **InputField** — runs with field editor content
- **General** — runs with no specific context

#### 7.5 HTML Output Window

- WebKit-based floating window for rich script output
- Zoom, navigation, save, print support
- Scripts can generate charts, reports, formatted data

### Proposed TablePro Architecture

```
CustomCommands/
├── CommandDefinition.swift          // name, scope, trigger, I/O config
├── CommandRunner.swift              // NSTask/Process execution
├── CommandEnvironment.swift         // Environment variable injection
├── CommandOutputHandler.swift       // Exit code → action dispatch
├── CommandManagerView.swift         // UI for managing commands
└── HTMLOutputPanel.swift            // WKWebView floating window
```

**Modern improvements over Sequel-Ace**:
- Use `Process` (Swift) instead of `NSTask` (ObjC)
- JSON-based command definitions instead of plist
- Structured concurrency for async execution
- SwiftUI settings pane for command management
- Keyboard shortcut assignment via `KeyboardShortcut`

---

## 8. Geometry Data Visualization

**Status**: Not started
**Effort**: Low | **Impact**: Low (niche but differentiating)
**Sequel-Ace reference**: `Source/Views/SPGeometryDataView.h/m`

### What Sequel-Ace Does

Renders MySQL GEOMETRY types as visual diagrams:

**Supported types**: POINT, LINESTRING, POLYGON, MULTIPOINT, MULTILINESTRING, MULTIPOLYGON, GEOMETRYCOLLECTION

**Rendering**:
- Auto-scaling to fit target dimension (default 400px)
- 10px margin border
- Color scheme: Points (red fill + gray stroke), Lines (black), Polygons (alternating cyan/lime/red with 10% alpha fill)
- NSBezierPath-based drawing
- PDF export via `-pdfData`

**Input**: WKT-parsed coordinate dictionary with `type`, `coordinates`, `bbox` keys.

### Proposed TablePro Implementation

```swift
struct GeometryView: View {
    let geometry: GeometryData  // parsed WKT

    var body: some View {
        Canvas { context, size in
            let transform = calculateTransform(bbox: geometry.bbox, targetSize: size)
            switch geometry.type {
            case .point: drawPoints(context, geometry.coordinates, transform)
            case .lineString: drawLineString(context, geometry.coordinates, transform)
            case .polygon: drawPolygon(context, geometry.coordinates, transform)
            // ... etc
            }
        }
    }
}
```

**Integration**: Show in field editor's Image tab when column type is geometry. Also useful as a cell renderer (thumbnail in data grid).

**Database support**: MySQL (WKT/WKB), PostgreSQL/PostGIS (ST_AsText, ST_AsBinary), SQLite/SpatiaLite.

---

## 9. SSH Tunnel Improvements

**Status**: Not started
**Effort**: Low-Medium | **Impact**: Low-Medium
**Sequel-Ace reference**: `Source/Other/SSHTunnel/SPSSHTunnel.h/m`, `Source/Other/SSHTunnel/SequelAceTunnelAssistant.m`

### What Sequel-Ace Does

#### 9.1 Separate Tunnel Assistant Process

- `SequelAceTunnelAssistant` is a standalone helper executable
- Acts as `SSH_ASKPASS` for interactive password/passphrase prompts
- Communicates with main app via `NSConnection` RPC (deprecated → use XPC)
- Checks Keychain first (silent auth), then prompts UI if needed

#### 9.2 Connection Muxing

- `ControlMaster=auto` with hashed control path
- Reuses SSH connections across multiple database connections to same host
- Disabled by default due to stability issues

#### 9.3 Keepalive

- `TCPKeepAlive=yes`
- `ServerAliveInterval` (configurable)
- `ServerAliveCountMax=3`

#### 9.4 Port Allocation

- Random local port via `getRandomPort()`
- Fallback port for host failover

### Applicability to TablePro

- **XPC Service** for SSH tunnel (modern replacement for NSConnection RPC)
- **Connection muxing** for users connecting to multiple databases on same host
- **Keepalive configuration** exposed in connection settings

---

## 10. Design Patterns Worth Adopting

### 10.1 Sparse Edit Overlay

**Pattern**: Only copy/store rows that the user has edited. Unedited rows read directly from the underlying result store.

**Sequel-Ace**: `NSPointerArray editedRows` — sparse array, only non-nil at edited indices.

**TablePro application**: Could optimize `DataChangeManager` to avoid duplicating entire row arrays for single-cell edits.

### 10.2 Template-Based SQL Generation

**Pattern**: Define SQL fragments as templates with placeholders, interpolate at runtime.

**Sequel-Ace**: `ContentFilters.plist` with `$CURRENT_FIELD`, `$BINARY`, `${}` placeholders.

**TablePro application**: Filter operators, query builders, statement generators. Makes SQL generation database-agnostic and user-extensible.

### 10.3 Tri-State Checkbox Hierarchy

**Pattern**: Parent checkbox reflects aggregate state of children (all checked, all unchecked, mixed).

**Sequel-Ace**: Filter rule enable/disable, with parent OR/AND groups showing mixed state.

**TablePro application**: Filter preset management, multi-select operations, column visibility toggles.

### 10.4 NSOperation Export Pipeline

**Pattern**: Each export format is an `NSOperation` subclass. Queue handles concurrency and cancellation.

**Sequel-Ace**: `SPExporter` base class → `SPCSVExporter`, `SPSQLExporter`, etc.

**TablePro application**: Use Swift `Operation` subclasses or structured concurrency `TaskGroup` for concurrent multi-table export.

### 10.5 Lazy Cell Conversion

**Pattern**: Store raw bytes from database. Convert to String/Number only when UI requests the cell value.

**Sequel-Ace**: C char arrays stored in malloc zone → NSString created on `cellDataAtRow:column:` call.

**TablePro application**: Store `Data` in RowBuffer, convert to display type in `DataGridView` cell provider. Saves memory for cells never scrolled into view.

### 10.6 Custom Malloc Zone

**Pattern**: Allocate all result data in a dedicated malloc zone. Destroy zone on result reload for instant cleanup.

**Sequel-Ace**: `malloc_create_zone(64 * 1024, 0)` per result store.

**TablePro application**: Consider for RowBuffer backing store if profiling shows deallocation overhead for large result sets.

### 10.7 Exit-Code-Driven Output Dispatch

**Pattern**: Script exit code determines what happens with the output (replace selection, show as HTML, insert as text, etc.).

**Sequel-Ace**: Exit codes 200-208 mapped to specific UI actions.

**TablePro application**: For custom command/script extensibility system.

---

## 11. Priority Matrix

| # | Feature | Effort | Impact | Priority | Dependencies |
|---|---------|--------|--------|----------|-------------|
| 1 | Template-driven filter operators | Medium (1-2 weeks) | High | **P0** | None |
| 2 | Advanced field editor (hex/JSON/bit/QL) | Medium (1-2 weeks) | High | **P0** | None |
| 3 | CSV import with field mapping | Medium (1-2 weeks) | High | **P1** | Import plugin protocol |
| 4 | Process list viewer | Low (2-3 days) | Medium | **P1** | Driver protocol addition |
| 5 | Server variables inspector | Low (1-2 days) | Medium | **P2** | Driver protocol addition |
| 6 | Export pipeline (concurrent/streaming) | Medium (1 week) | Medium | **P2** | None |
| 7 | Database copy/rename | Low-Medium (3-5 days) | Medium | **P2** | Driver protocol addition |
| 8 | Script/command extensibility | Medium (1-2 weeks) | Medium | **P3** | None |
| 9 | Geometry visualization | Low (2-3 days) | Low | **P3** | WKT parser |
| 10 | Streaming/lazy conversion | High (2-3 weeks) | Medium | **P3** | RowBuffer refactor |
| 11 | SSH tunnel improvements | Low-Medium (3-5 days) | Low | **P4** | XPC service |
| 12 | User/role manager | High (1-2 weeks per DB) | Low-Medium | **P4** | Per-database implementation |

**Priority key**: P0 = Next sprint, P1 = This quarter, P2 = Next quarter, P3 = Backlog, P4 = Nice-to-have

---

## 12. Implementation Tracking

### P0 — Next Sprint

- [ ] **Template-driven filter operators**
  - [ ] Define `FilterOperatorDefinition` Codable struct
  - [ ] Create `mysql-filters.json`, `postgresql-filters.json`, `sqlite-filters.json`
  - [ ] Implement `FilterOperatorRegistry` (loads JSON, keyed by DatabaseType + column type)
  - [ ] Implement `FilterSQLGenerator` (template interpolation with escaping)
  - [ ] Build `FilterRuleBuilderView` (SwiftUI, nested AND/OR groups)
  - [ ] Build `FilterQuickGridView` (column-per-column fast filter)
  - [ ] Integrate with existing filtering in `MainContentCoordinator+Filtering`
  - [ ] Add filter preset save/load
  - [ ] Add per-rule enable/disable checkboxes
  - [ ] Plugin support: plugins can bundle their own filter JSON

- [ ] **Advanced field editor**
  - [ ] Design `FieldEditorView` (SwiftUI sheet with tab picker)
  - [ ] Implement `HexEditorTab` (hex dump view + editable hex input)
  - [ ] Implement `JSONEditorTab` (CodeEditSourceEditor with JSON grammar)
  - [ ] Implement `BitFieldTab` (SwiftUI Grid with toggles + decimal/hex/octal sync)
  - [ ] Implement `ImagePreviewTab` (QLPreviewPanel integration)
  - [ ] Add file type detection from BLOB data (UTType magic bytes)
  - [ ] Wire up to DataChangeManager for edit flow
  - [ ] Double-click cell → detect type → open appropriate tab

### P1 — This Quarter

- [ ] **CSV import with field mapping**
  - [ ] Design `FieldMapperView` (SwiftUI)
  - [ ] Implement `CSVChunkReader` (streaming 1MB chunks)
  - [ ] Implement field alignment modes (by name, by index, custom)
  - [ ] Implement import methods (INSERT, REPLACE, UPDATE)
  - [ ] Add global value expressions (`NOW()`, `$1 + $2`)
  - [ ] Add progress tracking and error handling (ask/ignore/abort)
  - [ ] Add to `PluginDatabaseDriver` protocol: `importRows` method

- [ ] **Process list viewer**
  - [ ] Add `getProcessList()` to `PluginDatabaseDriver` protocol
  - [ ] Implement for MySQL (`SHOW PROCESSLIST`)
  - [ ] Implement for PostgreSQL (`SELECT * FROM pg_stat_activity`)
  - [ ] Implement for Redis (`CLIENT LIST`)
  - [ ] Build `ProcessListView` (SwiftUI Table + auto-refresh timer)
  - [ ] Add kill query/connection support
  - [ ] Add filtering and save-to-file

### P2 — Next Quarter

- [ ] **Server variables inspector**
  - [ ] Add `getServerVariables()` to `PluginDatabaseDriver` protocol
  - [ ] Implement for MySQL, PostgreSQL, Redis
  - [ ] Build `ServerVariablesView` (searchable SwiftUI Table)

- [ ] **Export pipeline improvements**
  - [ ] Add streaming export support to plugin protocol
  - [ ] Implement concurrent multi-table export (TaskGroup)
  - [ ] Add gzip compression option
  - [ ] Add filename template system for multi-file export

- [ ] **Database copy/rename**
  - [ ] Add protocol methods
  - [ ] Implement for MySQL, PostgreSQL
  - [ ] Add to sidebar context menu

### P3 — Backlog

- [ ] **Script/command extensibility**
  - [ ] Design command definition format (JSON)
  - [ ] Implement `CommandRunner` (Process-based execution)
  - [ ] Implement environment variable injection
  - [ ] Implement exit-code-driven output dispatch
  - [ ] Build command manager UI
  - [ ] Add HTML output panel (WKWebView)

- [ ] **Geometry visualization**
  - [ ] Implement WKT parser
  - [ ] Build `GeometryView` (SwiftUI Canvas)
  - [ ] Integrate with field editor Image tab
  - [ ] Support MySQL, PostGIS, SpatiaLite

- [ ] **Streaming/lazy conversion**
  - [ ] Profile current RowBuffer performance with 100K+ rows
  - [ ] Prototype lazy string conversion (store Data, convert on access)
  - [ ] Evaluate malloc zone isolation for RowBuffer
  - [ ] Implement sparse edit overlay if profiling justifies

### P4 — Nice-to-Have

- [ ] **SSH tunnel improvements** (XPC service, connection muxing)
- [ ] **User/role manager** (MySQL grants, PostgreSQL roles, Redis ACLs)
