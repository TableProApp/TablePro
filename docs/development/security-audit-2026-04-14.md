# TablePro Security & Production Readiness Audit

**Date:** 2026-04-14
**Scope:** Full codebase — TablePro/, Plugins/, scripts/, entitlements, dependencies

---

## Critical / High Severity

### 1. [HIGH] Raw SQL injection via URL scheme without user confirmation

- **Category:** SQL Injection
- **Files:** `TablePro/Core/Utilities/Connection/ConnectionURLParser.swift:476`, `TablePro/Views/Main/Extensions/MainContentCoordinator+URLFilter.swift:63`
- **Description:** A crafted URL such as `mysql://myconn/mydb/mytable?condition=1=1 OR DROP TABLE...` injects arbitrary SQL into WHERE clauses when clicked. The `condition`/`raw`/`query` URL parameter is passed directly as a raw SQL filter without any user confirmation dialog or sanitization. The `openQuery` deeplink path does show a confirmation dialog, but this filter path does not.
- **Impact:** An attacker who tricks a user into clicking a link can inject arbitrary SQL against a connected database.
- **Remediation:** Add user confirmation dialog for `condition`/`raw`/`query` URL parameters (matching the existing `openQuery` deeplink), or remove raw SQL passthrough from URL parsing entirely.
- [x] **Fixed** — Added `AlertHelper.confirmDestructive` gate in `AppDelegate+ConnectionHandler.swift` before posting `.applyURLFilter` with raw SQL condition. Matches existing `openQuery` deeplink pattern.

### 2. [HIGH] OpenSSL 3.4.1 is outdated — 3.4.3 patches CVE-2025-9230 and CVE-2025-9231

- **Category:** Supply Chain / Dependency
- **Files:** `scripts/build-libpq.sh:39`, `scripts/build-hiredis.sh:38`, `scripts/build-libssh2.sh:38`
- **Description:** All three build scripts use `OPENSSL_VERSION="3.4.1"`. OpenSSL 3.4.3 fixes:
  - **CVE-2025-9230**: Out-of-bounds read/write in RFC 3211 KEK Unwrap (CMS decryption), potentially enabling crashes or code execution.
  - **CVE-2025-9231**: Timing side-channel in SM2 on 64-bit ARM — could leak private key material.
  - **CVE-2025-9232**: OOB read in HTTP client `no_proxy` handling (Moderate).
- **Impact:** TablePro uses TLS in database connections (PostgreSQL, Redis, MariaDB over SSH). Real attack surface.
- **Remediation:** Update `OPENSSL_VERSION` to `3.4.3` in all three build scripts, update `OPENSSL_SHA256`, rebuild all affected libraries, update `Libs/checksums.sha256`, and upload new archives to `libs-v1` GitHub Release.
- [x] **Fixed** — Created shared `scripts/openssl-version.sh` (single source of truth) with OpenSSL 3.4.3 + SHA256. All 4 build scripts now source this file. **Note:** Libs must still be rebuilt, checksums regenerated, and archives uploaded to complete the update.

### 3. [HIGH] App sandbox disabled + library validation disabled

- **Category:** Entitlements
- **File:** `TablePro/TablePro.entitlements`
- **Description:** `com.apple.security.app-sandbox = false` and `com.apple.security.cs.disable-library-validation = true`. Necessary for the plugin system (loading third-party `.tableplugin` bundles) and arbitrary database connections, but means no OS-level containment.
- **Impact:** Any code placed in the plugin directory loads without sandbox restrictions.
- **Mitigation in place:** Plugin code signing verification via `SecStaticCodeCheckValidity` with team ID requirement for registry-installed plugins.
- **Remediation:** Accept as necessary trade-off. Ensure deeplink-triggered connections always prompt user confirmation. Document for contributor awareness. Consider adding UI warning for manually installed plugins from unknown sources.
- [x] **Acknowledged / Documented** — Architecturally necessary. Compensating controls in place: Fix #1 closes deeplink attack surface, plugin code signing + SHA-256 verification for registry plugins.

### 4. [HIGH] MySQL prepared statement: fixed 64KB buffer, no MYSQL_DATA_TRUNCATED check

