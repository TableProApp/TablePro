# A. TablePro Linux feature inventory mapped to BookiE

Source pin: TablePro `main` 3222542a4 (2026-10-19), tree `linux/` only. BookiE `linux` 7c4cb3929. Reviewed 2026-10-20 by reading source and grepping both trees. Nothing was built or run. Upstream files are cited relative to `linux/`. BookiE files are cited relative to the repository root.

Statuses come from code, not docs. "Already recorded in X" means a dated archive under `docs/archive/` or a live backlog row already owns it; those rows stay one line.

Lanes follow `AGENTS.md`: B3 = values, drivers, result paths. B4 = transport, TLS, SSH, policy, audit. UX = `apps/linux/`, packaging, CI, docs.

## 1. Feature mapping

### Connections

| Area | TablePro feature + source | BookiE status + path | Rec | Lane | Effort | Priority |
|---|---|---|---|---|---|---|
| Saved connections | Create, edit, delete. `crates/app/src/services/saved_connection_editor.rs` | Present. `crates/storage/src/connections.rs`, `apps/linux/app/src/ui/app/connection.rs` | Already have | UX | - | - |
| Duplicate | Duplicate carries secrets to the copy. `services/secret_changes.rs` | Present, but the copy asks for its password on first connect (`ui/app/connection.rs:826-829`). Deliberate | Skip | UX | - | P3, current behaviour avoids silent secret sharing |
| Delete with or without history | `services/connection_deletion.rs` deletes secrets first, then entry, then optional history | Partial. Delete exists (`ui/app/connection.rs:329`, `execute_delete_connection`). No "also delete history" choice; history rows stay | Adapt | UX | S | P3, privacy nicety |
| Groups and colour tags | `storage/src/connection_group_name.rs`, `connection_color.rs` | Present. `crates/storage/src/connection_organization.rs`, `ui/app/organization.rs` | Already have | UX | - | - |
| Import and export | JSON without secrets. `storage/src/connections.rs` | Present. `crates/storage/src/connection_bundle.rs`, `ui/connection_bundle/` | Already have | UX | - | - |
| Test before saving | `ui/connect_dialog/connect_submission.rs` | Present. `ui/connect_dialog/mod.rs` | Already have | UX | - | - |
| Missing password prompt | `ui/credential_prompt/` with Remember Password, `core/src/credentials/` | Partial. Missing password reopens the connect dialog prefilled (`ui/app/connection.rs:772-815`). No small prompt, no Remember switch | Adapt | UX | M | P3, works today, just heavier |
| Certificate file check in form | `ui/connect_dialog/pem_validation.rs` parses CA and client files before Connect | Absent. Pickers only (`ui/connect_dialog/mod.rs:237-241`) | Adopt | UX | S | P3, earlier error |
| Read-only connection | Engine-level refusal per engine, subtitle says which | Present for PostgreSQL (`crates/drivers/postgres/src/lib.rs:123`), MySQL (`mysql/src/lib.rs:543`), SQLite, DuckDB, plus PolicyGuard. ClickHouse has no engine-level `readonly` setting (no match in `crates/drivers/clickhouse/src`) | Adapt | B3 | S | P3, PolicyGuard already blocks; defence in depth |
| SQLite create vs open | Explicit create (`drivers/sqlite/src/create_file.rs`, `core/src/file_open_mode.rs`). Opening a missing file fails | **Gap.** `crates/drivers/sqlite/src/lib.rs:71-79` uses `create_if_missing(!opts.read_only)`. A moved or mistyped file silently becomes a new empty database. An empty path opens `:memory:` | Adopt | B3 + UX | S | **P1, user can write into the wrong, empty file without warning** |
| Locate a moved SQLite file | `ui/session_window/locate_file.rs` | Absent (follows from the row above) | Adopt | UX | S | P2, pairs with the fix above |
| SQLite on network or FUSE filesystem | `services/file_location_kind.rs`, `ui/session_window/sqlite_location_dialog.rs` asks before read-write | Absent. No statfs check | Adapt | B3 + UX | S | P3, lock corruption risk is rare |
| Open SQLite from the file manager | Desktop `MimeType=application/vnd.sqlite3`, `Exec=tablepro %U`, `application/open_files.rs`, test `crates/app/tests/desktop_entry.rs` | Absent. `apps/linux/flatpak/com.tablepro.linux.desktop` has no MimeType, no `%U`. App uses default `ApplicationFlags` (`services/single_instance.rs:92`), no `HANDLES_OPEN` | Adopt | UX | M | P2, basic desktop integration |
| Kerberos (SQL Server) | KCM socket in Flatpak | Present. `crates/transport/src/lib.rs:422`, `apps/linux/flatpak/com.tablepro.linux.json:20-21` | Already have | B4 | - | - |
| Health and reconnect | Banner, backoff 5 to 60 s, reads replayed once | Present: `apps/linux/app/src/services/connection_monitor.rs:15-18` (30 s ping, 5 to 60 s backoff). Replay rule already recorded in `upstream-main-analysis-2026-10-20.md` §1 | Already have | UX/B4 | - | - |
| Wake reconnect on network change and resume | `app/src/runtime/network_watch.rs` (gio::NetworkMonitor, per-server reachability), `runtime/resume_detector.rs` (boot-time vs monotonic gap, works in Flatpak without logind) | Absent. Monitor wakes only on a 30 s `tokio::time::sleep`, which pauses during suspend. A dead link after resume can wait up to 30 s or until the next user action | Adopt | UX | S | P2, cheap, visible after every laptop resume |
| Server-side cancel | Per engine | Present (ADR 0005). Already recorded in `upstream-linux-adoption-2026-10-18.md` | Already have | B3/B4 | - | - |
| Per-connection statement timeout | Upstream backlog item | Present. `query_timeout_secs` in `crates/storage/src/connections.rs:118` | Already have | - | - | - |

