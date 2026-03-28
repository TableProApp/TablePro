# BigQuery Plugin — Status Tracker

## Implementation Summary

- **Plugin**: `Plugins/BigQueryDriverPlugin/` (8 files, ~3,200 lines)
- **Distribution**: Registry plugin (separately distributed)
- **Auth**: Service Account JSON, ADC (authorized_user, service_account, impersonated_service_account)
- **Protocol coverage**: 100% of PluginDatabaseDriver + DriverPlugin

---

## Completed

### Core
- [x] Plugin skeleton + metadata (BigQueryPlugin.swift)
- [x] Service Account JWT auth (RS256 via Security.framework, PKCS#8 support)
- [x] Application Default Credentials (authorized_user + service_account)
- [x] Impersonated service account ADC support
- [x] HTTP client with URLSession (BigQueryConnection.swift)
- [x] Job execution + async polling
- [x] Result pagination (multi-page, 100-page cap)
- [x] Query cancellation (HTTP task + BigQuery job cancel)
- [x] 429 rate limit retry with exponential backoff
- [x] Configurable query timeout via applyQueryTimeout

### Schema Browsing
- [x] Dataset listing (fetchSchemas)
- [x] Dataset switching (switchSchema)
- [x] Table listing with types (TABLE, VIEW, MATERIALIZED_VIEW, EXTERNAL)
- [x] Column structure with nested STRUCT/ARRAY types
- [x] Clustering indexes
- [x] Time partitioning indexes
- [x] Range partitioning indexes
- [x] Table DDL via INFORMATION_SCHEMA
- [x] View definitions (VIEWS + fallback to TABLES for materialized views)
- [x] Table metadata (rows, bytes, description)
- [x] Approximate row count
- [x] Bulk fetchAllColumns via INFORMATION_SCHEMA (with N+1 fallback)

### Query Execution
- [x] GoogleSQL queries via Jobs API
- [x] DML (INSERT/UPDATE/DELETE) with rowsAffected
- [x] DDL (CREATE/DROP/ALTER)
- [x] Dry run / EXPLAIN (cost estimation: bytes processed, billed, estimated USD)
- [x] Tagged query system for browse/filter/search (no-OFFSET pagination)
- [x] ROW_NUMBER() windowing for ad-hoc SQL pagination
- [x] LIMIT stripping (prevents double LIMIT)

### Data Types
- [x] All 16 types: INT64, FLOAT64, NUMERIC, BIGNUMERIC, BOOL, STRING, BYTES, DATE, TIME, DATETIME, TIMESTAMP, GEOGRAPHY, JSON, STRUCT, ARRAY, RANGE
- [x] TIMESTAMP epoch-seconds to ISO8601 conversion (cached formatter)
- [x] STRUCT flattened to JSON object strings
- [x] ARRAY flattened to JSON array strings
- [x] Nested STRUCT/ARRAY recursion

### Data Editing
- [x] INSERT with type-aware value formatting
- [x] UPDATE with WHERE from original row (skips STRUCT/ARRAY)
- [x] DELETE with WHERE from original row
- [x] Bool values as TRUE/FALSE
- [x] Numeric values unquoted
- [x] JSON values with JSON literal syntax
- [x] ARRAY values with bracket syntax
- [x] Single-quote escaping + null byte removal

### Filtering
- [x] All operators: =, !=, >, >=, <, <=, LIKE, NOT LIKE, IN, NOT IN, IS NULL, IS NOT NULL, CONTAINS
- [x] Type-aware filter values (bool bare, numeric unquoted)
- [x] Search via CAST AS STRING LIKE

### DDL
- [x] CREATE SCHEMA (createDatabase)
- [x] ALTER TABLE ADD COLUMN (with OPTIONS description)
- [x] ALTER TABLE DROP COLUMN
- [x] CREATE OR REPLACE VIEW template
- [x] TRUNCATE TABLE
- [x] DROP TABLE/VIEW

### Integration
- [x] DatabaseType.bigquery constant
- [x] PluginMetadataRegistry snapshot
- [x] bigquery-icon asset
- [x] Xcode target in pbxproj
- [x] CHANGELOG entry
- [x] Docs page (docs/databases/bigquery.mdx)
- [x] Docs navigation (docs.json)
- [x] Docs overview card

### Tests
- [x] BigQueryQueryBuilderTests (18 tests)
- [x] BigQueryStatementGeneratorTests (11 tests)
- [x] BigQueryTypeMapperTests (11 tests)
- [x] All 30 tests passing

---

## High Impact — Fixed

- [x] **Location not sent in job submission** — added `?location=` query param to job POST URL
- [x] **`_columnCache` key collision** — keyed by `dataset.table` (all 9 occurrences updated)
- [x] **BIGNUMERIC overflow** — replaced Double parsing with regex validation
  - Fix: For NUMERIC/BIGNUMERIC, validate with regex `^-?\d+(\.\d+)?$` instead of Double parsing

- [x] **BYTES editing broken** — added `FROM_BASE64('...')` literal encoding
- [x] **No `maximumBytesBilled`** — added `bqMaxBytesBilled` connection field + query config
- [x] **DML on external tables** — checks table type, returns nil for EXTERNAL
- [x] **Ping costs money** — replaced `SELECT 1` with zero-cost `datasets.list?maxResults=0`
- [x] **Dead code in formatValue JSON branch** — removed redundant if condition

---

## Medium Impact — Fixed

- [x] Exponential backoff for polling (500ms → 1s → 2s → 4s → 5s cap)
- [x] Schema cache TTL (5 min, `CachedResource` with timestamp)
- [x] Table metadata: labels, expiration, creation time, range partitioning in comment
- [x] `creationTime`/`lastModifiedTime` forwarded to PluginTableMetadata
- [x] Partition filter error guidance (detects "partition" in error, adds tip)
- [x] Dead code in formatValue JSON branch removed
- [x] `castColumnToText` → `CAST(column AS STRING)`
- [x] `systemSchemaNames` → `["INFORMATION_SCHEMA"]`

## Medium Impact — Won't Fix (Design Limitations)

- `fetchRowCount` doubles query cost — inherent to BigQuery, no cheaper alternative
- Large result memory (1M rows) — needs streaming/disk, major refactor
- Routines (UDFs/stored procedures) invisible — needs new API endpoints + protocol changes
- ML models invisible — needs new API endpoints

---

## Low Impact — Edge Cases

- [ ] Table snapshots shown as regular tables (type "SNAPSHOT" → "TABLE")
- [ ] `systemSchemaNames` not set (INFORMATION_SCHEMA not filtered)
- [ ] Fire-and-forget Task in cancelCurrentRequest (holds strong ref)
- [ ] URL paths not percent-encoded (low risk — BQ IDs are alphanumeric)
- [ ] Single-project browsing only (multi-project requires separate connections)
- [ ] Multi-statement scripts (BEGIN...END) limited result handling
- [ ] IN/NOT IN filter splits comma-containing string values (UI limitation)
- [ ] STRUCT/ARRAY editing requires exact BigQuery literal syntax (no validation/guidance)
- [ ] Wildcard table queries only via raw SQL

---

## Out of Scope (admin/infrastructure features)

- Reservation/slot management
- BI Engine configuration
- Data transfer configs
- Authorized views/datasets management
- Row-level security policies
- Column-level security (policy tags)
- Search index management
- Table cloning
- OAuth 2.0 browser flow
- Workload Identity Federation (external_account ADC)
- GCE metadata server token