- **Category:** Memory Safety / Data Integrity
- **File:** `Plugins/MySQLDriverPlugin/MariaDBPluginConnection.swift:628-675`
- **Description:** Each result column in prepared statements is allocated exactly 65,536 bytes. After `mysql_stmt_fetch`, the code never checks for `MYSQL_DATA_TRUNCATED` (return value 101). For TEXT, BLOB, JSON, or LONGTEXT columns exceeding 64KB, the caller silently reads truncated data with no error or warning. The non-prepared-statement path (`executeQuerySync`) does not have this issue.
- **Impact:** Silent data truncation for large column values. Users see incomplete data without any indication.
- **Remediation:** Check `mysql_stmt_fetch` return for `MYSQL_DATA_TRUNCATED`, reallocate buffer if needed, or use `mysql_stmt_fetch_column` to re-fetch oversized columns.
- [x] **Fixed** — Fetch loop now handles `MYSQL_DATA_TRUNCATED` (101): detects truncated columns by comparing `length > buffer_length`, reallocates buffer, and re-fetches via `mysql_stmt_fetch_column`. Error pointer allocated and cleaned up in defer block.

---

## Medium Severity

### 5. [MEDIUM] ClickHouse/Etcd TLS cert verification bypassed when sslMode="Required"

- **Category:** Network Security
- **Files:** `Plugins/ClickHouseDriverPlugin/ClickHousePlugin.swift:197-199`, `Plugins/EtcdDriverPlugin/EtcdHttpClient.swift:354-357`
- **Description:** The UI option "Required" implies TLS is required, but the code treats it as "require TLS, skip certificate validation." `InsecureTLSDelegate` accepts any server certificate unconditionally. Query results and credentials (HTTP Basic Auth) are exposed to MITM interception.
- **Remediation:** Rename the option to "Required (Skip Verify)" or "Required (self-signed)" to match actual behavior. Consider adding a "Required (Verify)" option that validates certificates.
- [x] **Fixed** — Added `displayLabel` to `SSLMode` that shows "Required (skip verify)". Updated `ConnectionSSLView` picker to use `displayLabel` instead of `rawValue`. Stored values unchanged (no migration needed).

### 6. [MEDIUM] ClickHouse credentials sent as plaintext HTTP Basic Auth when TLS disabled

- **Category:** Network Security
- **File:** `Plugins/ClickHouseDriverPlugin/ClickHousePlugin.swift:946-948`
- **Description:** When `sslMode` is "Disabled" or absent, `scheme = "http"`. Credentials are base64-encoded HTTP Basic Auth over plaintext. Trivially decoded by network attackers.
- **Remediation:** Show a warning in the connection UI when TLS is disabled and credentials are configured. Document the risk for users connecting over untrusted networks.
- [ ] **Fixed**

### 7. [MEDIUM] BigQuery column name not escaped and operator string passed verbatim

- **Category:** SQL Injection
- **File:** `Plugins/BigQueryDriverPlugin/BigQueryQueryBuilder.swift:276, 192, 209, 315`
- **Description:** `buildFilterClause` wraps column names in backticks without applying backtick escaping (unlike `quoteIdentifier`). The `default` branch interpolates `filter.op` directly without validation against an allowlist. `BigQueryFilterSpec` is a `Codable` struct that could contain any string.
- **Remediation:** Apply `quoteIdentifier` (with backtick escaping) to `filter.column`. Validate `filter.op` against a fixed allowlist of known operators.
- [x] **Fixed** — Added `quoteIdentifier()` for backtick escaping on all column names in filter, search, and sort paths. Added `allowedFilterOperators` allowlist; `default` branch returns `nil` for unknown operators.

### 8. [MEDIUM] Deeplink sql= preview truncated at 300 chars

- **Category:** Input Validation
- **Files:** `TablePro/Core/Services/Infrastructure/DeeplinkHandler.swift:46-48`, `TablePro/AppDelegate+FileOpen.swift:184`
- **Description:** The `sql` parameter from `tablepro://connect/{name}/query?sql=...` is accepted with only an empty-string check. The confirmation dialog shows only the first 300 characters. A user could approve a malicious query hidden past the preview. No length limit on accepted SQL.
- **Remediation:** Show more of the SQL in the preview or add a clear "N more characters not shown" warning. Add a hard length limit (e.g., 50KB) for SQL via deeplinks.
- [x] **Fixed** — Added 50KB hard limit, "N more characters not shown" warning when truncated.

### 9. [MEDIUM] BigQuery OAuth refresh token may persist in UserDefaults