### SSH and TLS

| Area | TablePro feature + source | BookiE status + path | Rec | Lane | Effort | Priority |
|---|---|---|---|---|---|---|
| System OpenSSH, ControlMaster, ssh_config, ProxyJump | `crates/ssh/src/` | Present. `crates/ssh/src/openssh/` plus built-in russh | Already have | B4 | - | - |
| Auth methods and askpass | Agent, key, password, keyboard-interactive | Present. `crates/ssh/src/openssh/askpass_bridge.rs`, `prompt.rs`, `ui/ssh_prompt.rs` | Already have | B4 | - | - |
| Host key review | SHA256 shown before connect. Changed key can be replaced in known_hosts | Partial by design. Unknown key prompt with fingerprint (`ui/ssh_prompt.rs:51`). Changed key refused (`crates/ssh/src/known_hosts.rs:100-107`) | Skip | B4 | - | P3, refusal is the safer default; maybe show the `ssh-keygen -R` hint |
| TLS modes and files | Disable, Require, Verify full; CA, client cert, server name | Present. `ui/connect_dialog/mod.rs:237-241`, `docs/connections.md` | Already have | B4 | - | - |
| Typed TLS failure with remedy | `core/src/tls_failure.rs` (UnknownIssuer, NameMismatch, Expired, Revoked, ServerRefusedTls...), `net/src/tls/classify.rs`, `app/src/ui/error_text/tls_remedy.rs` jumps to the CA or server-name field | **Gap.** One string `DriverError::Tls(String)`. `apps/linux/app/src/ui/error_text.rs:31-32` tells the user to "set TLS to Disabled" for every TLS error, including a failed certificate check | Adopt | B4 + UX | M | **P1, the current hint steers users to downgrade security on verify failures** |
| System trust store for every rustls driver | `net/src/tls/client_config.rs` uses `rustls-platform-verifier` plus extra roots | Partial. PostgreSQL and MySQL use native roots (`docs/connections.md:23`). ClickHouse uses bundled `webpki_roots` when no CA is named (`crates/drivers/clickhouse/src/tls.rs:51-54`). MongoDB sets `ca_file_path` only when the user names one (`crates/drivers/mongodb/src/lib.rs:173`), so it falls back to the crate's webpki roots. Redis not checked | Adopt | B4 (with B3) | S-M | P2, corporate CAs in `/etc/ssl` fail on these engines |

