# TablePro Roadmap

Written 2026-08-19 against `main @ 83cab056c`, from the DBngin feasibility research.
Every file:line below was verified against the tree on that commit. Re-check before starting a task that has been sitting.

## How to read this

| Priority | Meaning |
| --- | --- |
| **P0** | Ship now. Confirmed defects and one unmet legal obligation. Each is one commit. |
| **P1** | The next feature. Two open issues ask for it by name. |
| **P2** | Earns its place after P1 ships. |
| **P3** | Ranked backlog. Pick by appetite, not by order. |
| **Conditional** | Do not start until the open question above it is answered yes. |
| **Declined** | Written down so it stops coming back. |

Effort is S (under a day), M (a few days), L (a week or more), measured in focused time, not calendar time.

Every task carries the same closing checklist. It is stated once, in [Definition of done](#definition-of-done), and not repeated per task.

---

## P0. Shipped

All five landed on `fix/p0-connection-and-binary-integrity`. Each is its own commit with its own tests.
The stale "Work / Test / Effort / Commit" notes under each item are the original plan, kept so the
intent is readable next to what actually shipped.

### P0-1. Editing a connection wipes four stored properties

- [x] **Fix `connectionToSave` dropping fields, and add a round-trip test.** Shipped in `9b85b49bd`.

**Where:** `TablePro/Views/ConnectionForm/ConnectionFormCoordinator.swift:282-310` built the object, `:368` wrote it with `savedConnections[index] = connectionToSave`.

**What was wrong:** the initializer call omitted `isFavorite:`, `isSample:`, `sortOrder:` and `aiAlwaysAllowedTools:`. All four default to an empty value in `DatabaseConnection.init`, and the save path replaces the whole object, so each reset on any edit.

Three of the four are live:

| Field | Read by |
| --- | --- |
| `sortOrder` | `WelcomeViewModel.swift:618`, `:655`; `FavoritesSidebarViewModel.swift:249`, `:258` |
| `aiAlwaysAllowedTools` | `AIChatViewModel+ToolApproval.swift:104`, `:154` |
| `isFavorite` | the welcome list; its iCloud half was fixed separately in `[Unreleased]` |

**Correction to an earlier draft of this file:** it also named `mongoAuthSource`, `mssqlSchema`, `oracleServiceName` and the rest of that family. Those are computed properties over `additionalFields`, not stored properties, and every one of them except `oracleServiceName` is declared by its plugin, so the panes carry them. Only `oracleServiceName` was at risk, through a different route: it is written by URL parsing into `advanced.additionalFieldValues` but no plugin declares it, so it was dropped when the form next loaded.

**What shipped:** a `ConnectionFormEdits` value type holding exactly what the form owns, with `applied(to:)` writing those onto the connection being edited rather than constructing a new one. Anything the form does not own is carried by construction, with no list to maintain. For `additionalFields` the same rule holds through `ownedAdditionalFieldIDs`, which covers the plugin-declared set for both the new and the previous database type plus the three app-managed keys, so a key nobody owns (`oracleServiceName`) survives while a type change still clears the old type's fields.

**Test:** `ConnectionFormEditsTests` covers the apply semantics. `ConnectionFormEditsCoverageTests` is the guard against recurrence: it reflects over `DatabaseConnection` and fails when a stored property is neither classified as form-written nor as carried over, so adding a property to the model forces the decision instead of silently resetting it.

---

### P0-2. A second waiter on `termination` never wakes

- [x] **Convert `terminationContinuation` to an array of continuations.** Shipped in `771669af8`, together with a second defect the new tests caught: `finish()` cleared the pipe's readability handler before the last chunk arrived, so the final stderr line was dropped whenever a helper exited quickly. That line is usually the reason it failed. `finish()` now drains the pipe with `readToEnd()` and is idempotent.

**Where:** `TablePro/Core/Process/SupervisedProcessRunner.swift:30` declares it as a single optional, `:89` overwrites it, `:119-120` resumes it once.

**What is wrong:** two concurrent `await runner.termination` calls means the first continuation is dropped and never resumed. That task hangs for the life of the process. Latent today because only `startDeathWatch` awaits it, so this is a fix before the next caller, not a live bug report.

**Work:** hold `[CheckedContinuation<SubprocessTermination, Never>]`, append under the lock, resume all on finish, and keep the cached-result fast path.

**Test:** start two `await` tasks against a fake runner, terminate once, assert both resume with the same value.

**Effort:** S. **Commit:** `fix(perf): wake every waiter on a supervised process termination`

---

### P0-3. A pinned binary version bump never reaches an installed copy

- [x] **Compare the installed version and re-verify the SHA before exec.** Shipped in `cadc76b8c`. `CloudSQLProxyBinaryManager.installedBinaryIsCurrent()` requires the file to exist, the recorded version to equal `pinnedVersion`, and the SHA-256 to match the pin, on every call and again after a download. `CopilotBinaryManager` has no pin to check against, since npm serves whatever `latest` resolves to, so it records the digest at install (`sha256.txt`) and re-verifies against that. The shared streaming digest and the quarantine strip moved into `DownloadedBinary`, which also absorbed the third verbatim copy of the xattr helper in `PluginInstaller`.

**Where:** `TablePro/Core/CloudSQL/CloudSQLProxyBinaryManager.swift:47-50` reads `installedVersion()`, `:52-55` returns early on `isExecutableFile` without comparing it. The same early return exists in `TablePro/Core/AI/Copilot/CopilotBinaryManager.swift`.

**What is wrong:** two things.

1. Raising `pinnedVersion` (currently `2.23.0`, `:15`) downloads nothing on a Mac that already has the old binary. The pin is only honoured on a first install.
2. The SHA-256 is checked once at download and never again. The file then sits in a user-writable directory under Application Support and is executed on every connect. The binary itself is `Signature=adhoc`, `TeamIdentifier=not set`, and `spctl -a -t exec` rejects it, so the checksum is the only thing standing between the app and unattributable code.

**Work:** in `ensureBinary()`, return the cached path only when the file exists **and** `installedVersion() == Self.pinnedVersion` **and** its SHA-256 matches `expectedSHA256[arch]`. Otherwise re-download. Apply the same shape to `CopilotBinaryManager`. Keep the single-flight `downloadTask` behaviour.

**Test:** `TableProTests/CloudSQL/CloudSQLProxyBinaryManagerTests.swift` already injects `fetch` and `baseDirectory`. Add three cases: version file behind the pin re-downloads; a tampered file with the right version re-downloads; a matching file and version does not fetch.

**Effort:** S. **Commit:** `fix(connections): re-download a pinned helper binary when its version or checksum no longer matches`

---

### P0-4. The notarization comment is wrong

- [x] **Correct the doc comment on `PluginCodeSignatureVerifier`.** Shipped in `b714190ed`. The same false claim was also in the `[Unreleased]` CHANGELOG entry and in `docs/features/plugins.mdx`, and both were corrected: a Developer ID signature proves Apple issued the certificate and the bundle is unaltered, not that Apple scanned it.

**Where:** `TablePro/Core/Plugins/PluginCodeSignatureVerifier.swift:27-31`.

**What is wrong:** it claims `SecStaticCodeCheckValidity` performs a notarization check by default and fails with `errSecCSRevokedNotarization`. The requirement string the verifier uses contains no notarization term. Apple DTS states that `SecRequirementCreateWithString(CFSTR("notarized"))` only ever returns `errSecCSReqFailed`, which cannot separate never-notarized from revoked, and that `SecAssessmentTicketLookup` is not in the public SDK ([forums thread 731675](https://developer.apple.com/forums/thread/731675)).

The verifier's actual behaviour is fine. Only the comment is wrong, and it will be copied into the next thing that checks a signature.

**Work:** state what the requirement really asserts (Apple-anchored chain plus a Developer ID leaf), and state that notarization status is not checkable from in-process API. No behaviour change.

**Effort:** S. **Commit:** `docs(plugins): correct what the plugin signature check actually verifies`

---

### P0-5. Third-party licence notices are missing

- [x] **Add a licenses page and a drift gate.** Shipped in `c023b61a7`, as Help › Acknowledgements rather than a Settings pane, which is where macOS apps conventionally put it. 38 components, 36 license texts, 448K. Larger than the half-day estimate: the notice obligation is not one file per license but one per component, because Apache 2.0 section 4(d) requires nine packages' NOTICE attribution lines and three C libraries carry a second required file, `mongo-c-driver`'s `THIRD_PARTY_NOTICES` among them, which is what discharges the projects vendored inside it.

**What is wrong:** TablePro statically links and ships copyleft libraries with no notice surface anywhere.

| Library | Version | Licence | Pin |
| --- | --- | --- | --- |
| MariaDB Connector/C | 3.4.4 | LGPL 2.1-or-later | `scripts/build-mariadb.sh:20` |
| FreeTDS | 1.4.22 | LGPL v2-or-later, **modified** | `scripts/build-freetds.sh:22`, patch at `scripts/patches/freetds/freetds-fedauth.patch` |

Both are linked into `.tableplugin` bundles that ship today. The source-and-relink half of LGPL 2.1 §6 is met by the public AGPLv3 repo carrying the build recipes, the exact pins and the patch. The notice half is not: §6 requires the distributed work to say the Library is used, that its use is covered by the LGPL, and to include a copy of the licence. Grep across `TablePro/` and `docs/` finds no such page.

This is the only unmet legal obligation the project currently has.

**Work:**

- [ ] A script that reads the version pins out of `scripts/build-*.sh` and the SPM dependency list out of `project.yml`, and emits a single generated markdown file. Generating it is the point: a hand-written list drifts the first time a lib is bumped.
- [ ] `docs/about/licenses.mdx` rendering that file, linked from `docs/index.mdx`.
- [ ] A Settings surface. Put it under the existing `.account` pane rather than adding a `SettingsPane` case, unless the list turns out long enough to need its own.
- [ ] Include the full licence text for each distinct licence, not just its name.

Cover every `Libs/*.a` and every SPM dependency (Sparkle, swift-certificates, Yams, and the vendored CodeEdit packages), not only the two above.

**Effort:** S. **Commit:** `feat(settings): list the open source libraries TablePro ships and their licences`

---

## P1. Cross-connection data transfer

**Why this one.** Two open issues ask for it by name, [#721](https://github.com/TableProApp/TablePro/issues/721) and [#1491](https://github.com/TableProApp/TablePro/issues/1491). Both ends of the pipe already exist in `TableProPluginKit`. It needs no new privileged capability, no new plugin protocol requirement, and no ABI bump. It runs end to end on CI against SQLite and DuckDB with no server.

**What the user gets.** Pick tables in connection A, pick connection B, pick create / truncate / append, watch a progress sheet, get a summary. Same-engine transfer works for every driver that already implements export and import. Cross-engine transfer works where the type mapping covers it, and says plainly where it does not.

**The seams, verified:**

| Need | Already exists |
| --- | --- |
| Read rows | `PluginExportDataSource.streamRows(table:databaseName:)` returns `AsyncThrowingStream<PluginStreamElement, Error>` (`Plugins/TableProPluginKit/PluginExportDataSource.swift:5`) |
| Read schema | `fetchAllColumns(databaseName:)` `:14`, `fetchAllForeignKeys(databaseName:)` `:16` |
| Write rows | `PluginImportDataSink.insertRows(_:)` (`PluginImportDataSink.swift:13`) |
| Transaction | `beginTransaction` `:15`, `commitTransaction` `:16`, `rollbackTransaction` `:17` |
| FK handling | `disableForeignKeyChecks()` `:18`, defaulted to a no-op at `:35` |
| Target DDL | `PluginDatabaseDriver.generateCreateTableSQL(definition:)` (`PluginDatabaseDriver.swift:170`) |
| Progress fan-out | `PostgresDumpService.stateUpdates()` (`:101`), a multi-observer `AsyncStream`. Copy this shape, not the tunnel managers'. |
| Flow UI | `TablePro/Views/Backup/BackupDatabaseFlow.swift` (164 lines), `BackupProgressSheet.swift`, `BackupResultSheet.swift` |

### Tasks

- [ ] **P1-1. `DataTransferPlan` model.** Source connection, source database and schema, table list, target connection, target database and schema, write mode (`create` / `truncate` / `append`), batch size, per-table column mapping. Codable so a plan can be saved and re-run later. Pure, fully unit-testable. **S**

- [ ] **P1-2. Type mapping matrix.** The only hard part. A pure `TypeMappingResolver` that takes a source `PluginColumnInfo` and a target `DatabaseType` and returns a target type name or a stated reason it cannot map. Start with the pairs the plugin set makes likely: Postgres to MySQL, MySQL to Postgres, anything to SQLite, anything to DuckDB, anything to CSV-shaped sinks. Same-engine is identity and covers most of the demand, so ship that first and let the matrix grow. Table-driven, so each new pair is a fixture, not a code change. **M**

- [ ] **P1-3. FK-ordered table sequencing.** Topological sort over `fetchAllForeignKeys`, so parents load before children. Report a cycle instead of guessing, and offer `disableForeignKeyChecks()` as the way through it. Pure. **S**

- [ ] **P1-4. The transfer pump.** Host-side actor. Pulls from the source stream, batches, pushes to the sink inside a transaction, rolls back the current table on error. Backpressure so a fast source cannot outrun a slow sink. Cancellation must leave the target in a stated condition, not a half-written table. Publishes progress through a multi-observer `AsyncStream` modelled on `PostgresDumpService.stateUpdates()`. **M**

- [ ] **P1-5. Target DDL.** For `create` mode, build a `PluginCreateTableDefinition` from the mapped columns and call `generateCreateTableSQL`. Show the SQL before running it. Never create a table when the driver returns `nil`, say so instead. **S**

- [ ] **P1-6. Flow UI.** Source and target pickers, table list with select-all, write mode, a preview of the generated DDL and the mapping decisions, progress sheet, result sheet. Follow `BackupDatabaseFlow` for structure. If it becomes a tab rather than a sheet, the tab must declare `resolveDetailMinimumThickness(for:)` and must not leak a minimum width into the window's split dividers. **M**

- [ ] **P1-7. Tests.** Pure pieces (`TypeMappingResolver`, the topological sort, the plan model) get plain unit tests. The pump gets a fake source and a fake sink asserting batching, ordering, transaction calls and cancellation. One end-to-end test moving a table between two temporary SQLite files, and one SQLite to DuckDB, both of which run on CI with no server.

- [ ] **P1-8. Docs.** New page under `docs/features/`. Say plainly which engine pairs are mapped and what happens when a type has no mapping.

**Effort total:** M. **Scope:** app-side only. No `PluginKit` change, therefore no ABI bump.

**Watch for:** if the result renders in the data grid, resolve any selected index through `DisplayRowMapping` before touching a row. `GridSelectionState.indices` are display positions, not array indices (#1837).

---

## P2. Schema diff to migration script

Do this after P1 ships and has run in the wild for a release.

**What the user gets.** Pick two schemas: two servers, two databases on one server, or a live schema against a saved snapshot. See a structural diff. Generate `CREATE` / `ALTER` / `DROP` with a checkbox per change. Destructive changes are marked and unchecked by default.

No competitor at TablePro's price does this. DataGrip and Navicat do; TablePlus does not.

**The seams:** reading is `fetchAllColumns(schema:)` (`PluginDatabaseDriver.swift:117`), `fetchIndexes(table:schema:)` `:88`, `fetchAllForeignKeys(schema:)` `:119`, `fetchTriggers(table:schema:)` `:90`, `fetchViewDefinition(view:schema:)` `:92`. All are defaulted on the protocol. Emitting is the existing `generate*SQL` family, already exercised by the structure editor.

### Tasks

- [ ] **P2-1. `SchemaSnapshot`.** Codable model covering tables, columns, indexes, foreign keys, triggers and view definitions. Saving one to disk is what makes "diff against last week" work. **S**
- [ ] **P2-2. Type normalization.** `int(11)` and `integer` and `int4` are the same column. This is the whole risk of the feature: get it wrong and the diff reports changes that are not changes. Pure and table-driven, reusing P1-2's tables where they overlap. **M**
- [ ] **P2-3. Diff engine.** Pure. Emits `[SchemaChange]`, each carrying `isDestructive` and `requiresDataMigration`. **M**
- [ ] **P2-4. Script generation.** Ordered so a generated script applies cleanly: create before reference, drop after dereference. **S**
- [ ] **P2-5. Two-pane tab.** Left schema, right schema, changes in the middle with checkboxes. Must subclass `ResizeCursorSplitViewController` or the divider drags without ever showing the resize cursor (#1905). Must declare `resolveDetailMinimumThickness(for:)` (#1872). **M**
- [ ] **P2-6. Tests.** Fixture snapshots per engine, asserted diffs, asserted generated SQL. Normalization gets its own fixture corpus.
- [ ] **P2-7. Docs and CHANGELOG.**

**Effort:** M to L. **Scope:** app-side only, no `PluginKit` change.

---

## P3. Ranked backlog

Pick by appetite. Each is independent. Effort and value are relative to a solo developer on this codebase.

### P3-1. Masked and anonymized transfer

**Effort S once P1 exists. Value 8.**

A transform stage inside the P1 pump, between source and sink. Per-column rules: hash this email, fake this name, null this SSN, keep this foreign key intact so the clone still joins. Because it sits in the pump and not in a plugin, every existing export plugin gets it at the same time and `PluginKit` does not change.

Rules persist per table as JSON, following the one-file-per-connection-plus-database-plus-schema-plus-table shape `FilterSettingsStorage` already uses.

Headline: clone production into a local Postgres with the personal data removed. Snaplet shut down in 2024 and Neosync was acquired and archived in 2025, so no desktop client currently offers this.

- [ ] Rule model and per-column editor
- [ ] Transform stage in the pump
- [ ] Deterministic hashing so the same input maps to the same output across runs, or foreign keys break
- [ ] Rule persistence
- [ ] Tests: every rule kind, plus FK integrity across two related tables

### P3-2. Cloud instance auto-discovery

**Effort M. Value 8.**

`TablePro/Core/Database/AWS/` already holds `RDSAuthTokenGenerator`, `RDSSigningEndpoint`, `RDSEndpoint` and `AWSSSOLoginService`, so `rds:DescribeDBInstances` is a signed GET away. The serverless tier (Neon, Supabase, PlanetScale, Turso, Upstash, Railway, Fly) is token plus REST and no competitor serves it.

**Hard rule:** opt-in per named profile. TablePro never reads a credentials file it was not explicitly pointed at. This is the same rule the discovery work below is bound by, and the two must not contradict each other.

- [ ] Provider protocol, one implementation per vendor
- [ ] AWS first, since the signing code exists
- [ ] Then the token-plus-REST vendors, which are nearly identical to each other
- [ ] A picker that adds discovered instances as connections
- [ ] Verify the API route names for Neon, Supabase, Turso and PlanetScale before writing the clients

### P3-3. Data compare with sync script

**Effort M. Value 8. One hard restriction in v1.**

Row-level diff keyed on the primary key, then a script that makes the target match the source.

**The trap:** a PK-ordered streaming merge is not collation-safe across engines. MySQL's default `utf8mb4_0900_ai_ci` sorts case-insensitively and accent-insensitively. PostgreSQL under `C` or an ICU locale does not. Two differently ordered streams desynchronise, and the merge then reports rows present on both sides as source-only inserts and target-only **deletes**. The deliverable emits those DELETEs.

**v1 restricts to integer and UUID primary keys.** Lift the restriction later by sorting host-side on a normalized key or by emitting an explicit per-dialect `COLLATE` in the `ORDER BY`.

Note `streamRows(table:databaseName:)` takes no ordering parameter. Ordering has to come from `PluginDatabaseDriver.streamRows(query:)` with the app writing the `ORDER BY`.

- [ ] Streaming merge over two ordered cursors
- [ ] PK type gate with a clear message when a table is excluded
- [ ] Diff view, reusing the data grid
- [ ] Sync script generation with destructive changes unchecked
- [ ] Tests including the collation case, as an explicit regression test

### P3-4. Migration file export

**Effort M, not S. Value 8, only if scoped to one framework.**

Rails, Laravel, Django, Prisma, Drizzle, Atlas and goose each define their own DSL, naming, version scheme and reversibility contract. Django and Prisma go further and keep a state model the file must stay consistent with: a Django migration is a node with `dependencies = [...]`, and a Prisma migration must reconcile with `schema.prisma` or `prisma migrate` refuses to run. A file the framework's own tooling rejects is worse than no feature.

**Ship one framework, the one you use. Add a second only after the first has run in the wild for a release.**

Offer the file for the user to save. Never write into a framework-managed migrations directory without the framework's own CLI in the loop.

The seam exists: `TablePro/Core/Services/ProjectImport/` already identifies the framework from `.env`, `docker-compose.yml`, `schema.prisma`, `config/database.yml`, `application.properties` and `appsettings.json`.

- [ ] Pick the framework
- [ ] Emitter, with the framework's real reversibility contract, not a generic template
- [ ] Round-trip test: generate, then run the framework's own CLI against it in CI if that is affordable, otherwise assert against captured real output

### P3-5. Runners-up

Written down, not scheduled.

| Idea | Note |
| --- | --- |
| SQL review linting | 31 dialects make false positives the whole risk |
| MapKit geospatial viewer | The clearest "not possible in Electron" screenshot, narrow audience |
| Seed and mock data generation | Pure Swift, highly testable, DataGrip lacks it |
| DuckDB local analytics for cross-connection joins | Strongest pure differentiator. Needs one app-owned `duckdb_open` handle with several connections on it, because two opens of one path are independent databases (`supportsConnectionPooling = false` exists for this reason) |

---

## Conditional. Local Services

**Do not start until open question OQ-1 is answered yes.**

The research found zero recorded demand: 18 open issues, 9 of them "support my database", 0 mentioning local servers, Docker, DBngin or Herd. Full findings, including the licence table and the platform analysis, are in the feasibility report.

What survives review is much smaller than a DBngin equivalent. Read the two "not in this stage" lists as hard scope, not as aspirations.

### Stage 1. Discover and adopt

Offer a pre-filled localhost connection at three moments the user is already looking: the Welcome empty state, the Open Project Folder result screen, and the new-connection form when the chosen type has a listener on a non-canonical port. Plus one Settings pane listing what was found, with Adopt per row.

- [ ] **LS-1. Anchor discovery on the listening socket.** `lsof -nP -iTCP -sTCP:LISTEN` runs in 0.03s (measured, macOS 27.0 build 26A5406e) and is the only source that says a database is reachable. Use `ps` only to enrich the owning PID, never to constitute a service. Postgres rewrites argv per process, so `ps` shows `postgres: checkpointer` and one `postgres: <user> <db> 127.0.0.1(49576) idle` line per open session from every app on the machine. MariaDB shows `/bin/sh .../mariadbd-safe --datadir=/opt/homebrew/var/mysql`: argv[0] is a shell, no port, no version, and a datadir named `mysql` while the engine is MariaDB.

- [ ] **LS-2. Link adopted services through a side store keyed by connection UUID.** Not `additionalFields`. All three form panes rebuild `additionalFieldValues` from the plugin-declared field list only (`NetworkPaneViewModel.swift:130`, `AuthPaneViewModel.swift:110-118`, `AdvancedPaneViewModel.swift:59-79`) and the coordinator fills `finalAdditionalFields` only from those three (`:243-246`). An app-invented key is dropped on load and absent on save, so the link would vanish the first time the user edits the connection, silently, and Adopt would then create a second connection to the same database. Follow `DatabaseTreeFilterStorage` and `RecentTablesStore`. This also keeps the key off CloudKit without depending on `localOnly`, which is a user-editable checkbox (`AdvancedPaneViewModel.swift:78`).

- [ ] **LS-3. Credentials.** PostgreSQL sets `additionalFields["usePgpass"] = "true"`, which is plugin-declared (`PluginMetadataRegistry.swift:500`) and therefore survives the form. The reader already exists and handles wildcards, escaped colons and the 0600 check (`TablePro/Core/Utilities/Connection/PgpassReader.swift`). Do **not** use `PasswordSource.file`: `PasswordSourceResolver.resolveFile` returns the whole trimmed file as the password. MySQL has no `.my.cnf` equivalent, so leave its password empty.

- [ ] **LS-4. Do not probe unadopted rows.** An unadopted service has no `DatabaseScope`, so the only way to show `.ready(version:)` is to build a transient connection and authenticate on a poll, without credentials and without consent, writing failed-auth rows into the target's audit log and counting toward MySQL's `max_connect_errors`. An unadopted row shows "listening on 5433", derived from the socket, and nothing more.

- [ ] **LS-5. Redaction.** `ps` output carries `--password=`, `PGPASSWORD=`, `MYSQL_ROOT_PASSWORD=`, URIs with embedded credentials, and session PII in the `postgres: <user> <db> <addr>` form. Redact before anything reaches OSLog, the UI, a log file, a Copy Details buffer or a bug report. Default-deny for any argv the app did not construct. Nothing from a scan reaches analytics. Fixture-tested.

- [ ] **LS-6. Port handling.** `LoopbackPort.allocateFree()` (`TablePro/Core/Process/LoopbackPort.swift:11-37`) binds port 0, closes the descriptor in a `defer`, and returns the number. That is a verified TOCTOU, and `MCPPortAllocator` has the same shape. The one race-free implementation in the tree is `SOCKSProxyManager`, which lets an `NWListener` hold the port. Generalize that. Attribute a conflict with `lsof` plus `proc_pidpath` and offer "use that one instead"; never silently pick a different port.

- [ ] **LS-7. One Settings pane, one inline affordance.** No fifth Welcome section, no `Database` submenu, no separate sheet, no menu bar extra. `SettingsPane` (`TablePro/Views/Settings/SettingsView.swift:8`) is `String`-raw so an added case stays compatible with the persisted-key fallback. Errors inline, never alerts. One failing provider keeps its last good result and never blanks the list (#1916).

**Not in Stage 1:**

- No start, stop, restart, create or delete of anything.
- No writing to a directory it did not create.
- No `stat` of a discovered data directory during a scan. `Info.plist:293-297` already carries the Documents, Desktop and Downloads usage strings, so touching a datadir under one of those fires a TCC prompt at launch, which is the startup modal the app's own rules forbid. A datadir is an opaque display string until the user asks to reveal it.
- No datadir on an external or network volume. `NSRemovableVolumesUsageDescription` and `NSNetworkVolumesUsageDescription` are absent (grep count 0). Add them first if this is ever wanted.
- No reading of `~/.ssh`, `~/.aws`, `~/.gnupg` or any Keychain.

### Stage 2. Control what already exists

**Do not start until OQ-2 and OQ-3 are answered.** The catalog lost SQL Server, Oracle and Db2, which removed most of this stage's reason to exist.

- [ ] **LS-8. Provider capability decides the verb.** For anything launchd supervises, the only legal control is the manager's own verb. Measured: `~/Library/LaunchAgents/homebrew.mxcl.postgresql@17.plist` carries `KeepAlive: true`, `RunAtLoad: true`, `ExitTimeOut: 120`. Any signal is undone within a second and the health probe then reports the service up, so a signal-based Stop is a visible no-op with no error anywhere. There is no `signalVerbs` capability, because TablePro never signals a database process.

- [ ] **LS-9. Disclose the login item.** Since macOS 13 every third-party LaunchAgent appears in System Settings, General, Login Items and Extensions, and produces a "Background items added" notification. `RunAtLoad: true` means Start really means start now and at every login. Say this before the first `brew services start`.

- [ ] **LS-10. Container runtime probe order.** `DOCKER_HOST`, then `~/.docker/run/docker.sock`, `~/.orbstack/run/docker.sock`, `~/.colima/<profile>/docker.sock`, the Podman machine socket, then `/var/run/docker.sock` last. On Docker Desktop that last one is opt-in and requires an admin password, and was measured absent. Report which runtime answered.

- [ ] **LS-11. Lead the empty state with Colima and Podman.** Docker Desktop needs a paid subscription for commercial use above 250 employees or $10M revenue, and for government. OrbStack needs a licence for freelance, commercial, non-profit or government use. Only Colima and Podman are free for commercial use.

- [ ] **LS-12. Do not build a second Docker credential extractor.** `TablePro/Core/Services/ProjectImport/DockerComposeExtractor.swift` already maps image names to `DatabaseType` (`:68`), sets `host = "127.0.0.1"` (`:43`), parses both published-port forms (`:113`), and reads `POSTGRES_PASSWORD`, the `MYSQL_*` and `MARIADB_*` family, `MONGO_INITDB_ROOT_*`, `CLICKHOUSE_*`, `MSSQL_SA_PASSWORD` and `REDIS_PASSWORD` (`:141`). Two copies drift, and with no shared identity between a `ScannedConnectionCandidate` and a service record the user gets two connections to `127.0.0.1:5433`. Either extract one shared pure table, or drop the container provider and extend the compose scanner to cross-check against the running socket. The second is smaller and probably right.

**Not in Stage 2:** no engine binary download, no runtime installation, no data directory outside the runtime's own volumes, no deleting a volume TablePro did not create, no menu bar extra (0 uses of `NSStatusBar` or `SMAppService` repo-wide today).

---

## Declined

Written down so the question stops recurring.

### Shipping or downloading database engine binaries

**Declined permanently.**

The decisive reason is not licensing. It is that the safety gate cannot be built. Any "we only ship binaries the vendor notarized" rule needs a way to check notarization from in-process API, and there is none: `SecRequirementCreateWithString(CFSTR("notarized"))` returns only `errSecCSReqFailed`, which cannot separate never-notarized from revoked, and `SecAssessmentTicketLookup` is not public SDK. An unenforceable constraint is not a constraint.

Per engine:

| Engine | Licence | Verdict |
| --- | --- | --- |
| PostgreSQL | PostgreSQL Licence | No. The ICU collation pin makes every data directory a permanent compatibility contract. Postgres records the collator version at collation creation, and a different ICU silently mis-orders btree indexes on text columns. Wrong results, not an error. |
| MySQL, MariaDB | GPLv2-only | No. Incompatible with AGPLv3 for linking. Aggregation is legal but attaches GPLv2 §3 to TablePro: a three-year written source offer per copy conveyed. |
| Redis 8+, Valkey, ClickHouse | AGPLv3 / BSD / Apache 2.0 | No. Legally fine, but nobody struggles to install these, so bundling the easy engines buys nothing and still carries the maintenance. |
| MongoDB Community | SSPLv1, AGPLv3 from 8.1 | No. Was the one defensible download target, on the vendor-notarizes argument. That gate cannot be checked. |
| SQL Server | Proprietary | No. No macOS server binary. The container is amd64-only, 2025 RTM dies under Rosetta on an AVX assertion until CU1 (Feb 2026), and Azure SQL Edge is deprecated. `ACCEPT_EULA=Y` is the acceptance, and the default edition is Developer, which has no production rights. |
| Oracle, Db2 | Proprietary | No. No macOS binary, and the container path means accepting a vendor EULA on the user's behalf. |

Note for the record: earlier drafts cited the MySQL FOSS License Exception. It was deprecated as of MySQL 8.0.4 (2018-01-24) and never covered the server. Do not cite it. TablePro is AGPLv3 (`LICENSE:1`), which changes several of these analyses but none of the verdicts.

### Autostart a local database at login

Out of scope as a consequence of the above. If TablePro never owns a long-lived process, there is no login item and no Background Item approval prompt. That simplification is worth more than the feature.

### Becoming a stack manager

TablePro manages database endpoints. Never a language runtime, web server, DNS, TLS or mail catcher. MAMP, XAMPP, Laragon and Local all bundled those as a unit and rotted as a unit; XAMPP's macOS builds still list PHP 8.2.4 and MariaDB 10.4.28. This is declined by policy, not case by case.

---

## Open questions

Answer these before the conditional work starts. None is answerable from the code.

- **OQ-1. Build Local Services at all this cycle?** Zero recorded demand. Two open issues ask for P1 by name. Recommendation: ship P1, revisit this only when a user asks.
- **OQ-2. With SQL Server, Oracle and Db2 removed, does Stage 2 still have a reason to exist?** The remaining engines are the ones users already install easily.
- **OQ-3. Read-only Homebrew, or `brew services` verbs?** Starting a service mutates a package manager's state on the user's behalf, adds a permanent Login Items entry with `RunAtLoad: true`, and fires a system notification. Homebrew also allows one service per formula, so a second instance is impossible. Read-only, meaning discovery, status and "open in Terminal", may be the right stopping point.
- **OQ-4. Free or paid?** Recommendation: free throughout. The direct competitor is free and does more. Note that adding a `ProFeature` case is four switch sites, not three: the enum plus `displayName`, `systemImage`, `featureDescription` and `requiredTier` in `TablePro/Models/Settings/ProFeature.swift`.
- **OQ-5. Naming.** "Local Services" against "Local Databases" against "Servers". Competitors say services, users say servers, and the app already overloads "connection". Expensive to reverse once it is in menu items, settings keys and docs.

### Verification still owed

Do not quote these numbers until they are confirmed.

- [ ] MongoDB Community's current licence for 8.1 and later. AGPLv3 was announced in May 2025.
- [ ] Oracle Free Use Terms full text. `oracle.com/downloads/licenses/oracle-free-license.html` returned HTTP 403.
- [ ] Whether `container-registry.oracle.com` still requires an authenticated pull with per-repository terms acceptance.
- [ ] Db2 container image availability on arm64.
- [ ] Docker Hub Terms of Service as applied to automated pulls started by a third-party desktop app.
- [ ] DBngin, Herd and Postgres.app on-disk layouts, on machines with each actually installed. Those providers do not ship until this is done.
- [ ] Whether `NWEndpoint.unix(path:)` plus hand-rolled HTTP/1.1 to the Docker Engine API is really the small adapter it looks like. No runtime was present on the machine this was researched on.
- [ ] Neon, Supabase, Turso and PlanetScale API route names, for P3-2.

---

## Definition of done

Every task above closes the same way. From `CLAUDE.md`, non-negotiable.

- [ ] `CHANGELOG.md` updated under `[Unreleased]`, one user-facing line, no file paths or class names, reference ID in parens at the end. No "Fixed" entry for something that is itself still unreleased.
- [ ] Tests added or updated. When a test fails, fix the source, never the test.
- [ ] UI automation in `TableProUITests` where the flow runs deterministically. If it cannot, say why in the PR body.
- [ ] `docs/` updated: keyboard shortcuts, feature pages, settings, or driver pages as applicable.
- [ ] New user-facing strings use `String(localized:)`. Never with interpolation, use `String(format:)` instead.
- [ ] `scripts/generate-project.sh` run if any file was added, moved or deleted.
- [ ] `swiftlint lint --strict`. `.swiftlint.yml` sets `included: [TablePro]`, so pass paths explicitly for anything under `Plugins/`, `Packages/`, `LocalPackages/` or the test targets.
- [ ] `swiftformat .`
- [ ] Conventional Commits, single line, no body. Scope from the canonical list.
- [ ] Writing check before committing:

```bash
git diff --cached -U0 | grep -nE '—|seamless|robust|comprehensive|intuitive|effortless|streamlined|leverage|elevate|delve|utilize|facilitate'
```

- [ ] A rename or signature change updates every caller and every test in the same commit.