- **Category:** Credential Storage
- **File:** `Plugins/BigQueryDriverPlugin/BigQueryConnection.swift:722`
- **Description:** `bqOAuthRefreshToken` is stored in `additionalFields` after OAuth flow completion but is never declared as a `ConnectionField` with `isSecure: true`. If it ends up in UserDefaults rather than Keychain, it's readable by any process running as the same user.
- **Remediation:** Verify persistence path. If in UserDefaults, declare the field as `isSecure` or store via `KeychainHelper` directly.
- [x] **Fixed** — Added `bqOAuthRefreshToken` as `ConnectionField` with `fieldType: .secure` to ensure Keychain storage.

### 10. [MEDIUM] Custom plugin registry URL configurable via defaults write

- **Category:** Supply Chain
- **File:** `TablePro/Core/Plugins/Registry/RegistryClient.swift:32-34`
- **Description:** The registry URL can be overridden via `defaults write` by any local process. If attacker controls the manifest, they control download URLs AND checksums, so SHA-256 verification provides no protection. Code signature verification is the last line of defense.
- **Remediation:** Require explicit UI confirmation when custom registry URL is set. Consider requiring that custom registry manifests be signed.
- [x] **Fixed** — Added warning log when custom registry URL is detected. Added `isUsingCustomRegistry` property for UI awareness.

### 11. [MEDIUM] Build scripts download source without checksum verification

- **Category:** Supply Chain
- **Files:** `scripts/build-freetds.sh:21`, `scripts/build-cassandra.sh:37-38,76`, `scripts/build-duckdb.sh:20-22`
- **Description:** FreeTDS, Cassandra (libuv + cpp-driver), and DuckDB source downloads use `curl -sL` with no SHA-256 verification before compilation. Other build scripts (libpq, hiredis, libssh2, libmongoc) correctly pin checksums.
- **Remediation:** Add SHA-256 constants for all three, matching the pattern used in `build-libpq.sh` / `build-hiredis.sh`.
- [x] **Fixed** — Added SHA-256 checksums and `shasum -a 256 -c -` verification to all three build scripts.

### 12. [MEDIUM] FreeTDS global mutable error state shared across connections

- **Category:** Thread Safety
- **File:** `Plugins/MSSQLDriverPlugin/MSSQLPlugin.swift:103-116`
- **Description:** `freetdsLastError` is a global variable protected by a lock. Error/message handlers are registered globally for all FreeTDS connections. With multiple MSSQL connections open, error messages from one connection may be attributed to another. Inherent limitation of FreeTDS C API's global callback design.
- **Impact:** Mislabeled error messages (not data corruption). Only occurs with multiple simultaneous MSSQL connections.
- **Remediation:** Document the limitation. If possible, use the `DBPROCESS*` argument in callbacks to route errors to per-connection buffers.
- [x] **Fixed** — Replaced global error string with per-DBPROCESS dictionary (`freetdsConnectionErrors`). Error/message handlers now route to the correct connection's buffer. Cleanup on disconnect via `freetdsUnregister`.

### 13. [MEDIUM] unsafeBitCast on SecIdentity without runtime type check

- **Category:** Memory Safety
- **File:** `Plugins/EtcdDriverPlugin/EtcdHttpClient.swift:1068`
- **Description:** `unsafeBitCast(identityRef, to: SecIdentity.self)` where `identityRef` is typed as `Any` from a `CFDictionary`. No runtime type check before the bitcast. If the dictionary contains an unexpected type, this is undefined behavior.
- **Remediation:** Replace with `identityRef as! SecIdentity` (descriptive crash) or check `CFGetTypeID` before casting.
- [x] **Fixed** — Replaced `unsafeBitCast` with `as! SecIdentity` for descriptive crash on type mismatch.

### 14. [MEDIUM] MainActor.assumeIsolated in notification callbacks

- **Category:** Thread Safety
- **Files:** `TablePro/Views/Results/DataGridCoordinator.swift:211,225`, `TablePro/Views/Main/MainContentCoordinator.swift:323,353,527`
- **Description:** `MainActor.assumeIsolated` is used inside `NotificationCenter` callbacks posted with `queue: .main`. If any future code path posts the same notification from a background thread without specifying `queue: .main`, this will assert/crash in debug or silently run off-actor in release.
- **Remediation:** Consider using `Task { @MainActor in }` instead, or add defensive documentation preventing background posting.
- [x] **Fixed** — Converted `themeDidChange`, `teardownObserver`, `pluginDriverObserver`, and VimKeyInterceptor popup observer to `Task { @MainActor in }`. Left `willTerminate` observer (must be synchronous) and event monitor (must be synchronous) unchanged.