### Browse and edit

| Area | TablePro feature + source | BookiE status + path | Rec | Lane | Effort | Priority |
|---|---|---|---|---|---|---|
| Virtual grid, page sizes | `ui/grid/`, `ui/browse_tab/` | Present. `ui/grid/`, `ui/browse_tab/chrome.rs` | Already have | UX | - | - |
| Estimated count and Count Rows | `ui/browse_tab/count_policy.rs`, `core/src/meta/table_estimate.rs` | Absent; always `COUNT(*)` (`services/browse_query.rs:63-64`). Already recorded in backlog UI-19 / #549 | Already recorded | B3/UX | - | - |
| Filters | Operators, raw WHERE validated as one expression, match any/all | Present. `ui/filter_strip.rs` (AND/OR, Advanced raw SQL), presets (`ui/filter_presets.rs`) | Already have | UX | - | - |
| Sorting | Server sort for tables, local for results | Present. `ui/grid/local_sort.rs`, `services/browse_query/order.rs` | Already have | UX | - | - |
| Cell editors by kind | Inline, multiline, calendar, toggle, JSON check | Present. `ui/grid/editing.rs` (calendar, JSON popover), `ui/grid/full_value_editor.rs`, `ui/grid/choice_editor.rs` | Already have | UX | - | - |
| Insert, duplicate, delete rows | `ui/browse_tab/row_deletion.rs` | Present. `ui/grid/context_menu.rs:331-417` | Already have | UX | - | - |
| Set NULL, Empty, DEFAULT | Cell menu | Partial. Set NULL present (`context_menu.rs:339`). No Set Empty. New rows start as all NULL (`ui/browse_tab/row_ops.rs:84`). DEFAULT already recorded (NULL/default B3 decision in `0.2-feature-comparison.md`) | Adapt (Empty only) | UX | S | P3 |
| Undo and redo | Grid undo and redo | Partial. Undo in UI (`ui/browse_tab/messages.rs:88`). Redo exists only in the tracker (`services/change_tracker_materialize_tests.rs:373`); no Redo action | Adopt | UX | S | P3, tracker already supports it |
| Stop a running save | Stop between statements | Absent. No cancel path for grid saves in `ui/browse_tab/` | Adapt | UX + B4 | M | P3, must keep unknown-outcome audit semantics |
| Bulk delete confirmation | Threshold, preference | Present. `ui/preferences.rs`, `ui/browse_tab/row_ops.rs:235` | Already have | UX | - | - |
| Copy As | Rows, headers, JSON, CSV, Markdown, IN, INSERT; Copy Column Name; Row as JSON | Present. `ui/grid/context_menu.rs:480-512` | Already have | UX | - | - |
| Column widths, keyboard resize | Persisted widths; Shift+Alt+Left/Right | Widths present (`ui/grid/column.rs:309`). Keyboard resize already recorded in `upstream-main-analysis-2026-10-20.md` §6 (#561) | Already recorded | UX | - | - |
| Column order per table | Upstream backlog | Present. `ui/grid/column_order.rs` | Already have | UX | - | - |
| Paste rows | Upstream backlog | Present. `ui/browse_tab/paste.rs` | Already have | UX | - | - |
| FK jump | Upstream backlog | Present. "Go to Referenced Row", `ui/grid/context_menu.rs:519` | Already have | UX | - | - |
| CSV import | Mapping, one transaction, 64 MiB | Present. `ui/import_dialog.rs`, `services/csv_import_mappings.rs` | Already have | UX | - | - |
| Sidebar object kinds | Tables, partitioned, views, matviews, foreign tables | Partial. No foreign tables (no match for `foreign_table`). Routines, triggers, sequences in `ui/catalog_dialog.rs:173-174` | Adapt | B3 | S | P3, PostgreSQL FDW users only |
| Stale banner after failed refresh | `ui/tab_load/stale_banner.rs` keeps old content with one-line banner | Not verified as a distinct state | Skip for now | UX | - | P3 |

### Structure

| Area | TablePro feature + source | BookiE status + path | Rec | Lane | Effort | Priority |
|---|---|---|---|---|---|---|
| Definition and DDL edits | `core/src/ddl/` | Present. `crates/core/src/sql_ddl/`, `ui/structure_tab/` | Already have | B3/UX | - | - |
| SQL preview | `ui/structure_tab/sql_preview.rs` | Present. `ui/structure_tab/mod.rs:16` | Already have | UX | - | - |
| Destructive change review | `core/src/ddl/destructive_change.rs`, `change_review.rs`, `ui/structure_tab/review_dialog.rs` | Partial. Drop Table confirmation (`ui/app/structure.rs:70-95`) and PolicyGuard approvals. No per-change "loses data / can stop halfway" review | Adapt | B3 + UX | M | P2, data loss guard on type changes and drops |
| SQLite table rebuild | `drivers/sqlite/src/ddl/rebuild_plan.rs`: keeps rows, indexes, triggers, dependent views, AUTOINCREMENT; FK check before commit | Absent. BookiE refuses (`crates/core/src/sql_ddl/column.rs:18-27`, `index_fk.rs:100,165`) | Adopt | B3 | L | P2, common SQLite need; refusal is safe meanwhile |

### SQL editor

| Area | TablePro feature + source | BookiE status + path | Rec | Lane | Effort | Priority |
|---|---|---|---|---|---|---|
| Highlighting, scheme, toggle comment | GtkSourceView | Present. `ui/editor/mod.rs:718`, `sql_text.rs` | Already have | UX | - | - |
| Completion | Aliases, fuzzy match (`ui/editor/completion/fuzzy.rs`) | Partial. Schema-aware with aliases (`ui/editor/completion_*`). No fuzzy match | Adopt | UX | S | P3 |
| Token-preserving formatter | `ui/editor/format_plan.rs`, `significant_tokens.rs` | Present, same design. `crates/core/src/sql_format/mod.rs:52` | Already have | - | - | - |
| Script splitting | DELIMITER, GO n, bodies | Present, shared code. `crates/core/src/sql_syntax/script/` | Already have | - | - | - |
| Find and replace | Regex, case, word | Present. `ui/editor/find_bar.rs` | Already have | UX | - | - |
| Open, save, drop .sql | `ui/editor/sql_file.rs` | Present. `ui/editor/open_file.rs`, `split_view.rs` (DropTarget) | Already have | UX | - | - |
| Multi results, limits, Go to Error | `ui/result_pane/` | Present. `ui/editor/outcomes.rs`, `error_location.rs`, `stream_pages.rs`. Export All already recorded (ADR 0014) | Already have | UX | - | - |
| Drafts restore | `workspace/draft_writer.rs`, `restored_drafts.rs` | Present. `ui/app/workspace_persist.rs` | Already have | UX | - | - |
| Open transaction close guard | `ui/editor/transaction_dirty.rs` | Present. `ui/app/workspace_close.rs:153`, `ui/editor/session_mode.rs:255` | Already have | UX | - | - |
| Vim mode | Upstream backlog | Present. `ui/preferences.rs:259` | Already have | - | - | - |
| Snippets, multi-cursor | Upstream backlog | Absent in both. Multi-cursor already recorded in `0.2-feature-comparison.md` | Skip | UX | - | P3 |

### History, saved queries, export

| Area | TablePro feature + source | BookiE status + path | Rec | Lane | Effort | Priority |
|---|---|---|---|---|---|---|
| History store | SQLite FTS, filters, pins, retention, export SQL/CSV, Show in Files | Present. `crates/storage/src/query_history.rs` (FTS5, pins, retention), `ui/history_dialog.rs:70-71,591` | Already have | UX | - | - |
| Secret-bearing SQL kept out | `core/src/sql_syntax/credential_rules.rs` | Present (#988). Already recorded | Already have | - | - | - |
| Turn recording off | `services/history_preferences.rs` | Absent. Only retention and Clear (`ui/preferences.rs:140-171`) | Adopt | UX | S | P3, privacy switch for sensitive sessions |
| Saved queries | `storage/src/saved_queries/` | Present. `ui/saved_queries_dialog.rs`, `crates/storage/src/favorites.rs` | Already have | - | - | - |
| Formats | CSV, JSON, MD, HTML, XML, XLSX, SQL INSERT | Present. `crates/core/src/export/`, `ui/export_dialog/file.rs` | Already have | - | - | - |
| Full streamed export | Separate read-only connection | Already recorded (ADR 0014, `upstream-linux-movement-2026-10-18.md` §6.6) | Already recorded | - | - | - |
| Quit or close with a running export | `workspace/close_guard.rs`, `work_kind.rs` | Not found. No export check in `ui/app/workspace_close.rs` or `grid_close.rs`. Cancel exists in `ui/progress_dialog.rs` | Adopt | UX | S | P2, quitting truncates the file silently |

### Windows, session, desktop

| Area | TablePro feature + source | BookiE status + path | Rec | Lane | Effort | Priority |
|---|---|---|---|---|---|---|
| Window per session, single instance, New Window | `application/window_registry.rs` | Present. `services/window_registry.rs`, `services/single_instance.rs` (D-Bus plus flock), `ui/app/shortcuts.rs:69` | Already have | UX | - | - |
| Tab overview, adaptive layout | AdwTabOverview, breakpoints | Present. `ui/app/init_workspace.rs`, `ui/app/init_window.rs` (Breakpoint) | Already have | UX | - | - |
| Lazy first load of restored tabs | `ui/tab_load/first_load.rs` | Already recorded in `upstream-linux-movement-2026-10-18.md` §6.8 | Already recorded | UX | - | - |
| Restore every window at launch | `ui/session_window/session_restore.rs` | Partial. One connection restored (`services/window_state.rs:151-192`) | Adapt | UX | M | P3 |
| Logout and suspend inhibit | `workspace/window_inhibitor.rs`, `inhibit_reason.rs`: hold logout with unsaved edits; hold suspend while a save or export writes | Absent. No `inhibit` call in `apps/` | Adopt | UX | S | P2, logout during a save loses work; GTK gives this for free |
| Process hold while closing | `runtime/gio_process_hold.rs` keeps the app alive until connections close | Absent (no `hold()` use) | Adopt | UX | S | P3, clean audit terminal states on last-window close |
| Background-tab notifications | `ui/session_window/work_notifier.rs`: saves, exports, queries; withdrawn when the tab is viewed | Partial. Query finish only (`ui/editor/finish_notice.rs:23`) | Adapt | UX | S | P3 |
| Shortcuts and About | Shortcuts dialog; About with third-party licenses and debug info (`application/legal_section.rs`, `debug_info.rs`, `runtime_versions.rs`) | Partial. Shortcuts present (`ui/app/shortcuts.rs`). About has no licenses or debug info (`ui/app/status_pages.rs:124-142`). Diagnostics already proposed in `docs/proposals/devops-feedback-loop.md:68` | Adapt | UX | S | P3 |
| Crash report | `crash_report.rs` | Already recorded (`upstream-linux-movement-2026-10-18.md` §7) | Already recorded | UX | - | - |
| JSON logs | `logging.rs` | Present. `apps/linux/app/src/logging.rs:22-53` | Already have | - | - | - |

### Packaging, i18n, accessibility

| Area | TablePro feature + source | BookiE status + path | Rec | Lane | Effort | Priority |
|---|---|---|---|---|---|---|
| Version consistency | `build-aux/packaging/check_packaging.py:170-200` checks Cargo, metainfo newest release, CHANGELOG notes and spec agree | **Gap.** Cargo `0.2.0` (`apps/linux/app/Cargo.toml:3`), meson `0.1.6-dev` (`meson.build:1`), metainfo newest `0.1.5` (`apps/linux/flatpak/com.tablepro.linux.metainfo.xml:51`). No check exists | Adopt | UX | S | **P1, 0.2.0 publication is pending and would ship wrong AppStream data** |
| Desktop entry | MimeType, DBusActivatable, `new-window` action, Keywords, `X-GNOME-UsesNotifications`, plus a test | Partial. Minimal entry (`apps/linux/flatpak/com.tablepro.linux.desktop`) | Adopt | UX | S | P2 |
| D-Bus service file | `data/app.tablepro.TablePro.service.in` | Absent | Adopt | UX | S | P3, needed only with DBusActivatable |
| Man page | `data/tablepro.1` | Absent | Adopt | UX | S | P3, Arch packaging nicety |
| Metainfo screenshots | `data/screenshots/` referenced in metainfo | Absent. No `<screenshot>` in metainfo | Adopt | UX | S | P3 |
| gettext | POTFILES check, template | Present. `apps/linux/po/`, `scripts/update-translations.py --check` in `scripts/test-harness.sh:9` | Already have | UX | - | - |
| Translation runtime test | `crates/app/tests/i18n_catalog.rs` compiles a catalog and checks a child process shows translated text | Absent | Adapt | UX | S | P3, proves bindtextdomain works installed |
| Typed error reasons to translated text | `app/src/ui/error_text/*.rs` | Already recorded (`upstream-main-analysis-2026-10-20.md`, #3555/#3586) | Already recorded | UX | - | - |
| Accessibility audit | In-process Rust widget walk `crates/app/tests/accessibility/audit.rs` | Partial. AT-SPI Python on installed builds (`apps/linux/app/tests/gtk_safety.py`, `gtk_ux.py`) | Adapt | UX | M | P3, catches unlabelled controls in the cheaper gtk-widgets tier |
| Flatpak, deb, rpm, PPA/COPR | `build-aux/` | BookiE targets Arch first (`scripts/PKGBUILD`, `build-deb.sh`, `build-flatpak.sh`). Distribution choice already recorded | Skip | UX | - | - |

### Not applicable

| TablePro item | Reason |
|---|---|
| Oracle | Out of scope for BookiE |
| In-app AI chat, paid tiers, telemetry idea | Product rules; BookiE uses governed MCP via PolicyGuard |
| Upstream has no MCP on Linux | BookiE is ahead (`crates/mcp`, `crates/agentd`) |
| Extra engines in BookiE (Redis, MongoDB, DuckDB) | BookiE is ahead; Cassandra/Scylla absent in both |

## 2. Architecture and engineering ideas

| Idea | Upstream source | BookiE today | Recommendation | Lane | Effort | Priority |
|---|---|---|---|---|---|---|
| Typed TLS failure enum | `core/src/tls_failure.rs`, `net/src/tls/classify.rs` | `DriverError::Tls(String)` | Add a small `TlsFailure` enum in core, classify in each rustls driver via the existing `error_chain_text` walk, map to remedies in `ui/error_text.rs` | B4 + UX | M | P1 |
| One TLS client-config helper with platform verifier | `net/src/tls/client_config.rs` | Each driver builds its own; ClickHouse uses webpki roots | Share one rustls config builder for ClickHouse, Redis, MongoDB using `rustls-platform-verifier` plus extra roots. Keep provider consolidation separate (already recorded) | B4 | M | P2 |
| Workspace lints | `Cargo.toml` `[workspace.lints]`: `allow_attributes_without_reason`, `ignore_without_reason`, `unsafe_op_in_unsafe_fn`, `self_named_module_files` | Not set. 163 bare `#[allow(...)]` in crates/apps/tests | Turn on `ignore_without_reason` and `unsafe_op_in_unsafe_fn` now (cheap). Add `allow_attributes_without_reason` with a ratchet, converting to `#[expect(..., reason)]` | UX | S-M | P2 |
| cargo-deny bans with reasons | `deny.toml`: `yanked = "deny"`, `wildcards = "deny"`, bans on `rustls<0.23`, `rustls-pemfile`, `backoff`, `instant`, `rsa` scoped by `wrappers` | `yanked = "warn"`, `wildcards = "allow"`, no bans | Adopt `yanked = "deny"`, `wildcards = "deny"`, preventive bans for crates absent today, and scope `rsa` with `wrappers = ["sqlx-mysql", "russh", "ssh-key"]` so a new path needs review | UX | S | P2 |
| Release metadata check | `build-aux/packaging/check_packaging.py`, `metainfo_release.rs` | None | Port a small check into `scripts/` and the harness: Cargo, meson, metainfo, CHANGELOG versions agree | UX | S | P1 |
| Desktop entry test | `crates/app/tests/desktop_entry.rs` (glib KeyFile) | None | Add with the desktop entry fix | UX | S | P2 |
| Resume and network wakeups | `runtime/resume_detector.rs`, `network_watch.rs` | None | Notify the existing `connection_monitor` fault channel on both | UX | S | P2 |
| Session inhibit and process hold | `workspace/window_inhibitor.rs`, `runtime/gio_process_hold.rs` | None | Use `gtk::Application::inhibit` and `ApplicationExt::hold` from the existing in-flight save and export state | UX | S | P2 |
| Typed test fixtures crate | `crates/test-fixtures/` (versions, PKI, OpenSSH, PgBouncer) | Per-driver testcontainers helpers, `tests/fixtures`, `crates/drivers/shared/` | Skip a new crate. Reuse version enums only if the PostgreSQL version matrix grows | B3 | - | P3 |
| Clippy disallowed-methods | `crates/app/clippy.toml` | `scripts/check-gtk-blocking.py` | Already recorded (UP-6, `upstream-linux-adoption-2026-10-18.md`) | - | - | - |
| Session crate, operation runner, replay rule | `crates/session/` | Spread over app services | Already recorded (`upstream-main-analysis-2026-10-20.md`) | - | - | - |
| DriverCapabilities, WriteLedger, OwnedCalls | `core/src/capabilities.rs`, `write_ledger.rs`, `owned_calls.rs` | Partial equivalents | Already recorded (#1065, #947) | - | - | - |
| Conformance suite, value corpus, large table, kill during save | `crates/test-support/src/conformance/` | Partial | Already recorded (#594, #1032, #1029) | - | - | - |
| towncrier `changelog.d` | `towncrier.toml` | `CHANGELOG.md` | Already recorded; UP-9 kept the current convention | - | - | - |
| cargo-about notices, offline sources, smoke ordering | `build-aux/` | Partial | Already recorded (UP-7, UP-8) | - | - | - |
| meson | `meson.build`, `data/meson.build` | `meson.build` present | Already have; fix its version string | UX | S | P1 (via version check) |

## 3. ROADMAP mapping (`linux/ROADMAP.md`)

### Implemented sections

| ROADMAP item | BookiE status |
|---|---|
| Saved connections, groups, import/export, test | Present |
| Passwords prompt with Remember | Partial (connect dialog reopens) |
| Read-only connections | Present, plus PolicyGuard; ClickHouse engine flag missing |
| SQLite: choose, create, open from Files, Locate, network FS | Partial: choose only; missing file is silently created |
| Kerberos SQL Server | Present |
| Health and reconnect | Present; no network/resume wakeups |
| Cancel on server | Present |
| SSH OpenSSH, jump hosts, auth, host keys | Present; changed key refused by design |
| TLS modes and certificates | Present |
| TLS remedies | Absent; current hint says disable TLS |
| Grid, filters, sorting, cell editors | Present |
| Rows: insert, duplicate, delete, NULL, undo | Present; no Empty, Redo UI or Stop save |
| Bulk delete confirm, Copy As, column widths | Present; keyboard resize recorded |
| CSV import | Present |
| Sidebar object kinds | Partial: no foreign tables |
| Structure edits and preview | Present |
| Destructive review | Partial |
| SQLite rebuilds | Absent (refused) |
| Editor, completion, formatter, scripts, find, files, results, drafts | Present; no fuzzy completion |
| History, secret filter, Show in Files, saved queries | Present; no off switch |
| Export formats and scope | Present; full export recorded under ADR 0014 |
| Export quit guard | Absent |
| Window per session, single instance, tabs | Present |
| Session restore | Partial (one connection) |
| Close safety | Present for edits and transactions; no export guard |
| Logout and suspend inhibit | Absent |
| Notifications | Partial (queries only) |
| Preferences | Present |
| Shortcuts, About | Shortcuts present; About lacks licenses and debug info |
| Flatpak, deb, rpm | Different targets; Arch first |
| Desktop file Open With, D-Bus activation, man page, screenshots | Absent |
| Translations | Present |
| Logs and crash report | Logs present; crash report recorded |
| Tests (a11y audit, conformance) | Partial; conformance recorded |

### Backlog section

| ROADMAP backlog item | BookiE status |
|---|---|
| Per-connection statement timeout | Present (`query_timeout_secs`) |
| Kerberos SPN override | Absent in both |
| Paste rows | Present |
| NOW() or CURRENT_TIMESTAMP as a cell value | Absent in both; follows the B3 default decision |
| Binary columns from and to a file | Absent in both |
| Time and timestamp pickers | Absent in both (calendar only) |
| Column order per table | Present |
| Functions, procedures, sequences, triggers in sidebar | Partial: in the catalog dialog, not the tree |
| CREATE INDEX for one index | Not found |
| FK jump | Present |
| Drag to reorder columns in structure | Absent in both |
| ER diagram | Absent in both |
| Multi-cursor | Absent; recorded |
| Vim mode | Present |
| Snippets | Absent in both |
| Flathub, AUR, first translations, manual Orca pass | BookiE has its own PKGBUILD; Orca pass is in #561 |
| Redis, MongoDB, DuckDB | Present in BookiE |
| Cassandra/Scylla | Absent in both |
| Oracle | Not applicable |
| Ideas: monitoring, backup, schema diff | BookiE has backup (`ui/app/backup.rs`, `crates/dump`); others absent in both |

## 4. Top 15 to adopt, ranked

1. **Stop silent SQLite file creation.** Open existing files only; add an explicit Create path and a Locate prompt. B3 + UX, S, P1. `crates/drivers/sqlite/src/lib.rs:71-79`.
2. **Typed TLS failures with safe remedies.** Remove the blanket "set TLS to Disabled" advice for verify failures. B4 + UX, M, P1. `apps/linux/app/src/ui/error_text.rs:31-32`.
3. **Release metadata consistency check.** Cargo, meson, metainfo, CHANGELOG must agree before 0.2.0 ships. UX, S, P1.
4. **Logout and suspend inhibit** while edits are unsaved or a save or export writes. UX, S, P2.
5. **Quit and close guard for running exports.** UX, S, P2.
6. **Wake the connection monitor on network change and resume.** UX, S, P2.
7. **System trust store for ClickHouse, MongoDB and Redis** through one shared rustls config. B4, S-M, P2.
8. **Desktop entry: MimeType, `%U`, `HANDLES_OPEN`, new-window action**, with a KeyFile test. UX, M, P2.
9. **cargo-deny hardening:** `yanked = "deny"`, `wildcards = "deny"`, scoped `rsa`, preventive bans. UX, S, P2.
10. **Workspace lints:** `ignore_without_reason`, `unsafe_op_in_unsafe_fn` now; `allow_attributes_without_reason` with a ratchet. UX, S-M, P2.
11. **Destructive DDL review** for type changes, drops and multi-step saves. B3 + UX, M, P2.
12. **SQLite table rebuild** for changes ALTER cannot do. B3, L, P2.
13. **History recording off switch** and delete-history option on connection delete. UX, S, P3.
14. **Redo action, Set Empty, fuzzy completion.** Small UX gaps where the core already supports the behaviour. UX, S, P3.
15. **About: third-party licenses and Copy debug info**, following `docs/proposals/devops-feedback-loop.md`. UX, S, P3.

## Limits

No code was run. Redis trust roots, the stale-banner state and CREATE INDEX copy were not verified. The MongoDB root behaviour is inferred from BookiE setting `ca_file_path` only on user input and from upstream's ROADMAP note on the same crate.