### 15. [MEDIUM] Connection list stored in UserDefaults without atomic writes

- **Category:** Data Integrity
- **File:** `TablePro/Core/Storage/ConnectionStorage.swift:66-76`
- **Description:** `saveConnections` writes to UserDefaults via `defaults.set(data, forKey:)`. If the process is killed mid-write, the backing plist can corrupt. Compare with `TabDiskActor` which uses `data.write(to: fileURL, options: .atomic)`.
- **Remediation:** Migrate connection metadata to file-based JSON storage with `.atomic` writes, or document the accepted risk.
- [x] **Fixed** — Migrated `ConnectionStorage` to file-based storage at `~/Library/Application Support/TablePro/connections.json` with `.atomic` writes. One-time migration from UserDefaults on first launch.

### 16. [MEDIUM] No applicationShouldTerminate for graceful quit

- **Category:** App Lifecycle
- **File:** `TablePro/AppDelegate.swift`
- **Description:** The app implements `applicationWillTerminate` but not `applicationShouldTerminate(_:)`. No opportunity to defer quit while in-flight queries complete or unsaved changes are confirmed. Synchronous `TabDiskActor.saveSync` runs but active queries are cut off.
- **Remediation:** Implement `applicationShouldTerminate` with a check for pending unsaved edits before allowing quit.
- [x] **Fixed** — Added `applicationShouldTerminate` with `MainContentCoordinator.hasAnyUnsavedChanges()` check and confirmation alert.

### 17. [MEDIUM] Main thread blocked during first-connection plugin load race

- **Category:** Performance
- **File:** `TablePro/Core/Database/DatabaseDriver.swift:360-364`
- **Description:** `DatabaseDriverFactory.createDriver` is `@MainActor`. If `PluginManager.hasFinishedInitialLoad` is false when the user connects immediately after launch, `loadPendingPlugins()` runs synchronously on the main thread (dynamic linking + C bridge init). Multi-second UI freeze on slower machines.
- **Remediation:** Ensure plugin loading completes before enabling the connect button, or move `loadPendingPlugins()` off the main thread.
- [x] **Fixed** — Added async `createDriver(awaitPlugins:)` overload that awaits `PluginManager.waitForInitialLoad()` via continuation instead of blocking. All async callers updated. Sync fallback preserved.

### 18. [MEDIUM] Stale plugin rejection not surfaced in UI

- **Category:** Production UX
- **File:** `TablePro/Core/Plugins/PluginManager.swift`
- **Description:** When `currentPluginKitVersion` is bumped and a user has a stale plugin, it's silently blocked. Only an OSLog error is emitted — no UI notification that their plugin was rejected.
- **Remediation:** Show a user-visible notification or alert when a plugin is rejected due to version mismatch.
- [x] **Fixed** — Added `rejectedPlugins` tracking in PluginManager, `.pluginsRejected` notification, and NSAlert in AppDelegate showing rejected plugin names and reasons.

### 19. [MEDIUM] Test-only init not guarded by #if DEBUG

- **Category:** Debug Code
- **Files:** `TablePro/Core/Storage/QueryHistoryStorage.swift:55`, `TablePro/Core/Storage/SQLFavoriteStorage.swift:19`
- **Description:** `init(isolatedForTesting:)` is public and unguarded by `#if DEBUG`. Uses `DispatchSemaphore.wait()` on the main thread — potential deadlock if called from main thread in production.
- **Remediation:** Wrap test-only initializers with `#if DEBUG`.
- [x] **Fixed** — Wrapped `init(isolatedForTesting:)` with `#if DEBUG` in both files.

### 20. [MEDIUM] try? on COUNT(*) pagination queries — silent failure

- **Category:** Error Handling
- **File:** `TablePro/Views/Main/Extensions/MainContentCoordinator+QueryHelpers.swift:274,378`
- **Description:** If the COUNT(*) query fails (e.g., connection dropped), the error is silently swallowed. The UI shows no row count or retains a stale count, leading to incorrect pagination display.
- **Remediation:** Propagate the error or show a visual indicator that the count is unavailable.
- [x] **Fixed** — Replaced `try?` with `do/catch` + `Self.logger.warning` at both COUNT(*) sites.

### 21. [MEDIUM] Settings/connection form not VoiceOver-audited

- **Category:** Accessibility
- **Description:** The sidebar, connection form, settings screens, and right panel tabs have minimal or no VoiceOver-specific customisation. Data grid and filter panel are covered.
- **Remediation:** Conduct a focused VoiceOver audit of connection and settings UI.
- [ ] **Fixed**

### 22. [MEDIUM] Sparkle appcast served from mutable main branch

- **Category:** Update Security
- **File:** `TablePro/Info.plist:7-10`
- **Description:** `SUFeedURL` points to `raw.githubusercontent.com/.../main/appcast.xml`. If the repo is compromised, a malicious appcast could be pushed. Mitigated by Ed25519 signature verification on the actual binary.
- **Remediation:** Consider pointing `SUFeedURL` to a versioned GitHub Release asset or CDN URL. Defense-in-depth.
- [ ] **Fixed**

---

## Low Severity

### 23. [LOW] PostgreSQL PQexec result leaked

- **File:** `Plugins/PostgreSQLDriverPlugin/LibPQPluginConnection.swift:227-229`
- **Description:** `PQexec` result for `SET client_encoding TO 'UTF8'` is discarded without `PQclear`. Small memory leak per connection.
- **Fix:** `if let r = PQexec(connection, cStr) { PQclear(r) }`
- [x] **Fixed** — Captured `PQexec` result and added `PQclear()` call, matching existing pattern throughout the file.

### 24. [LOW] License signed payload in UserDefaults

- **File:** `TablePro/Core/Storage/LicenseStorage.swift:47-55`
- **Description:** Email and expiry stored in UserDefaults plist (readable by same-user processes). License key itself is correctly in Keychain. Signed payload is re-verified on load.
- [x] **Documented** — By design: signed payload is RSA-SHA256 verified on every cold start. License key is in Keychain. Added inline documentation.

### 25. [LOW] try! for static regex patterns

- **Files:** `TablePro/Views/Results/JSONHighlightPatterns.swift:9-12`, `TablePro/Views/AIChat/AIChatCodeBlockView.swift:127-259`, `TablePro/Core/Utilities/Connection/EnvVarResolver.swift:16`
- **Description:** `try!` on `NSRegularExpression` init. Patterns are string literals so crash risk is near zero, but a typo during refactoring would crash at launch.
- [x] **Accepted** — `try!` on static string literal regex patterns is the standard Swift idiom. Callers depend on non-optional types. Patterns are tested at launch. Added clarifying comment.

### 26. [LOW] oracle-nio pinned to pre-release RC

- **File:** `Package.resolved`
- **Description:** `oracle-nio` 1.0.0-rc.4, SSWG Sandbox maturity. Pre-release APIs may change. No stable 1.0.0 yet.
- [x] **Accepted** — External dependency; no stable release available. Monitor for 1.0.0 and update when released.

### 27. [LOW] FreeTDS 1.4.22 behind available 1.5.x

- **File:** `scripts/build-freetds.sh:8`
- **Description:** FreeTDS 1.5 is available. No confirmed high-severity CVEs in 1.4.22 but changelog should be reviewed.
- [x] **Accepted** — No high-severity CVEs in 1.4.22. Version bump to 1.5.x requires testing MSSQL driver compatibility. Track for next lib rebuild cycle.

### 28. [LOW] Uncached machineId IOKit lookup

- **File:** `TablePro/Core/Storage/LicenseStorage.swift:84-110`
- **Description:** Computed property calls `IOServiceGetMatchingService` on every access. Low practical impact (called infrequently) but should be cached as `lazy var`.
- [x] **Fixed** — Changed to `lazy var _machineId` computed once on first access.

### 29. [LOW] -Wl,-w suppresses all linker warnings in Release

- **File:** `TablePro.xcodeproj/project.pbxproj`
- **Description:** Hides potential issues like duplicate symbols or undefined behavior during linking.
- [x] **Accepted** — Intentional to suppress noise from third-party static libs. Flag suppresses warnings not errors. Removing risks CI breakage without investigation.

### 30. [LOW] Etcd VerifyCA mode skips hostname verification

- **File:** `Plugins/EtcdDriverPlugin/EtcdHttpClient.swift:1024-1028`
- **Description:** CA chain validated but hostname not checked. A certificate from the same CA for a different hostname will be accepted. Standard behavior for VerifyCA mode.
- [x] **Accepted** — Standard VerifyCA behavior matching MySQL/PostgreSQL drivers. Users who need hostname verification should select "Verify Identity" mode.

### 31. [LOW] SSH tunnel close error silently swallowed

- **File:** `TablePro/Core/Database/DatabaseManager+Health.swift:137`
- **Description:** `try? await SSHTunnelManager.shared.closeTunnel(...)` — if tunnel close fails, OS resources (file descriptors) may leak.
- [x] **Fixed** — Replaced `try?` with `do/catch` + `Self.logger.warning` for visibility.

### 32. [LOW] DuckDB extension SET errors silently swallowed

- **File:** `Plugins/DuckDBDriverPlugin/DuckDBPlugin.swift:566-567`
- **Description:** `try?` on `SET autoinstall_known_extensions=1`. If it fails, subsequent queries relying on autoloaded extensions fail with confusing errors.
- [x] **Fixed** — Replaced `try?` with `do/catch` + `Self.logger.warning` for DuckDB extension autoloading failures.

### 33. [LOW] Settings sync encode operations all use try?

- **File:** `TablePro/Core/Sync/SyncCoordinator.swift:687-694`
- **Description:** All eight settings categories silently return `nil` on encode failure, causing that category to not sync with no user feedback.
- [x] **Fixed** — Replaced individual `try?` with a single `do/catch` block + `Self.logger.error` logging the category name.

### 34. [LOW] Tag badge accessibility label not localized

- **File:** `TablePro/Views/Toolbar/TagBadgeView.swift:34`
- **Description:** `"Tag: \(tag.name)"` not wrapped in `String(localized:)`. VoiceOver announces "Tag:" in English for non-English users.
- [x] **Fixed** — Changed to `String(format: String(localized: "Tag: %@"), tag.name)` for proper localization.

### 35. [LOW] No memory pressure response

- **File:** `TablePro/Core/Utilities/MemoryPressureAdvisor.swift`
- **Description:** Tab eviction budget is row-count-based, not reactive to `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`. Under sustained memory pressure, no automatic eviction until next tab switch.
- [x] **Fixed** — Added `DispatchSource.makeMemoryPressureSource` monitoring. Budget halved under memory pressure. Monitoring started at app launch.

---

## What's Done Well

- **Live edits use parameterized prepared statements** (`SQLStatementGenerator` + `ParameterizedStatement`)
- **Plugin code signing enforced** via `SecStaticCodeCheckValidity` with team ID for registry plugins
- **Plugin registry: 3-layer defense** — HTTPS download, SHA-256 checksum, code signature verification
- **Connection export crypto** — AES-256-GCM, 12-byte random nonce, PBKDF2-SHA256 at 600K iterations
- **License verification chain** — RSA-SHA256 with machine ID binding, re-verified on every cold start
- **No passwords or secrets logged** anywhere in OSLog calls
- **Keychain usage correct** — `kSecUseDataProtectionKeychain`, proper accessibility levels
- **Sparkle uses HTTPS + Ed25519 signatures** — MITM-resistant
- **Tab persistence uses atomic writes** with 500KB truncation guard
- **Filter values properly escaped** per SQL dialect in `FilterSQLGenerator`
- **SPM dependencies all pinned** to exact versions/SHAs (no branch pins)
- **Hardened runtime enabled** at target level with all exception flags set to NO
- **`#if DEBUG` blocks are correctly stripped** in release builds

---

## Remediation Priority

### Immediate (High)

1. **Issue #1**: Add confirmation dialog for URL `condition`/`raw`/`query` parameters
2. **Issue #2**: Update OpenSSL to 3.4.3 in all build scripts, rebuild libs

### Short-term (Medium)

3. **Issue #4**: Handle `MYSQL_DATA_TRUNCATED` in MySQL prepared statements
4. **Issue #7**: Escape BigQuery column names; validate operator allowlist
5. **Issue #8**: Improve deeplink SQL preview; add length limit
6. **Issue #11**: Add SHA-256 verification to FreeTDS, Cassandra, DuckDB build scripts
7. **Issue #5**: Rename misleading sslMode="Required" option
8. **Issue #9**: Verify BigQuery OAuth refresh token storage path

### Medium-term

9. **Issue #15**: Migrate connection storage to atomic file-based JSON
10. **Issue #16**: Implement `applicationShouldTerminate` with unsaved-edits check
11. **Issue #18**: Surface stale plugin rejections in UI
12. **Issue #19**: Guard test-only initializers with `#if DEBUG`
13. **Issue #17**: Fix plugin load race on first connection
