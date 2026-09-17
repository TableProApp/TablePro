# TablePro Linux remediation plan

**Date**: 2026-09-14  
**Fixes**: every finding in [audit-2026-09-13-full.md](audit-2026-09-13-full.md) (F-001 to F-138)  
**Size**: 172 commit-sized tasks in 66 landing steps across 9 workstreams  
**Details**: contracts, decisions and full task specifications are in [plan-2026-09-14-audit-remediation-details.md](plan-2026-09-14-audit-remediation-details.md)

This is one complete plan. Every finding gets a root-cause fix and nothing is deferred. The landing sequence is dependency order only: the app builds and every test passes after each step. Step numbers written inside task texts in the details file come from an earlier draft order; the landing sequence below is authoritative.

## Owner decisions

| Topic | Decision |
|---|---|
| App ID | `app.tablepro.TablePro` (development profile `app.tablepro.TablePro.Devel`) |
| Build system | Meson + Cargo, following Snapshot and Fractal; `cargo run` keeps working |
| API floor | relm4 `gnome_50` (GTK 4.22, libadwaita 1.9, GLib 2.88), sourceview5 `v5_18`; Flatpak `org.gnome.Platform//50` |
| App model | One `adw::ApplicationWindow` per connection session, GApplication uniqueness, `app.new-window`, `app.quit` |

## Decisions this plan makes that need sign-off

- **Two maintained forks.** PostgreSQL moves from sqlx-postgres to tokio-postgres 0.7.18 with a three-commit fork at TableProApp/rust-postgres (column type ids on simple queries, transaction status, row-limited text portal). SQL Server moves to a five-commit fork at TableProApp/tiberius on tiberius-rs main (no panics on server input, sql_variant and CLR UDT decoding, exact MONEY, TDS attention cancel, injected rustls config). Every fork commit is filed upstream, and deny.toml allows no other git source. Reason: sqlx-postgres keeps the cancel key private, and tiberius panics inside its codec, so neither can be fixed in the driver alone.
- **Pooling and MySQL transport.** deadpool 0.13 managers replace sqlx pools for PostgreSQL, MySQL and SQL Server (SQLite keeps one workspace connection). MySQL and MariaDB run on sqlx-mysql 0.9 through a private Unix socket relay so TLS verifies the real host name through SSH tunnels.
- **TLS modes.** Disable, Require and VerifyFull only, with VerifyFull the default for new connections. Prefer (downgradable) and VerifyCa (unsafe with sqlx's CA handling) are not offered; a server name override covers the VerifyCa use case.
- **Clean break for stored data.** No migration code. Installed builds keep ~/.config/tablepro, cargo run uses a separate tablepro-devel profile, SavedConnection replaces use_tls with a required tls field, old com.tablepro.linux keyring items are abandoned. An unreadable old file is moved aside behind a banner, never overwritten. Your current saved connections will not load after the switch.
- **Toolchain.** Rust 1.98 (the Flatpak rust-stable//25.08 version), workspace lints denying unwrap, expect, panic, todo and print macros, and a size check of 800 production lines per file.
- **Package and binary rename.** The Cargo package and binary become tablepro (library tablepro_app).
- **Keyboard changes.** app.new-window takes Ctrl+Shift+N (GNOME Console precedent), so Set NULL moves to Ctrl+BackSpace; history gets Ctrl+Shift+H.
- **Read-only guarantees.** SQLite and ClickHouse (readonly=2, allow_ddl=0) refuse writes at the engine. MySQL and PostgreSQL editor sessions use a session default that a user statement can turn off, and the switch subtitle says so. SQL Server cannot enforce it; the subtitle asks for a login granted only SELECT.
- **Flatpak permissions.** --filesystem=home plus /media, /run/media and /mnt (SQLite needs its -wal and -journal siblings), --socket=ssh-auth, the Heimdal KCM socket, and a committed lint-exceptions.json that must be requested from Flathub. The org.freedesktop.secrets talk-name is removed.
- **Distribution channels.** .deb for Ubuntu 26.04 (GitHub Release, rustup toolchain because Ubuntu ships Rust 1.93) and .rpm for Fedora 44 through a COPR project. AppImage is dropped: no base older than Ubuntu 26.04 or Fedora 44 has GLib 2.88 and GTK 4.22, and AppImage forbids the compiled-in locale, schema and D-Bus paths.
- **One large atomic commit.** Step 30 switches the driver contract, all five drivers, the value model, sessions and every caller in one refactor(linux)! commit of 23 tasks, built on a stacked branch and squashed only when the tip passes every suite. This follows the atomic API change rule; it is the only step of that size.
- **Accepted advisory.** RUSTSEC-2023-0071 (rsa Marvin attack) is accepted in deny.toml, scoped to in-process SSH RSA identity signatures.

## Architecture after the plan

### FA · Application, window and session ownership model

- **D1** Application controller is a GObject subclass of adw::Application, not a RelmApp root
- **D2** One window per session: picker -> connecting -> workspace; disconnect returns to picker
- **D3** Session: generation-stamped leases, OperationRunner chokepoint, runtime-free start, bounded shutdown
- **D4** Connect attempts: per-window generation gate, cancellation, adoption only on the GTK thread
- **D5** Health: pure HealthPolicy over a coalescing mailbox; probe outside the pool; Failed parks; per-session reachability
- **D6** Per-workspace tracker registries with borrow-safe handles
- **D7** Panic boundary at the command and spawn layers plus a process hook
- **D8** Tabs own their fetches through RequestSequencer; supersession includes a server-side cancel contract
- **D9** SchemaCatalog in Session with shared in-flight fetches; a refresh never clears the cache
- **D10** Close, quit and logout are event-driven loops over SaveLedger and dialogs; quit exits by use count
- **D11** Runtime sizing and blocking I/O
- **D12** Workspace persistence: in memory, per SessionKey, off-thread writes, write-blocked after a failed load, per-profile directory
- **D13** GApplication uniqueness and launch surface
- **D14** Operation chokepoint with deadlines, generation observation and read replay
- **D15** Injected TaskSpawner for every background task
- **D16** SessionKey and claim before establish on every path
- **D17** Ordered teardown for disconnect and approved close
- **D18** Testable crate layout: library target, fake driver crate, process-level application tests
- **D19** config and GResource work for both cargo run and Meson

### FB · Value model, column kinds and SQL dialect contracts

- **D1** Value and column metadata are in-memory transport types and are never persisted
- **D2** Decimal is a string-backed, validated SqlDecimal with NaN, +/-Infinity and allocation-bounded parsing
- **D3** Integers: Int(i64), UInt(u64), WideInt(WideInteger)
- **D4** Float32 and Float64 are separate, and non-finite values are first-class
- **D5** Temporals: Temporal<T> for infinity, SqlTime for extended time, OffsetTimestamp with offset-sensitive identity, unrepresentable dates as Other
- **D6** JSON is validated server text
- **D7** Other and Undecodable are distinct from Null, and a decode failure never yields Null
- **D8** Columns are classified from each engine's structured catalog; sqlparser only where text is the sole source
- **D9** The dialect is owned by its connection and depends only on server-invariant properties
- **D10** Engine SQL generation lives in the driver crates; core keeps engine-agnostic structure
- **D11** The encoding decision is made once, when the dialect renders the marker, and carried to the binder in BoundParam
- **D12** ClickHouse: typed JSON cell decoding, exact UTF-8 handling, CAST literals for writes
- **D13** LIKE and case-insensitive matching are owned by the dialect
- **D14** sqlparser 0.63 validates user-typed DDL and classifies catalog default text; no step waits on an upstream release
- **D15** Edit text is lossless and edit parsing depends on the edit context
- **D16** MSSQL money, sql_variant and CLR UDT are fixed in a maintained tiberius fork with an upstream-compatible API
- **D17** CSV formula neutralisation is keyed on the Value variant
- **D18** MySQL tinyint(1) is Bool with integer storage and keeps its exact integer
- **D19** Saves are guarded per row with typed statement kinds, and a failed guard refuses the whole save
- **D20** Browse SQL is built in core with dialect projections; Connection::fetch_rows is removed
- **D21** Clipboard and export literals parse identically under every session mode

### FC · Driver connection contract, transport security, cancellation and sessions

- **FC-D1** PostgreSQL moves to tokio-postgres 0.7.18 with a three-commit TableProApp fork
- **FC-D2** MySQL and MariaDB on sqlx-mysql 0.9.0 through a private socket relay, flavour-aware
- **FC-D3** sqlx 0.9.0 and MSRV 1.94
- **FC-D4** SQL Server uses tiberius-rs main plus a TableProApp patch series
- **FC-D5** ClickHouse uses Client::with_http_client over our transport, TLS and product info
- **FC-D6** Transport model: injected streams, Happy Eyeballs, reroute, private UDS relay only for sqlx-mysql
- **FC-D7** TLS modes: Disable, Require, VerifyFull; default VerifyFull
- **FC-D8** Trust anchors as TrustAnchor slice plus parse-checked system certificates; aws-lc-rs only
- **FC-D9** Read-only enforced per engine; ReadOnlyConnection deleted
- **FC-D10** Server-side cancellation and deadlines from tasks the connection owns
- **FC-D11** Liveness and establishment deadlines with cancellable connect and open_session
- **FC-D12** Editor sessions: one owned physical connection per tab, run by a session actor
- **FC-D13** Commit outcome model; PostgreSQL resolves exactly, ClickHouse resolves on the answering node
- **FC-D14** DriverError v2 with typed diagnostics, observable timeout phases and ErrorCategory
- **FC-D15** Metadata: kinds within the connected database, index key model, row identity, keyset and ctid-window paging
- **FC-D16** SQLite: explicit create, absolute paths, one workspace connection, exact transaction state
- **FC-D17** russh 0.63.3 with an injected decision-only HostKeyVerifier; tablepro-net; no globals
- **FC-D18** Pooling through deadpool managers except SQLite
- **FC-D19** Display row limit never changes outcome, transaction state or statement order
- **FC-D20** Result streaming with an async sink and TCP backpressure
- **FC-D21** PostgreSQL session bounds that pass through PgBouncer
- **FC-D22** SQL Server login: no ApplicationIntent, one followed redirect, Kerberos off the async workers
- **FC-D23** PostgreSQL tls-server-end-point channel binding
- **FC-D24** Stored connections change schema in place; no migration
- **FC-D25** Delivery: additive commits, one atomic switch, docs

### FD · Platform, build, runtime and distribution layer

- **FD-D1** Meson + Cargo layout, build drivers, one source for build values
- **FD-D2** Embedded GResource with an explicit resource base path
- **FD-D3** GSettings for preferences and window state; files for structured or unbounded data
- **FD-D4** Persistence locations, profile isolation, durable private writes, clean break
- **FD-D5** Application identity, desktop integration and D-Bus activation
- **FD-D6** i18n pipeline
- **FD-D7** Logging and startup errors
- **FD-D8** Toolchain, workspace lints, error crates
- **FD-D9** GNOME 50 API floor
- **FD-D10** Single aws-lc-rs crypto provider across the complete dependency graph
- **FD-D11** SQL Server Kerberos as a cargo feature
- **FD-D12** sqlx 0.9, system SQLite, gettext-rs 0.8, dependency hygiene
- **FD-D13** Third-party license notices and generated package license metadata
- **FD-D14** Flatpak manifests: one committed Devel manifest, a rendered Flathub manifest
- **FD-D15** Flatpak finish-args and linter exceptions
- **FD-D16** Kerberos inside the Flatpak
- **FD-D17** Metainfo: releases and screenshot URLs that always resolve
- **FD-D18** Icons for removed emblem glyphs
- **FD-D19** CI layout and supply-chain gates
- **FD-D20** Non-Flatpak channels
- **FD-D21** Stylesheet
- **FD-D22** Window geometry restored per window, persisted on close
- **FD-D23** RUSTSEC-2023-0071 risk acceptance with a correct scope

### Rules every task follows

- Names are unique across foundations. FA owns Session, SessionWindow and Workspace. The per-tab driver connection is EditorSession. FA's struct is EstablishedConnection, while Transport is FC's trait. The core TableRef is owned. FA's reachability enum is ReachabilityTarget. FC's settings type is WorkspaceSettings.
- Every Connection call carries CallOptions { deadline, cancel }. Deadlines come from DefaultDeadlines, derived from LivenessPolicy, and drivers own all timing and server-side stops. OperationRunner adds no timers. RetiredConnection::close, bounded by close_timeout, is the only outer timeout.
- UI code reaches a database only through Session::run or run_cancellable, whose op gets (ConnectionLease, CallOptions), or through an EditorSession the tab owns. SQL is built inside the op from lease.dialect(). No component stores a dialect or a connection.
- Futures that poll drivers, SSH or transports run only inside TaskSpawner or GuardedCommand futures, so they always have tokio context. The GTK thread builds only runtime-free primitives.
- Value, column and metadata transport types never derive serde. Only deliberately persisted configuration types do (TlsConfig, AuthMode, SavedConnection, workspace and storage records).
- aws-lc-rs is the single crypto provider, enforced through the dependency graph and deny.toml with dev edges. The app builds every rustls ClientConfig with an explicit provider and never calls install_default.
- Rust 1.98, relm4 gnome_50 and sourceview5 v5_18. No msrv key in any clippy.toml. Workspace lints deny unwrap, expect, panic, todo, unimplemented, dbg, print and allow_attributes.
- Exactly two git dependencies, both TableProApp forks: tiberius (on c1d2e741) and rust-postgres (on tokio-postgres-v0.7.18). Every fork commit is filed upstream, and deny.toml allows no other git source.
- PostgreSQL app-generated SQL must stay safe behind PgBouncer. It uses no startup options and no named prepared statements, directly or through tokio-postgres typeinfo. Every projected result OID is built-in.
- MySQL workspace connections pin time_zone +00:00 for lossless TIMESTAMP identity. Editor sessions keep the server time zone (F-056). Both use pipes_as_concat(false) and no_engine_substitution(false).
- Persistence goes through StoragePaths, profile-scoped as tablepro or tablepro-devel, with private durable writes run on the injected spawner. GSettings holds preferences and window geometry. Stored data makes a clean break with no migrations.
- Build values have one source (VERSION, build-aux/APP_ID, tablepro-build-support). The package is tablepro, the lib is tablepro_app and the bin is tablepro.
- Test doubles live only in crates/test-support. GTK and application tests run under xvfb-run -a dbus-run-session. Integration suites run without the kerberos feature, which is covered in the fast job and in Flatpak.
- A dependency is added in the commit that first uses it and removed in the commit that stops using it. Any trait or signature change updates every driver, caller and test in the same commit.

## Landing sequence

### Step 1: Security fixes and dependency cleanup

Nothing depends on these, and the ClickHouse identifier escape (F-018) is a security fix, so they go first. There are no shared sources. Merge rule for every step: tasks merge in the listed order. They may share Cargo.toml, Cargo.lock, build-linux.yml, docs indexes and one-line mod registrations, never another Rust source file.

- `W8-01` Remove unused and misplaced dependencies and refresh the lockfile (F-113, F-114)  
  `chore(deps): remove unused dependencies and the storage to ssh edge`
- `W3-01` Escape backslashes in ClickHouse quoted identifiers (F-018)  
  `fix(core): escape backslashes in ClickHouse quoted identifiers`
- `W3-02` Neutralise only textual CSV cells (F-023)  
  `fix(core): neutralise only textual cells in CSV export`

### Step 2: External fork series (TableProApp/rust-postgres, TableProApp/tiberius)

These are commits on fork branches, in the listed order. rust-postgres: W2-01, W2-02, W2-03. tiberius: (a) W2-04+W8-05, (b) W2-05+W8-06, (c) W2-06+W8-07, (d) W2-07+W8-08, (e) W2-08+W8-09, each pair a single commit with W2's scope. The workspace is unchanged until the pins in steps 7 and 8.

- `W2-01` rust-postgres fork: column type metadata on simple query results (F-013, F-014)  
  `feat(tokio-postgres): expose type, table and column ids on SimpleColumn`
- `W2-02` rust-postgres fork: transaction status from ReadyForQuery (F-013)  
  `feat(tokio-postgres): report transaction status from ReadyForQuery on simple query streams`
- `W2-03` rust-postgres fork: row-limited unnamed text portal and COPY handling (F-012, F-013, F-014)  
  `feat(tokio-postgres): add row-limited unnamed text portal queries and COPY data messages`
- `W2-04` tiberius fork: protocol errors instead of panics, full PRELOGIN encryption matrix (F-008, F-015)  
  `fix(codec): return protocol errors instead of panicking and negotiate encryption per MS-TDS`
- `W8-05` tiberius fork: server-reachable panics become protocol errors (F-046)  
  `fix(codec): return protocol errors instead of panicking on server input`
- `W2-05` tiberius fork: decode sql_variant and CLR UDT columns (F-015)  
  `feat(codec): decode sql_variant values and CLR UDT columns`
- `W8-06` tiberius fork: sql_variant and UDT decoding (F-046)  
  `feat(codec): decode sql_variant and user-defined type columns`
- `W2-06` tiberius fork: opt-in exact MONEY decoding (F-015)  
  `feat(config): add money_as_numeric for exact MONEY and SMALLMONEY decoding`
- `W8-07` tiberius fork: opt-in exact MONEY decoding (F-046)  
  `feat(config): add money_as_numeric for exact MONEY and SMALLMONEY decoding`
- `W2-07` tiberius fork: phase-aware request cancellation (Attention or ignore bit) (F-012, F-041)  
  `feat(client): add cancel_pending using TDS attention and the ignore bit`
- `W8-08` tiberius fork: Client::cancel_pending via TDS attention (F-046)  
  `feat(client): add cancel_pending to stop a running request with a TDS attention`
- `W2-08` tiberius fork: inject a rustls ClientConfig (F-008, F-047, F-048)  
  `feat(config): accept an injected rustls ClientConfig`
- `W8-09` tiberius fork: inject a rustls ClientConfig (F-046, F-111)  
  `feat(tls): accept an injected rustls ClientConfig`

### Step 3: Rust 1.98, workspace lint denies, StartupError

Every later commit is written under the no-unwrap/expect/panic lints and license inheritance. It touches many app files, so it lands alone.

- `W8-02` Rust 1.98, workspace lint denies, license inheritance, typed startup error, CI container ubuntu:26.04 (F-060, F-132)  
  `build(linux): pin Rust 1.98 and deny unwrap, expect and panic workspace-wide`

### Step 4: gettext-rs 0.8, additive core transport types, test fixtures

The sources are disjoint: app i18n.rs/main.rs, new core files plus core lib.rs, a new SQLite test, and the new test-fixtures crate. W2-09 creates core SshFailure and the endpoint/TLS types that W1-01 and W8-04 need.

- `W8-03` Migrate to gettext-rs 0.8 with an explicit single-threaded init contract (F-114)  
  `build(deps): migrate to gettext-rs 0.8`
- `W2-09` Core endpoint, TLS, liveness, transport and trust types (F-008, F-032, F-041, F-047, F-048, F-049)  
  `feat(core): add endpoint, TLS, liveness, transport and trust types`
- `W9-01` SQLite driver integration suite (F-059)  
  `test(drivers): add a SQLite integration suite`
- `W9-02` Container fixture crate with test PKI, per-engine key placement and an OpenSSH forwarding drop-in (F-059)  
  `test(linux): add shared container fixtures with a generated test PKI`

### Step 5: Lib/bin split, integration matrix, script lexer, OpenSSH resolver

W4-01 creates tablepro_app::run and crates/test-support, which W8-14, W9-05 and W1-07 need. W9-03 generates the docker matrix and deletes smoke_local.rs. W6-05 edits core lib.rs and W1-01 edits core ssh_failure.rs, so they don't overlap. W1-01 takes ADR 0010.

- `W4-01` Library/binary split and crates/test-support (F-068, F-072)  
  `build(app): split the tablepro_app library from the tablepro binary and add crates/test-support`
- `W9-03` Integration matrix generated from docker-ignored test targets, ignore-reason rule and CI jobs (F-059, F-107)  
  `ci(linux): run every docker test target from a matrix generated from cargo metadata`
- `W6-05` Add a data-driven SQL script lexer and planner to core (F-030)  
  `feat(core): add a dialect-driven SQL script lexer and planner`
- `W1-01` Resolve SSH destinations and jump chains through OpenSSH's client configuration (F-009, F-065)  
  `feat(ssh): resolve SSH destinations through OpenSSH client configuration`

### Step 6: russh 0.63.3 with host-key verification and confirmation in one PR

W1-02, W8-04 and W1-03 are one PR. Strict host keys without the fingerprint dialog would refuse every unknown host, and this clears RUSTSEC-2026-0153/0154. The doc-reference gate (unique ADR numbers), the driver script-syntax statics and the additive value types share no sources with that PR.

- `W1-02` Move to russh 0.63.3 and decide host keys over all known_hosts files with OpenSSH semantics (F-009, F-065, F-121)  
  `refactor(ssh)!: move to russh 0.63.3 and verify host keys with OpenSSH known_hosts semantics`
- `W8-04` russh 0.63.3 with an injected HostKeyVerifier (F-046)  
  `refactor(ssh)!: move to russh 0.63.3 and inject a HostKeyVerifier`
- `W1-03` Confirm unknown, changed and revoked SSH host keys with the fingerprint (F-009)  
  `feat(ssh): ask before trusting an unknown or changed SSH host key`
- `W9-04` Documentation reference gate (F-107)  
  `ci(linux): check documentation links, paths, packages and ADR numbers`
- `W6-06` Declare each engine's script syntax and completion keywords (F-030, F-090)  
  `feat(drivers): declare script lexing rules and keywords per engine`
- `W3-03` Add lossless value component types (F-006, F-052)  
  `feat(core): add lossless value component types`

### Step 7: Pin the tiberius fork with aws-lc-rs only, GTK test harness, SSH authentication

W8-10 needs the fork head (step 2), W8-04 and test-fixtures. It creates deny.toml. W9-05 must precede W4-03, W4-13, W4-17 and W7, which use test-support-gtk. W1-04 adds core credential_prompt and SSH auth.

- `W8-10` Pin the tiberius fork, use aws-lc-rs as the only crypto provider, add deny.toml (F-046, F-111)  
  `build(deps): pin tiberius to the TableProApp fork and use aws-lc-rs as the only crypto provider`
- `W9-05` GTK test harness crate with a verified accessibility audit, and headless GTK CI (F-059)  
  `test(linux): add a GTK test harness with an accessibility audit and run GTK tests headless in CI`
- `W1-04` Authenticate every SSH hop in OpenSSH's method order through an injected credential prompter (F-065, F-121)  
  `feat(ssh): authenticate each hop with the agent, keys, keyboard-interactive and password in OpenSSH order`

### Step 8: Kerberos feature, structure save routing, tablepro-net

W2-10 appends the rust-postgres fork to deny.toml from step 7 and consumes the step-2 fork. The sources are disjoint: connect_dialog/mssql, the structure route/workspace_state, and the new crates/net.

- `W8-11` SQL Server Kerberos behind a kerberos cargo feature (F-112)  
  `build(deps): gate SQL Server Kerberos behind a kerberos cargo feature`
- `W4-02` Route structure save completion by StructureMode and persist Edit-mode Structure tabs (F-019)  
  `fix(app): finish Edit-mode structure saves and restore Edit-mode structure tabs`
- `W2-10` tablepro-net: direct TCP, private socket relay, trust store and TLS classification (F-008, F-041, F-047, F-048, F-049)  
  `feat(net): add tablepro-net with direct TCP, private socket relay and rustls trust`

### Step 9: ProxyJump chains, sqlx 0.9

W1-13 builds on W1-04. W8-12 depends on W8-10 and W8-11. Storage connections.rs and query_history.rs are different files.

- `W1-13` Connect through ProxyJump chains built the way OpenSSH builds them (F-009, F-065)  
  `feat(ssh): connect through ProxyJump chains resolved like OpenSSH`
- `W8-12` sqlx 0.9 with aws-lc-rs, system SQLite and mysql-rsa (F-111, F-114)  
  `build(deps): migrate to sqlx 0.9 with aws-lc-rs, system SQLite and mysql-rsa`

### Step 10: App ID app.tablepro.TablePro and binary tablepro

This is the clean break before generated config. It edits lib.rs (APP_ID after step 5), the secret schema literal and the flatpak renames.

- `W8-13` App ID app.tablepro.TablePro and binary tablepro (F-037)  
  `refactor(linux)!: adopt app ID app.tablepro.TablePro and binary name tablepro`

### Step 11: Build-support crate, generated config.rs, embedded GResource

Needs the lib split and the new ID. Until W4-13, the app runs through an adw::Application with resource_base_path passed to RelmApp::from_app.

- `W8-14` Build-support crate, generated config.rs and embedded GResource with style.css (F-037, F-087, F-091, F-099)  
  `build(linux): generate build config and embed a GResource with style.css`

### Step 12: Meson layer, data templates, Devel Flatpak on GNOME 50

Adds the meson gtk suite env: GTK_A11Y=test, GDK_BACKEND=x11, GSETTINGS_BACKEND=memory, GSK_RENDERER=cairo.

- `W8-15` Meson layer, data templates, icons, GNOME 50 Devel Flatpak and meson in CI (F-007, F-033, F-038, F-060, F-087, F-099, F-112, F-123, F-124)  
  `build(linux): add meson build with desktop, metainfo, icons and a GNOME 50 Devel Flatpak`

### Step 13: GNOME 50 API floor and AdwShortcutsDialog resource

Creates shortcuts-dialog.ui with id shortcuts_dialog and deletes gtk::ShortcutsWindow and win.shortcuts, because AdwApplication installs app.shortcuts. W4-13, W5-07, W7-02, W7-03 and W6-16 edit this file later.

- `W8-16` Raise the API floor to GNOME 50 and replace deprecated GTK APIs (F-060, F-108)  
  `build(linux): raise the API floor to GNOME 50 and replace deprecated GTK APIs`

### Step 14: Replace removed emblem icons

Serial with W8-16 on the editor, history and structure files.

- `W8-17` Replace removed emblem icons (F-039)  
  `fix(linux): replace removed emblem icons with stock and bundled symbolic icons`

### Step 15: GSettings schema and storage AppSettings

Settings must exist before preferences move.

- `W8-18` GSettings schema and the storage AppSettings wrapper (F-064)  
  `feat(storage): add the GSettings schema and a typed AppSettings wrapper`

### Step 16: Preferences and window geometry in GSettings

One commit, since W6-01 belongs to FD 12. It deletes services/preferences.rs and window_state.rs before StoragePaths, as W8 requested, so W1-05 needs no accessors for them.

- `W8-19` Move preferences, window geometry and the editor font and style scheme to GSettings (F-064, F-091)  
  `feat(linux): move preferences, window geometry and editor font to GSettings`
- `W6-01` Drop the dead confirmation preference and read page size when each tab opens (F-096)  
  `feat(linux): GSettings for preferences and geometry (lands inside global step 17, FD 12)`

### Step 17: Gettext keywords with plural and context

Rewrites 549 tr! sites in 26 files, so it lands before the editor split and all new UI strings.

- `W8-20` Gettext functions with plural, context and named placeholders, with a real-locale catalog test (F-087)  
  `refactor(linux): use gettext keywords with plural and context support`

### Step 18: Journald logging and panic hook, editor module split

W4-03 uses logging::install_panic_hook. W6-02 moves editor.rs to ui/editor/ after the tr! rewrite. lib.rs and the editor files are disjoint.

- `W8-21` Journald logging with RUST_LOG and G_MESSAGES_DEBUG, and the process panic hook (F-130)  
  `feat(linux): log to journald with RUST_LOG and G_MESSAGES_DEBUG control and a logging panic hook`
- `W6-02` Split the SQL editor into a module directory (enabling work)  
  `refactor(editor): split the SQL editor into a module directory`

### Step 19: Panic boundary and crates/app/clippy.toml

Creates crates/app/clippy.toml without msrv, plus the guarded_command/deliver bans. It lands before most new UI code so that code follows the rule from the start. It touches nearly every UI file, so it lands alone.

- `W4-03` Panic boundary and non-panicking delivery for every background command (F-016)  
  `feat(app): resolve every background command through a panic boundary with non-panicking delivery`

### Step 20: Plain-text boundary for markup properties

Security fix (F-027) that needs the step-19 clippy.toml. It touches about 22 UI files, including host_key_review.rs from step 6.

- `W6-03` Route every markup-parsing widget property through one plain-text boundary (F-027)  
  `fix(app): render driver errors, SQL, names and translations as plain text`

### Step 21: StoragePaths through GLib, private durable writes

Needs the GSettings move (step 16), sqlx 0.9 and the app ID. It keeps the single-instance flock and resolves its path through glib::user_runtime_dir. W4-13 deletes it.

- `W1-05` Resolve storage paths through GLib and write private files durably (FD step 11) (F-061, F-062, F-063)  
  `refactor(storage): resolve paths through GLib and write private files durably`

### Step 22: Connection list safety, column and syntax types

W1-06 needs W1-05. W3-04 adds app clippy bans (step 19) and sqlparser. Storage/UI and core are disjoint.

- `W1-06` Never overwrite an unreadable saved-connection list; serialize writes and surface the failure (F-003)  
  `fix(storage): never overwrite an unreadable connection list`
- `W3-04` Add column type, SQL syntax and referential action types (F-021, F-054, F-117)  
  `feat(core): add column type, SQL syntax and referential action types`

### Step 23: Typed keyring errors, undoable editor replace

W1-07 creates storage SecretKind before W6-09 and W4-06. W6-04 owns asynchronous file drop through gio::File::load_contents_future.

- `W1-07` Report keyring failures with typed errors, unlock before reading, store secrets before the list entry and label them clearly (F-010, F-066, F-119, F-121)  
  `fix(storage): surface keyring failures, unlock before reading and label secrets clearly`
- `W6-04` Replace editor text undoably and load dropped files asynchronously (F-028)  
  `fix(editor): keep Format, history replace and file drop in the undo history`

### Step 24: History migrations, SSH form revalidation

Storage error.rs and history on one side, ssh_section and connect_dialog on the other: disjoint.

- `W1-08` Version the query history database with embedded migrations (F-118)  
  `feat(storage): version the query history with embedded migrations`
- `W6-07` Revalidate the connect form when any SSH row changes (F-031)  
  `fix(connect-dialog): revalidate the form when SSH rows change`

### Step 25: TaskSpawner runtime, storage isolation tests, Enter submits dialogs

W4-04 needs W4-03 and StoragePaths. It creates LatestWinsWriter and converts column_widths.rs and filter_settings.rs, which W1-09 then deletes. W9-06 needs W1-05, W1-06 and W1-08.

- `W4-04` Injected TaskSpawner, sized relm4 runtime, HistoryService, off-thread config writes (F-071)  
  `refactor(app): run background work through an injected spawner on a sized relm4 runtime`
- `W9-06` Storage isolation tests across two storage roots (F-059)  
  `test(storage): prove history and connection stores keep no process-wide state`
- `W6-08` Make Enter submit every form dialog (F-098)  
  `fix(app): submit form dialogs with Enter`

### Step 26: Session primitives, connect dialog defaults

W4-05 creates pure session/* files. W6-09 needs W6-08, GSettings and storage SecretKind.

- `W4-05` Pure session primitives: health policy, mailbox, attempts, keys (F-044, F-072, F-073)  
  `feat(app): add pure session health, attempt and key primitives`
- `W6-09` Open the connect dialog with the remembered driver's defaults and surface keyring failures (F-097)  
  `fix(connect-dialog): open with the chosen driver's defaults and report keyring failures`

### Step 27: Versioned column-width and filter documents

Creates workspace/mod.rs and persist_debouncer.rs on top of LatestWinsWriter. It shares app/mod.rs with steps 28 and 29.

- `W1-09` Coalesce column-width and filter writes into versioned documents that never overwrite unreadable files (F-011, F-120)  
  `fix(app): coalesce column width and filter writes and keep unreadable files`

### Step 28: Editor drafts

DraftStore and DraftWriter, which W4-11 consumes.

- `W1-10` Keep editor text as untruncated per-tab drafts written off the GTK thread and flushed on close (F-011, F-063)  
  `feat(app): keep editor text as untruncated drafts written off the main thread`

### Step 29: History retention through HistoryService

Last pre-switch dependency of W6-12.

- `W6-10` Apply history retention on the scheduled prune and clear history through the service (F-096)  
  `fix(preferences): apply history retention on the scheduled prune and clear history through the service`

### Step 30: Driver contract v2 switch (single refactor(linux)! commit)

The old Connection, DatabaseDriver, Value, ConnectOptions, SshTunnel and DatabaseService are deleted, so every consumer changes in the same commit. That covers: core contract v2 (including stream_read, OwnedCalls, fetch_table_definition, ForeignKeyMode, OperationKind::Export, build_export, PageSpec.layout, paging_mode, COUNT_BIG); five drivers; lossless values, dialects, catalogs and codecs; app Sessions; SSH transport; the editor on EditorSession; connect dialog v2; conformance and TLS suites.

- `W2-11` Core driver contract v2: Connection, DriverError, EditorSession, writes, metadata, OwnedCalls and WriteLedger (F-001, F-012, F-013, F-041, F-055, F-057, F-058, F-116)  
  `refactor(linux)!: switch to driver contract v2 with lossless values, dialects and generation-leased sessions`
- `W2-12` PostgreSQL driver on tokio-postgres: pooler-safe flights, psql-model editor sessions, phase-aware writes, metadata and decode (F-001, F-008, F-012, F-013, F-014, F-041, F-047, F-048, F-049, F-055, F-057, F-058, F-116)  
  `refactor(linux)!: switch to driver contract v2 with lossless values, dialects and generation-leased sessions`
- `W2-13` MySQL and MariaDB driver: relay transport, server-default session, KILL QUERY, engine-aware writes, raw editor protocol (F-001, F-008, F-012, F-013, F-014, F-041, F-047, F-048, F-049, F-055, F-056, F-057, F-058, F-116)  
  `refactor(linux)!: switch to driver contract v2 with lossless values, dialects and generation-leased sessions`
- `W2-14` SQLite driver: explicit open, atomic create-or-replace, one workspace connection, progress-handler cancel, exact transaction state (F-001, F-012, F-013, F-032, F-055, F-057, F-058, F-109, F-116, F-134)  
  `refactor(linux)!: switch to driver contract v2 with lossless values, dialects and generation-leased sessions`
- `W2-15` SQL Server driver on the tiberius fork: pools, in-band attention cancel, read-only transaction guard, routing, Kerberos off-worker, typed TLS failures, exact decode (F-001, F-008, F-012, F-013, F-014, F-015, F-041, F-047, F-048, F-049, F-055, F-057, F-058, F-116)  
  `refactor(linux)!: switch to driver contract v2 with lossless values, dialects and generation-leased sessions`
- `W2-16` ClickHouse driver over our transport: typed cells, probe-first unkillable writes, query_log and mutations resolution, KILL QUERY for reads (F-001, F-008, F-012, F-013, F-017, F-041, F-047, F-048, F-049, F-055, F-057, F-058, F-116)  
  `refactor(linux)!: switch to driver contract v2 with lossless values, dialects and generation-leased sessions`
- `W2-17` App surfaces for contract v2: Security group, SQLite file rows, read-only subtitles, categorised driver errors (F-001, F-008, F-032, F-047, F-049, F-116)  
  `refactor(linux)!: switch to driver contract v2 with lossless values, dialects and generation-leased sessions`
- `W3-05` Replace Value, column metadata and statement types with the lossless model (contract switch, core model) (F-006, F-052, F-054)  
  `refactor(linux)!: switch to driver contract v2 with lossless values, dialects and generation-leased sessions`
- `W3-06` SqlDialect trait, row-identity keys and dialect-driven core SQL builders (contract switch) (F-006, F-018, F-022, F-054)  
  `refactor(linux)!: switch to driver contract v2 with lossless values, dialects and generation-leased sessions`
- `W3-07` Per-engine SqlDialect implementations (contract switch) (F-006, F-018, F-022, F-053, F-054)  
  `refactor(linux)!: switch to driver contract v2 with lossless values, dialects and generation-leased sessions`
- `W3-08` Classify columns and defaults from each engine's structured catalog (contract switch) (F-006, F-021, F-054)  
  `refactor(linux)!: switch to driver contract v2 with lossless values, dialects and generation-leased sessions`
- `W3-18` Table definitions with column attributes, inbound foreign keys and SQLite dependents (contract switch) (F-020, F-045, F-050, F-051)  
  `refactor(linux)!: switch to driver contract v2 with lossless values, dialects and generation-leased sessions`
- `W3-19` Foreign-key suspension in WriteBatch, SQLite write transactions and MySQL workspace sql_mode (contract switch) (F-020, F-051, F-053)  
  `refactor(linux)!: switch to driver contract v2 with lossless values, dialects and generation-leased sessions`
- `W3-09` Decode and encode PostgreSQL, MySQL and SQLite values losslessly (contract switch) (F-006)  
  `refactor(linux)!: switch to driver contract v2 with lossless values, dialects and generation-leased sessions`
- `W3-10` Structure DDL on table definitions, typed defaults, structural validation and a static SQL Server default drop (contract switch) (F-021, F-050, F-117)  
  `refactor(linux)!: switch to driver contract v2 with lossless values, dialects and generation-leased sessions`
- `W3-11` Rewrite app SQL generation, row keys and copied SQL on dialects and column kinds (contract switch) (F-006, F-022, F-053, F-054)  
  `refactor(linux)!: switch to driver contract v2 with lossless values, dialects and generation-leased sessions`
- `W4-06` App part of the driver contract v2 switch: generation-leased Sessions replace DatabaseService (F-002, F-016, F-044, F-072, F-076, F-077, F-078)  
  `refactor(linux)!: switch drivers, core and app to driver contract v2 with generation-leased sessions`
- `W1-11` W1 portion of the atomic contract switch: SSH session transport, pinned connect and credential shapes, keyring credentials, sqlx statement logging off (F-009, F-010, F-061, F-065, F-122)  
  `refactor(linux)!: switch drivers, ssh and app to driver contract v2`
- `W6-11` Map driver, connect and operation errors by ErrorCategory (enabling work)  
  `refactor(linux)!: switch drivers, ssh and app to driver contract v2 (lands inside this atomic commit)`
- `W6-12` Run editor SQL through a tab-owned EditorSession, one statement or batch per run, with a results list (F-029, F-030, F-092)  
  `refactor(linux)!: switch drivers, ssh and app to driver contract v2 (lands inside this atomic commit)`
- `W6-13` Rebuild the connect dialog on ConnectRequest v2 with Security, SQLite file and SSH agent rows (F-031, F-097, F-098)  
  `refactor(linux)!: switch drivers, ssh and app to driver contract v2 (lands inside this atomic commit)`
- `W9-07` Connection v2 conformance module and suite, shipped in the contract switch (F-059)  
  `refactor(linux)!: switch to driver contract v2 with lossless values, dialects and generation-leased sessions`
- `W9-08` TLS conformance suite, shipped in the contract switch (F-059)  
  `refactor(linux)!: switch to driver contract v2 with lossless values, dialects and generation-leased sessions`

### Step 31: Tracker handles, driver docs, format plan

W4-07 edits trackers, grid.rs and browse_tab.rs. W2-19 is docs with ADR 0013. W6-14 edits editor/mod.rs.

- `W4-07` Per-workspace tracker registries with borrow-safe handles (F-076)  
  `refactor(app): give each workspace its own tracker registries with borrow-safe handles`
- `W2-19` Document driver contract v2, transports, trust, pooler requirements and per-engine behaviour (F-001, F-008, F-012, F-013, F-041, F-047, F-058, F-109)  
  `docs(linux): document driver contract v2, transports, trust and pooler requirements`
- `W6-14` Format only statements whose tokens survive sqlformat (F-028)  
  `fix(editor): keep statements sqlformat would change unformatted`

### Step 32: Export split, statement cursor

W3-17 lands before the grid move (step 35) and W5-02. Disjoint from W6-15's editor files.

- `W3-17` Export values at column precision with exact JSON numbers (F-023, F-052)  
  `fix(core): export values at column precision with exact JSON numbers`
- `W6-15` Present ScriptPlan statement boundaries through a shared editor cursor helper (F-029)  
  `feat(editor): select the statement Run at Cursor executes`

### Step 33: Undo and edit order, reference cycles

Both need W4-07. W4-08 edits change_tracker and browse_tab; W4-09 edits workspace_tabs, grid, filter_strip and editor.

- `W4-08` Undo restores the prior pending value; saves follow edit order deterministically (F-074)  
  `fix(app): undo restores the previous pending value and saves apply edits in the order they were made`
- `W4-09` Break reference cycles in tab view, grid, filter strip, editor and structure tab (F-075)  
  `fix(app): break reference cycles in the workspace tab tree, grid, filter strip and editors`

### Step 34: Tab-owned sequenced fetches and SchemaCatalog

Moves browse_tab.rs to browse_tab/mod.rs and adds SchemaCatalog::refresh_columns and Session::refresh_columns (XW14).

- `W4-10` Tabs own sequenced, cancellable fetches that recover after reconnect; shared SchemaCatalog (F-002, F-040, F-072, F-133)  
  `refactor(app): let tabs own sequenced fetches that recover after reconnect, with a shared schema catalog`

### Step 35: DdlDialect plans with the DDL suite, grid module move

W9-09 ships in W3-12's commit (ADR 0011). W5-01 needs W4-07 and W4-10. The structure files and the grid/editor files are disjoint.

- `W3-12` Generate DDL through per-engine DdlDialect plans against fetched table definitions (F-021, F-045, F-050, F-054, F-117)  
  `refactor(core)!: generate DDL through per-engine DdlDialect plans against table definitions`
- `W9-09` DDL execution conformance suite, shipped in the DdlDialect commit (F-059)  
  `refactor(core)!: generate DDL through per-engine DdlDialect plans against table definitions`
- `W5-01` Move the data grid into a ui/grid module (F-004)  
  `refactor(app): move the data grid into a ui/grid module`

### Step 36: Per-session WorkspaceStore, column attribute preservation

W4-11 needs W4-10 and W1-10 and reuses persist_debouncer.rs. W3-13 touches driver DDL only.

- `W4-11` Per-session WorkspaceStore with off-thread writer; editor changes carry no text; dropped files load asynchronously (F-002, F-019, F-070)  
  `refactor(app): persist each session's workspace off the main thread and load dropped files asynchronously`
- `W3-13` Preserve every column attribute when MySQL, PostgreSQL and SQL Server redefine a column (F-020)  
  `fix(drivers): preserve column attributes when a column definition is restated`

### Step 37: SaveLedger, CloseGuard, CloseBlocker seam

Edits app/mod.rs, row_ops.rs, browse_tab, structure_tab and error_text, and adds workspace/close_blocker.rs for XW5.

- `W4-12` SaveLedger with stoppable saves, event-driven CloseGuard, unknown save outcomes, WindowInhibitor (F-016, F-019, F-036, F-067, F-073, F-110)  
  `fix(app): make saving, closing and logout event-driven with stoppable saves and unknown-outcome handling`

### Step 38: Renames and primary keys, grid cell resolution

Structure/core DDL and grid/row_ops are disjoint. W5-02 needs W3-17.

- `W3-14` Rename columns, change primary keys and toggle auto-increment in the structure editor (F-045)  
  `feat(core): rename columns and change primary keys and auto-increment in the structure editor`
- `W5-02` Resolve grid cell events to row objects through the column view cell (F-004)  
  `fix(app): resolve grid cell events to row objects through the column view cell`

### Step 39: SQL Server default drop, bound cell notify, completion

W6-17 needs SchemaCatalog (step 34) and edits ui/app before the move.

- `W3-15` Drop and re-add SQL Server default constraints around column type changes (F-050)  
  `fix(drivers): drop and re-add SQL Server default constraints around column type changes`
- `W5-03` Notify bound cells of tracked row changes instead of swapping row objects (F-086)  
  `fix(app): notify cells of tracked row changes instead of swapping row objects`
- `W6-17` Complete tables, columns and keywords from the schema catalog (F-090)  
  `feat(editor): complete tables, columns and keywords from the schema catalog`

### Step 40: SQLite rebuilds, TableProApplication

W4-13 needs W4-12 and the shortcuts dialog (step 13). It deletes single_instance.rs and libc, rebinds grid Set NULL to <Primary>BackSpace, and binds win.show-history to <Primary><Shift>h.

- `W3-16` Create SQLite foreign keys inline and rebuild SQLite tables for structure changes (F-045, F-051)  
  `feat(drivers): rebuild SQLite tables for structure changes and create foreign keys inline`
- `W4-13` TableProApplication subclass: D-Bus uniqueness, app actions, New Window, QuitSequence, query-end (F-036, F-068, F-071, F-110)  
  `feat(app): run as a TableProApplication with D-Bus uniqueness, New Window and an app-level quit`

### Step 41: SessionWindow and ui/workspace move

W4-14 moves ui/app to ui/workspace and splits it into shell.rs, sidebar.rs, tabs.rs, tab_labels.rs and persistence.rs. It uses per-page set_content and ToastOverlay. W5-04 (grid) and W6-20 (structure lists after W3-16) are disjoint.

- `W4-14` SessionWindow per connection session with picker, connecting, failed and workspace pages (F-002, F-040, F-044, F-075, F-076, F-077, F-078)  
  `feat(app): open one window per connection session`
- `W5-04` Remove discarded drafts from the grid and make Delete act on the menu's row set (F-026)  
  `fix(app): remove discarded drafts from the grid and act on the menu's row set`
- `W6-20` Bind structure lists to list models and drop the idle suppression flag (F-128)  
  `refactor(structure): bind column, index and foreign key lists to list models`

### Step 42: Reachability, credential prompts, SQLite location, exact editors, destructive review, tab-view keys

All need the SessionWindow. The sources are disjoint: runtime and health_banner; the session_window prompt; the location dialog and connection_row; grid editors; structure review; workspace tab view.

- `W4-15` Per-session reachability and resume-from-suspend signals (F-072, F-073)  
  `feat(app): react to per-session reachability and resume from suspend`
- `W1-12` Ask for passwords, passphrases and server prompts the keyring or configuration cannot provide (F-010, F-065)  
  `feat(app): ask for passwords and SSH prompts the keyring cannot provide`
- `W2-18` SQLite file location: network, FUSE and portal detection, Locate… recovery (F-032, F-134)  
  `feat(connection-form): locate moved SQLite files and open network-filesystem databases read-only`
- `W5-06` Edit grid cells from lossless edit text with exact editors (F-005, F-024, F-025)  
  `fix(app): edit grid cells from lossless edit text with exact editors`
- `W6-21` Review destructive schema changes before applying them (F-094)  
  `feat(structure): review destructive schema changes before applying them`
- `W7-01` Keep Ctrl+Home/End and Ctrl+Shift+Home/End for widgets inside the workspace tab view (F-034)  
  `fix(app): keep Ctrl+Home and Ctrl+End for editors and grids inside the tab view`

### Step 43: Session restore, index and FK dialogs, grid keyboard, open files

W4-17 adds the restore-session key and its row. W6-22 deletes structure_tab_dialogs.rs. W5-07 edits shortcuts-dialog.ui. W8-22 edits desktop and metainfo templates.

- `W4-17` Record open session windows and reopen them on launch (F-044, F-076)  
  `feat(app): reopen the connection windows that were open at quit`
- `W6-22` Validate Add Index and Add Foreign Key live with catalog pickers (F-095, F-098)  
  `feat(structure): validate index and foreign key dialogs live and pick references from the catalog`
- `W5-07` Make grid cells keyboard focusable with native cell navigation and keyboard menus (F-004, F-025)  
  `fix(app): make grid cells keyboard focusable with native navigation and keyboard menus`
- `W8-22` Open SQLite files from Files and the command line (F-069, F-123)  
  `feat(linux): open SQLite files from Files and the command line`

### Step 44: Parked host-key review, history opt-out, grid rendering, architecture docs

W1-16 runs after W4-17's schema edit and edits W6-12's run_history.rs. W4-16 (ADR 0012) needs W4-15 and W4-17.

- `W1-14` Review a rejected SSH host key from a parked session (F-009)  
  `fix(app): let the user review a rejected SSH host key from the connection banner`
- `W1-16` Let people turn off query history and never record statements that carry credentials (F-061)  
  `feat(linux): let users turn off query history and never record credential statements`
- `W5-08` Render grid cells from borrowed display text with stock data-table styling (F-103, F-126)  
  `refactor(app): render grid cells from borrowed display text with stock data-table styling`
- `W4-16` Document the application, session and window-per-session architecture (F-002, F-068, F-071, F-076)  
  `docs(linux): document the application, session and window-per-session architecture`

### Step 45: Connection deletion, browse page ownership

W1-15 needs WorkspaceStore::purge and the SessionWindow. W5-09 needs W5-08.

- `W1-15` Delete a saved connection's secrets first, then its entry, then everything stored for it (F-066)  
  `fix(app): delete a connection's secrets first and purge everything stored for it`
- `W5-09` Keep one owner per browse page, key rows on every identity column, and replace pages with a single splice (F-004, F-103)  
  `perf(app): keep one owner per browse page and key rows on every identity column`

### Step 46: In-place refresh, streaming encoders

Browse tab/workspace and core export are disjoint.

- `W5-10` Refresh browse tabs in place and keep the last good page when a reload fails (F-102)  
  `fix(app): refresh browse tabs in place and keep the last good page when a reload fails`
- `W5-14` Streaming row encoders for CSV, TSV, JSON and Markdown (F-104, F-138)  
  `feat(core): add streaming row encoders for CSV, TSV, JSON and Markdown export`

### Step 47: Structure refresh, column failures, streaming export

W5-15 implements CloseBlocker and moves export_dialog.rs:266 and history_dialog.rs:940 writes to ReplaceFileWriter. It also widens the std::fs UI ban.

- `W5-11` Keep loaded structure on screen when a structure refresh fails and refetch columns after schema saves (F-102)  
  `fix(app): keep loaded structure on screen when a structure refresh fails`
- `W5-12` Fail browse tabs visibly when columns cannot be loaded and refetch columns on refresh (F-100)  
  `fix(app): surface browse column fetch failures and refetch columns on refresh`
- `W5-15` Stream exports to disk off the GTK thread with progress and cancel (F-104)  
  `feat(app): stream exports to disk off the GTK thread with progress and cancel`

### Step 48: Row counts, history search

W6-18 lands after W5-15 because it rewrites history_dialog into a module.

- `W5-13` Show row count estimates and count exact totals on demand (F-042)  
  `feat(app): show row count estimates and count exact totals on demand`
- `W6-18` Search history by substring and page it in a GtkListView (F-027, F-093)  
  `feat(history): search queries by substring and page results in a list view`

### Step 49: Whole-table export, history connection filter

W5-16 uses stream_read and build_export from step 30.

- `W5-16` Export whole tables and complete query results from the export dialog (F-043, F-104)  
  `feat(app): export whole tables and complete query results`
- `W6-19` Filter history by connections that have history and undo deletions (F-093, F-135)  
  `fix(history): list connections that have history and undo deletions with a toast`

### Step 50: Result limit banner, clipboard formats

W5-17 mounts ResultSetView in editor/result_item.rs. W5-19 edits grid menus, editor/mod.rs and workspace/mod.rs.

- `W5-17` Show editor result row limits with a banner and offer Export All (F-043)  
  `feat(app): show editor result row limits with a banner and offer Export All`
- `W5-19` Copy grid data with format-specific clipboard types rendered off the GTK thread (F-104, F-138)  
  `feat(app): copy grid data with format-specific clipboard types rendered off the GTK thread`

### Step 51: Accelerator table, result sorting

W7-02 needs W5-07, W4-13, W4-14 and W6-12 and edits pre-split browse_tab, filter_strip and grid_menus. W5-18 edits column_factory and result_pane.

- `W7-02` Route every keyboard shortcut through one accelerator table and keep the shortcuts dialog in sync with it (F-080, F-081)  
  `refactor(app): route every shortcut through one accelerator table`
- `W5-18` Sort editor result grids by column header (F-127)  
  `feat(app): sort editor result grids by column header`

### Step 52: Split header bars, About dialog, history filters, editor docs

Disjoint: the workspace shell, application/about_dialog, history_filters, docs.

- `W7-03` Split header bars per pane, tab overview at the window root, adaptive tab bar, sidebar toggle and window size floor (F-035, F-079, F-082)  
  `refactor(app): give each pane its own header bar and put the tab overview at the window root`
- `W7-12` Build the About dialog from the embedded metainfo (F-137)  
  `feat(app): build the About dialog from the app metainfo`
- `W7-14` Replace the history filter popover of combo rows with drop-downs and a toggle group (F-125)  
  `refactor(app): filter history with drop-downs and a toggle group instead of a popover`
- `W6-23` Document editor scripts, results, history search and structure review (enabling work)  
  `docs(linux): document editor scripts, history search and structure review`

### Step 53: Find and replace, recycling sidebar, license notices

W6-16 needs W7-02's table. W8-23 needs W7-12's build_about_dialog.

- `W6-16` Add find and replace to the SQL editor (F-089)  
  `feat(editor): add find and replace backed by GtkSourceSearchContext`
- `W7-04` Recycling GtkListView table sidebar with schema sections, filter and shared context menu (F-085)  
  `refactor(app): list tables in a recycling sidebar list with schema sections`
- `W8-23` Ship third-party license notices (F-115)  
  `build(linux): ship third-party license notices`

### Step 54: Picker model, non-colour pending state

W7-05 needs W1-15 and W2-18. W7-09 needs W5-08 and W6-18.

- `W7-05` Picker rows on a shared model that follows the connection store, with one delete confirmation (F-083)  
  `fix(app): confirm deleting a saved connection once`
- `W7-09` Show pending state without colour and give icon buttons translated accessible labels (F-088)  
  `fix(app): show pending changes without colour and label icon buttons for screen readers`

### Step 55: Title resolver, reveal in Files

Workspace title files versus preferences/history/app_services.

- `W7-08` Resolve tab and window titles in one place, mark unsaved tabs with the page icon, restore the active tab by persisted index (F-105)  
  `fix(app): resolve tab titles in one place and restore the active tab`
- `W7-11` Reveal the history database in Files instead of opening its folder (F-131)  
  `fix(app): select the history database in Files instead of opening its folder`

### Step 56: Edit, rename, duplicate and group connections

Shares session_window/mod.rs with steps 57 and 58.

- `W7-06` Edit, rename, duplicate and group saved connections (F-101)  
  `feat(app): edit, rename, duplicate and group saved connections`

### Step 57: Connecting and failed pages

Needs W7-06's Edit Connection.

- `W7-07` Connecting and connection-failed pages with a spinner paintable, announcements and Edit Connection (F-084)  
  `feat(app): show connection progress and failures on status pages with edit and announcements`

### Step 58: Completion notifications

Needs W7-08, W5-15 and W4-12.

- `W7-10` Desktop notification when a query, save or export finishes in an inactive tab (F-129)  
  `feat(app): notify when a query, save or export finishes in a background tab`

### Step 59: HIG capitalisation check

Runs after every UI string task. W6-22 removed structure_tab_dialogs.rs.

- `W7-13` GNOME header and sentence capitalisation for UI strings, checked in CI (F-125)  
  `fix(linux): apply GNOME header and sentence capitalisation to UI strings and check it in CI`

### Step 60: Browse tab and preferences splits, Flathub manifest

Splits land after the last edit to each file. W8-24's screenshots follow the final UI.

- `W9-10` Split the browse tab update into per-domain inputs, handlers, layout builders and child components (F-106)  
  `refactor(app): split the browse tab update into per-domain inputs and child components`
- `W9-13` Build each preferences page in its own module (F-106)  
  `refactor(app): build each preferences page in its own module`
- `W8-24` Rendered Flathub manifest, lint exceptions, screenshots and branding (F-007, F-033, F-038)  
  `build(flatpak): render the Flathub manifest and finalize sandbox permissions`

### Step 61: Structure tab and filter strip splits, RSA hint

W9-11 is serial with W9-10 on tab_factory.rs. W8-25 extends W1-04's identity.rs.

- `W9-11` Split the structure tab update and init into per-domain inputs, handlers and page builders (F-106)  
  `refactor(app): split the structure tab update into per-domain inputs and page builders`
- `W9-12` Turn the filter strip into a component with factory rule rows (F-106)  
  `refactor(app): turn the filter strip into a component with factory rule rows`
- `W8-25` Recommend Ed25519 or ssh-agent for RSA identity files (F-046)  
  `feat(ssh): recommend Ed25519 or ssh-agent for RSA identity files`

### Step 62: Accessibility smoke tests, CI rewrite

W9-14 audits every page after all UI tasks. W8-26 keeps the generated matrix.

- `W9-14` Application accessibility smoke tests across session window pages and dialogs (F-059)  
  `test(app): audit accessible labels on every session window page and dialog`
- `W8-26` CI: meson, release-shaped Flatpak, supply chain, i18n drift and all driver suites (F-007, F-046, F-060, F-087, F-111, F-112, F-113, F-132)  
  `ci(linux): gate on meson, the release-shaped Flatpak, supply chain, i18n drift and all driver suites`

### Step 63: Size caps, deb and rpm

W9-15 needs every Rust-editing task to have landed.

- `W9-15` Deny clippy too_many_lines and cap Rust production files at 800 lines (F-106)  
  `build(linux): deny clippy too_many_lines and cap Rust production files at 800 lines`
- `W8-28` .deb for Ubuntu 26.04 and .rpm for Fedora 44 from meson install, release workflow (F-099, F-136)  
  `build(linux): package .deb for Ubuntu 26.04 and .rpm for Fedora 44 from meson install`

### Step 64: Regression map

Needs the named tests from all workstreams, plus W8-26.

- `W9-16` Critical-finding regression map with a checker (F-059)  
  `test(linux): map every critical finding to named regression guards and check the map`

### Step 65: Roadmap and docs index, workflow on main

W8-27 copies the final build-linux.yml; no later step edits it.

- `W9-17` Rewrite the roadmap from the code and index every guide (F-107)  
  `docs(linux): rewrite the roadmap from the code and index every guide`
- `W8-27` Identical Linux workflow on main so the weekly schedule fires (F-060)  
  `ci(linux): add the Linux workflow and weekly dispatcher to main`

### Step 66: README, CONTRIBUTING, ADRs 0014 and 0015

Last reconciliation against the final code.

- `W9-18` Reconcile README and CONTRIBUTING with the code and add ADRs 0014 and 0015 (F-107)  
  `docs(linux): reconcile README and contributing guide with the code and add ADRs 0014 and 0015`

## Workstreams

### W1 · Persistence, secrets and SSH tunnel

| Task | Title | Findings | Step | Depends on |
|---|---|---|---|---|
| W1-01 | Resolve SSH destinations and jump chains through OpenSSH's client configuration | F-009, F-065 | 5 | W2-09 |
| W1-02 | Move to russh 0.63.3 and decide host keys over all known_hosts files with OpenSSH semantics | F-009, F-065, F-121 | 6 | W1-01, W2-09, W8-04, W9-02 |
| W1-03 | Confirm unknown, changed and revoked SSH host keys with the fingerprint | F-009 | 6 | W1-02 |
| W1-04 | Authenticate every SSH hop in OpenSSH's method order through an injected credential prompter | F-065, F-121 | 7 | W1-02, W9-02 |
| W1-13 | Connect through ProxyJump chains built the way OpenSSH builds them | F-009, F-065 | 9 | W1-04, W9-02 |
| W1-05 | Resolve storage paths through GLib and write private files durably (FD step 11) | F-061, F-062, F-063 | 21 | W1-02, W6-02, W8-12, W8-14, W8-19 |
| W1-06 | Never overwrite an unreadable saved-connection list; serialize writes and surface the failure | F-003 | 22 | W1-05 |
| W1-07 | Report keyring failures with typed errors, unlock before reading, store secrets before the list entry and label them clearly | F-010, F-066, F-119, F-121 | 23 | W1-05, W1-06, W4-01 |
| W1-08 | Version the query history database with embedded migrations | F-118 | 24 | W1-05 |
| W1-09 | Coalesce column-width and filter writes into versioned documents that never overwrite unreadable files | F-011, F-120 | 27 | W1-05, W1-06, W4-04 |
| W1-10 | Keep editor text as untruncated per-tab drafts written off the GTK thread and flushed on close | F-011, F-063 | 28 | W1-05, W1-09, W4-04, W6-02 |
| W1-11 | W1 portion of the atomic contract switch: SSH session transport, pinned connect and credential shapes, keyring credentials, sqlx statement logging off | F-009, F-010, F-061, F-065, F-122 | 30 | W1-07, W1-13, W2-10, W2-11, W4-05, W4-06, W9-02 |
| W1-12 | Ask for passwords, passphrases and server prompts the keyring or configuration cannot provide | F-010, F-065 | 42 | W1-04, W1-11, W4-14 |
| W1-14 | Review a rejected SSH host key from a parked session | F-009 | 44 | W1-03, W1-11, W4-05, W4-06, W4-14 |
| W1-15 | Delete a saved connection's secrets first, then its entry, then everything stored for it | F-066 | 45 | W1-07, W1-08, W1-09, W1-10, W4-05, W4-11, W4-14 |
| W1-16 | Let people turn off query history and never record statements that carry credentials | F-061 | 44 | W1-05, W3-06, W3-07, W4-04, W4-14, W4-17, W6-12, W8-18 |

### W2 · Driver implementations

| Task | Title | Findings | Step | Depends on |
|---|---|---|---|---|
| W2-01 | rust-postgres fork: column type metadata on simple query results | F-013, F-014 | 2 | none |
| W2-02 | rust-postgres fork: transaction status from ReadyForQuery | F-013 | 2 | W2-01 |
| W2-03 | rust-postgres fork: row-limited unnamed text portal and COPY handling | F-012, F-013, F-014 | 2 | W2-02 |
| W2-04 | tiberius fork: protocol errors instead of panics, full PRELOGIN encryption matrix | F-008, F-015 | 2 | none |
| W2-05 | tiberius fork: decode sql_variant and CLR UDT columns | F-015 | 2 | W2-04 |
| W2-06 | tiberius fork: opt-in exact MONEY decoding | F-015 | 2 | W2-04 |
| W2-07 | tiberius fork: phase-aware request cancellation (Attention or ignore bit) | F-012, F-041 | 2 | W2-04 |
| W2-08 | tiberius fork: inject a rustls ClientConfig | F-008, F-047, F-048 | 2 | W2-04 |
| W2-09 | Core endpoint, TLS, liveness, transport and trust types | F-008, F-032, F-041, F-047, F-048, F-049 | 4 | none |
| W2-10 | tablepro-net: direct TCP, private socket relay, trust store and TLS classification | F-008, F-041, F-047, F-048, F-049 | 8 | W2-01, W2-02, W2-03, W2-09, W8-10 |
| W2-11 | Core driver contract v2: Connection, DriverError, EditorSession, writes, metadata, OwnedCalls and WriteLedger | F-001, F-012, F-013, F-041, F-055, F-057, F-058, F-116 | 30 | W2-09, W2-10, W3-05, W4-01 |
| W2-12 | PostgreSQL driver on tokio-postgres: pooler-safe flights, psql-model editor sessions, phase-aware writes, metadata and decode | F-001, F-008, F-012, F-013, F-014, F-041, F-047, F-048, F-049, F-055, F-057, F-058, F-116 | 30 | W2-10, W2-11, W3-06 |
| W2-13 | MySQL and MariaDB driver: relay transport, server-default session, KILL QUERY, engine-aware writes, raw editor protocol | F-001, F-008, F-012, F-013, F-014, F-041, F-047, F-048, F-049, F-055, F-056, F-057, F-058, F-116 | 30 | W2-10, W2-11, W3-06 |
| W2-14 | SQLite driver: explicit open, atomic create-or-replace, one workspace connection, progress-handler cancel, exact transaction state | F-001, F-012, F-013, F-032, F-055, F-057, F-058, F-109, F-116, F-134 | 30 | W2-11, W3-06 |
| W2-15 | SQL Server driver on the tiberius fork: pools, in-band attention cancel, read-only transaction guard, routing, Kerberos off-worker, typed TLS failures, exact decode | F-001, F-008, F-012, F-013, F-014, F-015, F-041, F-047, F-048, F-049, F-055, F-057, F-058, F-116 | 30 | W2-04, W2-05, W2-06, W2-07, W2-08, W2-10, W2-11, W3-06, W8-10, W8-11 |
| W2-16 | ClickHouse driver over our transport: typed cells, probe-first unkillable writes, query_log and mutations resolution, KILL QUERY for reads | F-001, F-008, F-012, F-013, F-017, F-041, F-047, F-048, F-049, F-055, F-057, F-058, F-116 | 30 | W2-10, W2-11, W3-01, W3-06 |
| W2-17 | App surfaces for contract v2: Security group, SQLite file rows, read-only subtitles, categorised driver errors | F-001, F-008, F-032, F-047, F-049, F-116 | 30 | W2-11, W2-12, W2-13, W2-14, W2-15, W2-16, W4-04, W4-06, W6-11, W6-13 |
| W2-18 | SQLite file location: network, FUSE and portal detection, Locate… recovery | F-032, F-134 | 42 | W2-14, W2-17, W4-04, W4-06, W4-13, W4-14, W6-13 |
| W2-19 | Document driver contract v2, transports, trust, pooler requirements and per-engine behaviour | F-001, F-008, F-012, F-013, F-041, F-047, F-058, F-109 | 31 | W2-12, W2-13, W2-14, W2-15, W2-16, W2-17 |

### W3 · Core domain, SQL generation and DDL

| Task | Title | Findings | Step | Depends on |
|---|---|---|---|---|
| W3-01 | Escape backslashes in ClickHouse quoted identifiers | F-018 | 1 | none |
| W3-02 | Neutralise only textual CSV cells | F-023 | 1 | none |
| W3-03 | Add lossless value component types | F-006, F-052 | 6 | none |
| W3-04 | Add column type, SQL syntax and referential action types | F-021, F-054, F-117 | 22 | W3-03, W4-03, W8-10 |
| W3-05 | Replace Value, column metadata and statement types with the lossless model (contract switch, core model) | F-006, F-052, F-054 | 30 | W3-03, W3-04, W4-01 |
| W3-06 | SqlDialect trait, row-identity keys and dialect-driven core SQL builders (contract switch) | F-006, F-018, F-022, F-054 | 30 | W2-11, W3-05, W3-19 |
| W3-07 | Per-engine SqlDialect implementations (contract switch) | F-006, F-018, F-022, F-053, F-054 | 30 | W2-12, W3-06, W8-10 |
| W3-08 | Classify columns and defaults from each engine's structured catalog (contract switch) | F-006, F-021, F-054 | 30 | W2-11, W2-12, W3-04, W3-05, W3-06 |
| W3-18 | Table definitions with column attributes, inbound foreign keys and SQLite dependents (contract switch) | F-020, F-045, F-050, F-051 | 30 | W2-11, W3-05, W3-08, W4-01 |
| W3-19 | Foreign-key suspension in WriteBatch, SQLite write transactions and MySQL workspace sql_mode (contract switch) | F-020, F-051, F-053 | 30 | W2-11, W3-05 |
| W3-09 | Decode and encode PostgreSQL, MySQL and SQLite values losslessly (contract switch) | F-006 | 30 | W2-12, W3-05, W3-06, W3-08, W8-12 |
| W3-10 | Structure DDL on table definitions, typed defaults, structural validation and a static SQL Server default drop (contract switch) | F-021, F-050, F-117 | 30 | W3-07, W3-08, W3-18, W4-06 |
| W3-11 | Rewrite app SQL generation, row keys and copied SQL on dialects and column kinds (contract switch) | F-006, F-022, F-053, F-054 | 30 | W2-11, W3-06, W3-07, W3-09, W3-18, W4-06 |
| W3-12 | Generate DDL through per-engine DdlDialect plans against fetched table definitions | F-021, F-045, F-050, F-054, F-117 | 35 | W3-10, W3-11, W3-18, W4-06, W4-07, W4-10 |
| W3-13 | Preserve every column attribute when MySQL, PostgreSQL and SQL Server redefine a column | F-020 | 36 | W3-12, W3-18, W3-19 |
| W3-14 | Rename columns, change primary keys and toggle auto-increment in the structure editor | F-045 | 38 | W3-13 |
| W3-15 | Drop and re-add SQL Server default constraints around column type changes | F-050 | 39 | W3-14 |
| W3-16 | Create SQLite foreign keys inline and rebuild SQLite tables for structure changes | F-045, F-051 | 40 | W3-15, W3-18, W3-19, W9-09 |
| W3-17 | Export values at column precision with exact JSON numbers | F-023, F-052 | 32 | W3-11 |

### W4 · Application model, sessions, async and lifecycle

| Task | Title | Findings | Step | Depends on |
|---|---|---|---|---|
| W4-01 | Library/binary split and crates/test-support | F-068, F-072 | 5 | W8-02 |
| W4-02 | Route structure save completion by StructureMode and persist Edit-mode Structure tabs | F-019 | 8 | W4-01 |
| W4-03 | Panic boundary and non-panicking delivery for every background command | F-016 | 19 | W4-01, W6-02, W8-21, W9-05 |
| W4-04 | Injected TaskSpawner, sized relm4 runtime, HistoryService, off-thread config writes | F-071 | 25 | W1-05, W4-03, W6-02 |
| W4-05 | Pure session primitives: health policy, mailbox, attempts, keys | F-044, F-072, F-073 | 26 | W4-04 |
| W4-06 | App part of the driver contract v2 switch: generation-leased Sessions replace DatabaseService | F-002, F-016, F-044, F-072, F-076, F-077, F-078 | 30 | W1-03, W1-07, W1-13, W2-11, W2-12, W2-13, W2-14, W2-15, W2-16, W3-05, W3-06, W4-05, W6-11, W6-12, W6-13 |
| W4-07 | Per-workspace tracker registries with borrow-safe handles | F-076 | 31 | W4-06 |
| W4-08 | Undo restores the prior pending value; saves follow edit order deterministically | F-074 | 33 | W3-06, W4-07 |
| W4-09 | Break reference cycles in tab view, grid, filter strip, editor and structure tab | F-075 | 33 | W4-07 |
| W4-10 | Tabs own sequenced, cancellable fetches that recover after reconnect; shared SchemaCatalog | F-002, F-040, F-072, F-133 | 34 | W1-09, W3-06, W3-11, W3-17, W4-07, W4-08 |
| W4-11 | Per-session WorkspaceStore with off-thread writer; editor changes carry no text; dropped files load asynchronously | F-002, F-019, F-070 | 36 | W1-05, W1-09, W1-10, W4-02, W4-10 |
| W4-12 | SaveLedger with stoppable saves, event-driven CloseGuard, unknown save outcomes, WindowInhibitor | F-016, F-019, F-036, F-067, F-073, F-110 | 37 | W3-06, W4-08, W4-11, W6-12 |
| W4-13 | TableProApplication subclass: D-Bus uniqueness, app actions, New Window, QuitSequence, query-end | F-036, F-068, F-071, F-110 | 40 | W1-05, W4-12, W8-14, W8-16, W8-19, W8-21, W9-05 |
| W4-14 | SessionWindow per connection session with picker, connecting, failed and workspace pages | F-002, F-040, F-044, F-075, F-076, F-077, F-078 | 41 | W1-05, W4-13, W6-12, W8-14, W8-19 |
| W4-15 | Per-session reachability and resume-from-suspend signals | F-072, F-073 | 42 | W4-05, W4-14 |
| W4-17 | Record open session windows and reopen them on launch | F-044, F-076 | 43 | W1-05, W4-11, W4-13, W4-14, W8-18 |
| W4-16 | Document the application, session and window-per-session architecture | F-002, F-068, F-071, F-076 | 44 | W4-15, W4-17 |

### W5 · Data grid and browse tab

| Task | Title | Findings | Step | Depends on |
|---|---|---|---|---|
| W5-01 | Move the data grid into a ui/grid module | F-004 | 35 | W1-09, W3-11, W3-17, W4-07, W4-09, W4-10, W6-12 |
| W5-02 | Resolve grid cell events to row objects through the column view cell | F-004 | 38 | W2-11, W3-05, W3-17, W4-01, W4-06, W4-07, W5-01 |
| W5-03 | Notify bound cells of tracked row changes instead of swapping row objects | F-086 | 39 | W4-07, W5-02 |
| W5-04 | Remove discarded drafts from the grid and make Delete act on the menu's row set | F-026 | 41 | W4-07, W5-03 |
| W5-06 | Edit grid cells from lossless edit text with exact editors | F-005, F-024, F-025 | 42 | W3-06, W3-11, W4-07, W5-03, W8-16 |
| W5-07 | Make grid cells keyboard focusable with native cell navigation and keyboard menus | F-004, F-025 | 43 | W4-13, W4-14, W5-06, W8-14, W8-15 |
| W5-08 | Render grid cells from borrowed display text with stock data-table styling | F-103, F-126 | 44 | W5-07, W8-14, W8-15, W8-16, W8-20 |
| W5-09 | Keep one owner per browse page, key rows on every identity column, and replace pages with a single splice | F-004, F-103 | 45 | W2-11, W3-05, W3-06, W4-10, W5-08 |
| W5-10 | Refresh browse tabs in place and keep the last good page when a reload fails | F-102 | 46 | W2-11, W4-01, W4-06, W4-10, W4-13, W4-14, W5-09 |
| W5-11 | Keep loaded structure on screen when a structure refresh fails and refetch columns after schema saves | F-102 | 47 | W4-06, W4-10, W4-12, W5-10 |
| W5-12 | Fail browse tabs visibly when columns cannot be loaded and refetch columns on refresh | F-100 | 47 | W4-01, W4-06, W4-10, W5-09, W5-10 |
| W5-13 | Show row count estimates and count exact totals on demand | F-042 | 48 | W2-11, W2-15, W3-06, W4-01, W4-06, W4-10, W4-12, W5-10, W5-12 |
| W5-14 | Streaming row encoders for CSV, TSV, JSON and Markdown | F-104, F-138 | 46 | W2-16, W3-05, W3-17, W4-03 |
| W5-15 | Stream exports to disk off the GTK thread with progress and cancel | F-104 | 47 | W2-11, W4-04, W4-12, W4-13, W4-14, W5-09, W5-14 |
| W5-16 | Export whole tables and complete query results from the export dialog | F-043, F-104 | 49 | W2-11, W2-12, W2-13, W2-14, W2-15, W2-16, W3-06, W4-06, W5-13, W5-15 |
| W5-17 | Show editor result row limits with a banner and offer Export All | F-043 | 50 | W2-11, W4-01, W5-16, W6-12 |
| W5-18 | Sort editor result grids by column header | F-127 | 51 | W5-02, W5-08, W5-17 |
| W5-19 | Copy grid data with format-specific clipboard types rendered off the GTK thread | F-104, F-138 | 50 | W3-17, W4-04, W4-14, W5-09, W5-14 |

### W6 · SQL editor, history and dialogs

| Task | Title | Findings | Step | Depends on |
|---|---|---|---|---|
| W6-01 | Drop the dead confirmation preference and read page size when each tab opens | F-096 | 16 | W8-19 |
| W6-02 | Split the SQL editor into a module directory | enabling | 18 | W8-20 |
| W6-03 | Route every markup-parsing widget property through one plain-text boundary | F-027 | 20 | W4-03, W6-02 |
| W6-04 | Replace editor text undoably and load dropped files asynchronously | F-028 | 23 | W6-03 |
| W6-05 | Add a data-driven SQL script lexer and planner to core | F-030 | 5 | W8-02 |
| W6-06 | Declare each engine's script syntax and completion keywords | F-030, F-090 | 6 | W6-05 |
| W6-07 | Revalidate the connect form when any SSH row changes | F-031 | 24 | W6-03 |
| W6-08 | Make Enter submit every form dialog | F-098 | 25 | W6-07 |
| W6-09 | Open the connect dialog with the remembered driver's defaults and surface keyring failures | F-097 | 26 | W1-07, W6-08, W8-18, W8-19 |
| W6-10 | Apply history retention on the scheduled prune and clear history through the service | F-096 | 29 | W1-05, W4-04, W6-03 |
| W6-11 | Map driver, connect and operation errors by ErrorCategory | enabling | 30 | W2-11, W6-05, W6-09 |
| W6-12 | Run editor SQL through a tab-owned EditorSession, one statement or batch per run, with a results list | F-029, F-030, F-092 | 30 | W2-11, W4-04, W6-04, W6-06, W6-10, W6-11 |
| W6-13 | Rebuild the connect dialog on ConnectRequest v2 with Security, SQLite file and SSH agent rows | F-031, F-097, F-098 | 30 | W1-03, W1-04, W1-07, W1-13, W2-11, W6-09, W6-11, W6-12 |
| W6-14 | Format only statements whose tokens survive sqlformat | F-028 | 31 | W6-12 |
| W6-15 | Present ScriptPlan statement boundaries through a shared editor cursor helper | F-029 | 32 | W6-12 |
| W6-16 | Add find and replace to the SQL editor | F-089 | 53 | W4-14, W6-12, W7-02, W7-03 |
| W6-17 | Complete tables, columns and keywords from the schema catalog | F-090 | 39 | W3-06, W4-06, W4-10, W6-06, W6-12 |
| W6-18 | Search history by substring and page it in a GtkListView | F-027, F-093 | 48 | W1-05, W1-08, W4-14, W5-15, W6-10 |
| W6-19 | Filter history by connections that have history and undo deletions | F-093, F-135 | 49 | W4-14, W6-18 |
| W6-20 | Bind structure lists to list models and drop the idle suppression flag | F-128 | 41 | W3-12, W3-16, W4-07, W4-10 |
| W6-21 | Review destructive schema changes before applying them | F-094 | 42 | W2-11, W3-12, W4-12, W4-14, W6-20 |
| W6-22 | Validate Add Index and Add Foreign Key live with catalog pickers | F-095, F-098 | 43 | W2-11, W3-06, W3-12, W4-06, W6-08, W6-20 |
| W6-23 | Document editor scripts, results, history search and structure review | enabling | 52 | W6-12, W6-17, W6-19, W6-21 |

### W7 · Window shell, navigation, actions and HIG

| Task | Title | Findings | Step | Depends on |
|---|---|---|---|---|
| W7-01 | Keep Ctrl+Home/End and Ctrl+Shift+Home/End for widgets inside the workspace tab view | F-034 | 42 | W4-14, W9-05 |
| W7-02 | Route every keyboard shortcut through one accelerator table and keep the shortcuts dialog in sync with it | F-080, F-081 | 51 | W4-10, W4-13, W4-14, W5-01, W5-07, W6-02, W6-12, W8-14, W8-16, W8-20, W9-05 |
| W7-03 | Split header bars per pane, tab overview at the window root, adaptive tab bar, sidebar toggle and window size floor | F-035, F-079, F-082 | 52 | W4-14, W5-07, W5-15, W7-02, W8-14, W8-15 |
| W7-04 | Recycling GtkListView table sidebar with schema sections, filter and shared context menu | F-085 | 53 | W2-11, W3-06, W3-12, W4-06, W4-10, W5-10, W7-02, W7-03 |
| W7-05 | Picker rows on a shared model that follows the connection store, with one delete confirmation | F-083 | 54 | W1-06, W1-15, W2-18, W4-14, W7-02, W7-03 |
| W7-06 | Edit, rename, duplicate and group saved connections | F-101 | 56 | W1-06, W1-07, W1-12, W6-11, W6-13, W7-05 |
| W7-07 | Connecting and connection-failed pages with a spinner paintable, announcements and Edit Connection | F-084 | 57 | W1-12, W4-14, W6-11, W7-03, W7-06 |
| W7-08 | Resolve tab and window titles in one place, mark unsaved tabs with the page icon, restore the active tab by persisted index | F-105 | 55 | W4-02, W4-10, W4-11, W4-12, W4-14, W6-02, W7-03 |
| W7-09 | Show pending state without colour and give icon buttons translated accessible labels | F-088 | 54 | W1-09, W4-10, W5-01, W5-03, W5-06, W5-07, W5-08, W6-18, W7-02, W8-20, W9-05 |
| W7-10 | Desktop notification when a query, save or export finishes in an inactive tab | F-129 | 58 | W4-12, W4-13, W4-14, W5-15, W6-12, W7-08 |
| W7-11 | Reveal the history database in Files instead of opening its folder | F-131 | 55 | W1-05, W4-13, W6-10, W6-18, W6-19, W8-18 |
| W7-12 | Build the About dialog from the embedded metainfo | F-137 | 52 | W4-13, W8-14, W8-15 |
| W7-14 | Replace the history filter popover of combo rows with drop-downs and a toggle group | F-125 | 52 | W6-18, W6-19, W7-02 |
| W7-13 | GNOME header and sentence capitalisation for UI strings, checked in CI | F-125 | 59 | W5-07, W5-08, W5-15, W5-19, W6-12, W6-16, W6-18, W6-19, W6-22, W7-02, W7-03, W7-04, W7-05, W7-06, W7-07, W7-08, W7-09, W7-10, W7-11, W7-12, W7-14, W8-15, W8-20 |

### W8 · Platform, build, packaging, i18n, dependencies and CI

| Task | Title | Findings | Step | Depends on |
|---|---|---|---|---|
| W8-01 | Remove unused and misplaced dependencies and refresh the lockfile | F-113, F-114 | 1 | none |
| W8-02 | Rust 1.98, workspace lint denies, license inheritance, typed startup error, CI container ubuntu:26.04 | F-060, F-132 | 3 | W8-01 |
| W8-03 | Migrate to gettext-rs 0.8 with an explicit single-threaded init contract | F-114 | 4 | W8-02 |
| W8-04 | russh 0.63.3 with an injected HostKeyVerifier | F-046 | 6 | W2-09, W8-02 |
| W8-05 | tiberius fork: server-reachable panics become protocol errors | F-046 | 2 | W2-04 |
| W8-06 | tiberius fork: sql_variant and UDT decoding | F-046 | 2 | W2-05, W8-05 |
| W8-07 | tiberius fork: opt-in exact MONEY decoding | F-046 | 2 | W2-06, W8-06 |
| W8-08 | tiberius fork: Client::cancel_pending via TDS attention | F-046 | 2 | W2-07, W8-07 |
| W8-09 | tiberius fork: inject a rustls ClientConfig | F-046, F-111 | 2 | W2-08, W8-08 |
| W8-10 | Pin the tiberius fork, use aws-lc-rs as the only crypto provider, add deny.toml | F-046, F-111 | 7 | W8-04, W8-09, W9-02 |
| W8-11 | SQL Server Kerberos behind a kerberos cargo feature | F-112 | 8 | W8-10, W9-03 |
| W8-12 | sqlx 0.9 with aws-lc-rs, system SQLite and mysql-rsa | F-111, F-114 | 9 | W8-10, W8-11 |
| W8-13 | App ID app.tablepro.TablePro and binary tablepro | F-037 | 10 | W8-12 |
| W8-14 | Build-support crate, generated config.rs and embedded GResource with style.css | F-037, F-087, F-091, F-099 | 11 | W4-01, W8-13 |
| W8-15 | Meson layer, data templates, icons, GNOME 50 Devel Flatpak and meson in CI | F-007, F-033, F-038, F-060, F-087, F-099, F-112, F-123, F-124 | 12 | W8-14, W9-03, W9-04 |
| W8-16 | Raise the API floor to GNOME 50 and replace deprecated GTK APIs | F-060, F-108 | 13 | W8-15 |
| W8-17 | Replace removed emblem icons | F-039 | 14 | W8-16 |
| W8-18 | GSettings schema and the storage AppSettings wrapper | F-064 | 15 | W8-17 |
| W8-19 | Move preferences, window geometry and the editor font and style scheme to GSettings | F-064, F-091 | 16 | W8-18 |
| W8-20 | Gettext functions with plural, context and named placeholders, with a real-locale catalog test | F-087 | 17 | W8-19 |
| W8-21 | Journald logging with RUST_LOG and G_MESSAGES_DEBUG, and the process panic hook | F-130 | 18 | W8-20 |
| W8-22 | Open SQLite files from Files and the command line | F-069, F-123 | 43 | W4-13, W4-14, W8-21 |
| W8-23 | Ship third-party license notices | F-115 | 53 | W7-12, W8-22 |
| W8-24 | Rendered Flathub manifest, lint exceptions, screenshots and branding | F-007, F-033, F-038 | 60 | W1-04, W1-13, W7-13, W8-23 |
| W8-25 | Recommend Ed25519 or ssh-agent for RSA identity files | F-046 | 61 | W1-04, W1-12, W1-13, W6-13, W8-24 |
| W8-26 | CI: meson, release-shaped Flatpak, supply chain, i18n drift and all driver suites | F-007, F-046, F-060, F-087, F-111, F-112, F-113, F-132 | 62 | W8-25 |
| W8-27 | Identical Linux workflow on main so the weekly schedule fires | F-060 | 65 | W8-26 |
| W8-28 | .deb for Ubuntu 26.04 and .rpm for Fedora 44 from meson install, release workflow | F-099, F-136 | 63 | W8-26 |

### W9 · Test infrastructure, code structure and documentation

| Task | Title | Findings | Step | Depends on |
|---|---|---|---|---|
| W9-01 | SQLite driver integration suite | F-059 | 4 | W8-02 |
| W9-02 | Container fixture crate with test PKI, per-engine key placement and an OpenSSH forwarding drop-in | F-059 | 4 | W8-02 |
| W9-03 | Integration matrix generated from docker-ignored test targets, ignore-reason rule and CI jobs | F-059, F-107 | 5 | W9-01, W9-02 |
| W9-04 | Documentation reference gate | F-107 | 6 | W9-03 |
| W9-05 | GTK test harness crate with a verified accessibility audit, and headless GTK CI | F-059 | 7 | W4-01, W9-03 |
| W9-06 | Storage isolation tests across two storage roots | F-059 | 25 | W1-05, W1-06, W1-08 |
| W9-07 | Connection v2 conformance module and suite, shipped in the contract switch | F-059 | 30 | W2-11, W2-12, W2-13, W2-14, W2-15, W2-16, W4-01, W9-02, W9-03 |
| W9-08 | TLS conformance suite, shipped in the contract switch | F-059 | 30 | W2-10, W2-12, W2-13, W2-15, W2-16, W9-02, W9-07 |
| W9-09 | DDL execution conformance suite, shipped in the DdlDialect commit | F-059 | 35 | W3-10, W3-12, W9-07 |
| W9-10 | Split the browse tab update into per-domain inputs, handlers, layout builders and child components | F-106 | 60 | W3-17, W4-10, W4-12, W5-04, W5-09, W5-10, W5-12, W5-13, W5-16, W5-19, W7-02, W7-09, W7-13, W9-05 |
| W9-11 | Split the structure tab update and init into per-domain inputs, handlers and page builders | F-106 | 61 | W3-10, W3-12, W3-14, W3-16, W4-02, W4-09, W4-10, W4-12, W5-11, W6-20, W6-21, W6-22, W7-09, W7-13, W8-17, W9-05 |
| W9-12 | Turn the filter strip into a component with factory rule rows | F-106 | 61 | W3-11, W4-09, W5-08, W7-02, W7-09, W7-13, W8-20, W9-05, W9-10 |
| W9-13 | Build each preferences page in its own module | F-106 | 60 | W1-16, W4-17, W6-01, W6-02, W6-10, W7-11, W7-13, W8-18, W8-19, W9-05 |
| W9-14 | Application accessibility smoke tests across session window pages and dialogs | F-059 | 62 | W1-12, W1-15, W2-17, W2-18, W4-13, W4-14, W5-16, W5-17, W6-11, W6-13, W6-16, W6-19, W6-22, W7-03, W7-04, W7-05, W7-06, W7-07, W7-09, W7-13, W7-14, W8-18, W9-05, W9-11, W9-13 |
| W9-15 | Deny clippy too_many_lines and cap Rust production files at 800 lines | F-106 | 63 | W1-03, W1-14, W3-01, W3-02, W4-15, W5-18, W6-01, W6-14, W6-15, W6-17, W7-01, W8-03, W8-22, W8-23, W8-25, W9-10, W9-11, W9-12, W9-13, W9-14 |
| W9-16 | Critical-finding regression map with a checker | F-059 | 64 | W1-06, W2-12, W2-13, W2-14, W2-16, W3-09, W4-06, W4-12, W4-14, W5-02, W5-04, W5-06, W5-18, W7-01, W8-26, W8-28, W9-04, W9-07, W9-14 |
| W9-17 | Rewrite the roadmap from the code and index every guide | F-107 | 65 | W1-16, W2-19, W4-16, W4-17, W6-21, W7-13, W8-28, W9-04, W9-16 |
| W9-18 | Reconcile README and CONTRIBUTING with the code and add ADRs 0014 and 0015 | F-107 | 66 | W1-01, W2-19, W3-12, W4-16, W8-15, W8-16, W8-26, W8-28, W9-15, W9-17 |

## Cross-workstream conflicts and resolutions

- **W2-04..W2-08, W8-05..W8-09**: Two plans for the same five tiberius fork commits. Resolution: One series, commits (a) to (e), each pair a single commit (step 2). W2's scope governs: the full PRELOGIN matrix, phase-aware attention, tests. W8's extra touched files are included (token_feature_ext_ack.rs, sql_read_bytes.rs, header.rs, tls.rs, row.rs). W8-10 pins the head, and W2 tasks never re-pin.
- **W1-02, W8-04**: Both create host_key_verifier.rs, host_key_decision.rs, known_hosts_verifier.rs and known_hosts_store.rs and bump russh. Resolution: Same PR (step 6). W1-02 owns all crates/ssh code. W8-04 is limited to the workspace russh 0.63.3 pin, the lockfile and the RUSTSEC check. W1-03 ships in the same PR.
- **W1-04, W8-25**: Both create crates/ssh/src/identity.rs. Resolution: W1-04 creates it. W8-25 extends it, adds identity_algorithm.rs, and places the RSA hint as a separate warning adw::ActionRow in the ssh section W6-13 rebuilt.
- **W8-10, W2-10**: Both create deny.toml. Resolution: W8-10 creates it (step 7). W2-10 appends TableProApp/rust-postgres to [sources] allow-git (step 8).
- **FA 2 / W4-01, W4-03, W6-03, W3-04, W8**: crates/app/clippy.toml is claimed by FA 2 (with msrv) and by W4-03 as new. W8 forbids msrv in any clippy.toml, and W6-03 depends on 'FA 2 clippy.toml'. Resolution: W4-03 creates it with no msrv, repeating the five allow-*-in-tests keys. W6-03 and W3-04 land after W4-03.
- **W1-05, W4-13**: Both delete services/single_instance.rs. Deleting it in W1-05 drops the flock that guards workspace_state.json for 19 steps before GApplication uniqueness exists. Resolution: W1-05 keeps the flock and resolves its path through glib::user_runtime_dir(). W4-13 deletes the file and libc once uniqueness and W4-11's write-blocking are in place.
- **W1-05, W8-19**: W1-05 edits services/preferences.rs and window_state.rs, which W8-19 deletes. Resolution: W8-19 (step 16) lands before W1-05 (step 21), and W1-05 drops both files from its scope.
- **W1-09, W4-04, W4-11**: Three claims on coalescing writers: W1-09 and W4-11 both create workspace/persist_debouncer.rs, W4-04 creates LatestWinsWriter, and A8 says FA 4 must not touch column_widths.rs or filter_settings.rs, yet W1-09 depends on W4-04. Resolution: W4-04 creates runtime/latest_wins_writer.rs and converts column_widths.rs and filter_settings.rs to the spawner, which its relm4::spawn ban requires. W1-09 deletes both files, creates workspace/mod.rs and persist_debouncer.rs, and writes through LatestWinsWriter. W4-11 edits persist_debouncer.rs rather than creating it.
- **W6-04, W4-11**: Both implement asynchronous loading of dropped editor files (W4-11 adds ui/editor_file_drop.rs). Resolution: W6-04 owns it with gio::File::load_contents_future on the main context. W4-11 drops editor_file_drop.rs.
- **W1-07, W6-09, W4-06, W6-13**: SecretKind is defined twice (storage secrets/secret_kind.rs and app services/secret_kind.rs), and PendingSave twice (session/pending_save.rs and services/pending_save.rs). Resolution: The only SecretKind is tablepro_storage::secrets::SecretKind; W6-09 imports it and lands after W1-07. The only PendingSave is crates/app/src/session/pending_save.rs, with W6-13's API (store_connection, store_secrets -> KeyringOutcome). W4-06's secret_writes and connection_writes are its internals.
- **W2-17, W6-13, W6-11**: Both create connect_dialog/tls_section.rs and sqlite_file_row.rs, and both rewrite error_text categories. Resolution: W6-13 owns the connect_dialog module, tls_section.rs and sqlite_file_row.rs. W2-17 is narrowed to read_only_row.rs, pem_validation.rs (calling tablepro_net::tls::inspect_ca_file and inspect_client_identity) and error_text/tls_remedy.rs. W6-11 owns the ErrorCategory mapping and calls tls_remedy. All three are in step 30.
- **W1-11, W1-14, W4-06**: The monitor file is named session/monitor.rs in W1 and session/health_monitor.rs in W4. W1-11 also edits connect_services.rs and keyring_credentials.rs, which W4-06 creates with a different shape or not at all. Resolution: The name is health_monitor.rs. In the switch, W4-06 creates session/connect_services.rs with A3's ConnectServices { trust, environment, ssh, liveness } and keyring_credentials.rs with W1-11's KeyringCredentials { secrets, connection_id }. ReachabilityTarget for SSH comes from ssh_session.first_hop_endpoint().
- **W6-12, W5-17, W5-18**: There are two result panes (editor/results_pane.rs and ui/result_pane/). XW7 gives W5-17 ownership of the editor hand-off, yet W6-12 lands before it and needs a column-first grid with append_rows. Resolution: W6-12 owns the per-run list, renamed editor/results_list.rs, plus run_history.rs with row counts. In the switch it adds the columns-first result grid with append_rows to ui/grid.rs. W5-17's ui/result_pane/ is the per-result-set view mounted in editor/result_item.rs, and W5-17 edits result_item.rs and run_history.rs. W5-18 extracts grid/result_grid.rs.
- **W1-05, W1-08, W6-18, W6-19, W1-15**: The history module is storage/src/history/ in W1 but storage/src/query_history/ in W6. Schema versioning is sqlx embedded migrations in W1-08 but PRAGMA user_version in W6-18. Resolution: Use storage/src/history/. W6-18's search schema ships as a new file in crates/storage/migrations run by sqlx::migrate!. No user_version gating.
- **W8-16, W4-13, W7-02**: shortcuts-dialog.ui is claimed by W8-16 (creates), W7 (ships before W4-13) and W4-13 (replaces gtk::ShortcutsWindow). Resolution: W8-16 creates it with id shortcuts_dialog and removes build_shortcuts_window and win.shortcuts. AdwApplication auto-loads the resource and installs app.shortcuts. W4-13 depends on W8-16. W5-07, W7-02, W7-03 and W6-16 edit it in that order.
- **W4-13, W5**: app.new-window needs <Primary><Shift>n, which the grid's Set NULL binding (browse_tab.rs:1510) holds. No W5 task lands before W4-13 to move it. Resolution: W4-13 rebinds Set NULL to <Primary>BackSpace in browse_tab/mod.rs and the shortcuts dialog, and binds win.show-history to <Primary><Shift>h. W5-07 carries the Ctrl+BackSpace trigger in GridKeyboard, and W7-02 carries it as a Component(GridCell) entry.
- **W4-14, W5-15, W6-18**: Cycle: W4-14 waits for the export and history writes to leave the GTK thread before widening the std::fs ban, but W5-15 depends on W4-14. Resolution: W4-14 bans std::fs only under ui/workspace and ui/session_window. W5-15 moves export_dialog.rs:266 and history_dialog.rs:940 to ReplaceFileWriter and widens the ban to crates/app/src/ui. W6-18 lands after W5-15.
- **W5-15, W4-12, W4-13**: XW5's CloseBlocker seam is in no task's file list. Resolution: W4-12 adds workspace/close_blocker.rs (CloseBlocker, CloseBlockPrompt, Workspace::register_close_blocker), and CloseGuard consults it. W4-13's QuitSequence consults it too.
- **W5-06, W3-06, W3-11**: XW9 requires an FB 16 edit API (edit_text, parse_edit_text, empty_input_meaning, is_unchanged) and the browse_tab commit-path switch. No task provides them; W3-06 names parse_literal_text. Resolution: W3-06 provides those four functions in core edit/, with EditParseError not #[non_exhaustive]. W3-11 switches browse_tab to parse_edit_text and deletes parse_input_for_column, classify_type, TypeKind and parse_*_value. W5-06 depends on both.
- **W5-13, W5-16, W2-11..W2-16, W3-06, W4-06**: W5's later tasks need contract additions from inside the switch: stream_read (XW1), row-at-a-time decode (XW8), OperationKind::Export (XW2), build_export (XW3), PageLayout (XW13), COUNT_BIG (XW15). XW12 also reverses an edge so that W2's F-055 work waits on W5-13, a cycle. Resolution: All of these land in step 30. W2-11 adds Connection::stream_read with ReadStatement and StreamSummary. W2-12..W2-16 implement it with decode-as-rows-arrive, and W9-07 carries the 50,000-row bounded-buffer case. W4-06 adds OperationKind::Export. W3-06 adds build_export, PageSpec.layout, browse::paging_mode and COUNT_BIG for SQL Server. W2-15 decodes count_rows to u64. BrowsePager belongs to W5-13 alone, and no W2 task depends on it.
- **W7 (all tasks), W9-10..W9-13, W4-14**: W7 cites W9 ids from an older numbering and files that do not exist: ui/workspace/{shell,sidebar,tabs,tab_labels,persistence,window_actions}.rs, browse_tab/layout.rs, browse_tab/paginator/, filter_strip/*, grid/context_menu/menu_model.rs, grid/column_view.rs, preferences/general_page.rs, services/column_width_store.rs, sidebar_row/. The current W9 splits these modules after W7 (W9-10..W9-13 depend on W7), so W7 editing post-split paths creates cycles. Resolution: W4-14's move splits ui/app/mod.rs and workspace_tabs.rs by domain into ui/workspace/{mod,shell,sidebar,tabs,tab_labels,persistence,structure,row_ops,connection,status_pages}.rs. W7 tasks edit the pre-split paths: browse_tab/mod.rs, filter_strip.rs, grid/grid_menus.rs and context_menu.rs, grid/column_factory.rs and row_factory.rs, preferences.rs, persistence/column_width_store.rs, ui/sidebar_row.rs, session_window/window_actions.rs. W9-10..W9-13 split afterwards and carry that code.
- **W4-14, W7-03**: W4-14 builds a window-level ToastOverlay, and W7-03 then restructures it so AdwTabOverview becomes the window's direct child. Resolution: W4-14 sets each page root with adw::ApplicationWindow::set_content and a per-page adw::ToastOverlay from the start. Teardown step 5 sets the picker page as content. W7-03 does not restructure teardown.
- **W8-15, W7, W9**: W8 specifies GTK_A11Y=none for the gtk suite; W7 and W9 need an accessibility backend. Resolution: GTK_A11Y=test with GDK_BACKEND=x11 in W8-15's meson env, W9-05's CI job and W8-28's %check. In gtk-4-22 gtkatcontext.c, 'none' returns NULL and 'test' creates GtkTestATContext.
- **W1-01, W2-19, W3-12, W4-16, W8, FA-D13**: ADR numbers collide: 0005 claimed three times, 0010 claimed four times. Resolution: Use W9's table: 0005-0009 W8 (W8-10, W8-15, W8-18, W8-24, W8-28), 0010 W1-01, 0011 W3-12, 0012 W4-16, 0013 W2-19, 0014 and 0015 W9-18. W9-04's unique-number check enforces it.
- **W4-06, W6-19**: W4-06 needs history_dialog's connection source (database_service::instance().all_connections() at history_dialog.rs:113) in the switch, but F-135 lands in W6-19. Resolution: In step 30, W4-06 passes the ConnectionStore snapshot through HistoryDialogInit. W6-19 later replaces it with the connections that have history.
- **W1-16, W6-12, W4-17**: W1-16 edits ui/editor.rs and the gschema, but history recording moves to W6-12's editor/run_history.rs and W4-17 also edits the schema. Resolution: W1-16 edits editor/run_history.rs, lands after W4-17 (step 44), and extends the FakeDialect that W3-07 creates in test-support during the switch.
- **W4-17, W8-18, W7**: The restore-session key and the Preferences 'Restore Session' row are assigned to FD 12 and W7, but neither's task lists them. Resolution: W4-17 adds the key (b, default true), the AppSettings accessor, and an AdwSwitchRow bound through gio::Settings::bind in ui/preferences.rs. W9-13 splits preferences afterwards.
- **W1-11, W2-13, W2-14**: MySQL and SQLite disable_statement_logging are planned in both. Resolution: W1-11 owns the calls and their tests. W2-13 and W2-14 keep them when rewriting connect options in the same commit.
- **W2-12..W2-16, W3-01, W3-07..W3-11, W5-14, W9-03**: Several tasks edit drivers' tests/integration.rs, which the switch replaces with tests/integration/ trees, and some W2 tasks hand-list suites in build-linux.yml. Resolution: In step 30, W3's driver tests move into tests/integration/<topic>.rs. W5-14 edits clickhouse tests/integration/keys_and_decimals.rs. Suites are found by W9-03's generated matrix through #[ignore = "requires docker"], never listed by hand.
- **W9-16, definition of done**: W9-16 maps only critical findings; the plan must show a regression test for every finding. Resolution: W9-16's map covers F-001..F-138. check-regression-map.py fails on any unmapped id or missing test. Process and docs findings (F-059, F-060, F-107) map to their CI checks.
- **W5 coverage_gaps field**: W5 lists 15 findings as coverage gaps, but its tasks cover all of them. Resolution: Treat the field as empty. A set check confirms every one of the 138 findings is claimed by at least one task.

## Risks

- The step-30 switch is 23 tasks across every crate in one refactor(linux)! commit, so a hidden break blocks all later work and bisect. Mitigation: Build it on a stacked integration branch based on step 29, one reviewable commit per workstream portion, compiling only at the tip. Before squashing, the tip must pass clippy -D warnings, all unit and #[gtk::test] suites, the generated integration matrix (PostgreSQL plain and PgBouncer, MySQL 8.4, MariaDB 11.4, SQLite, SQL Server 2022, ClickHouse, TLS, ssh) and the W9-07/W9-08 conformance macros. Nothing else lands on linux while the branch is open, except rebases of steps 1-29.
- Data safety on developer machines. Storage moves to GLib dirs (W1-05), the connection list is rewritten (W1-06), secrets are relabelled and the schema literal renamed (W1-07, W8-13), history gains migrations (W1-08), preferences move to GSettings (W8-19), and workspace and drafts become per-session files (W1-10, W4-11). Any of these could lose or overwrite user data. Mitigation: Old files are never deleted, only read or moved aside. W1-06 and W4-11 refuse unreadable documents and move them aside behind a banner. W1-08's baseline migration uses CREATE TABLE IF NOT EXISTS and is tested against a fixture history.db from the pre-migration schema. A secret missing after the app-ID break goes to W1-12's prompt, never to a silent empty password. Every writer is atomic (temp file + fsync + rename) with 0600 mode, and tests assert the mode. W9-06 isolates two storage roots. The README states the clean break.
- Large mechanical rewrites of ui/app: W8-20 (549 tr! sites), W6-03 (22 files), W4-03, and W4-14's move plus split. These cause merge conflicts, lost behaviour and history churn. Mitigation: Each lands alone in its step. W4-14 performs moves at git similarity of 50% or more, so git log --follow works. The lifecycle #[gtk::test] cases (claim-and-present, disconnect close count, cycle WeakRef tests from W4-09) run before and after. The W9-10..W9-13 splits wait until the last functional edit to each file.
- Dependency upgrades: russh 0.55 to 0.63.3 (handler and auth API), sqlx 0.9 (AssertSqlSafe, system SQLite at least 3.37), gettext-rs 0.8 (unsafe setlocale), aws-lc-rs as the only provider (native build), GNOME 50 floor. Mitigation: Each upgrade is a separate step with its own tests: steps 6, 9, 4, 7 and 13. CI asserts cargo tree -e all -i ring is empty and that rustls@0.21.12 and openssl-sys are absent. cargo deny runs from step 7. The Flatpak Devel build on org.gnome.Platform//50 with rust-stable//25.08 and llvm22 runs from step 12. aws-lc-rs build dependencies (clang, cmake) are listed in CI and the manifest.
- Fork maintenance for TableProApp/tiberius and TableProApp/rust-postgres: drift from upstream, and security fixes missed. Mitigation: Rev pins in [patch.crates-io]. deny.toml [sources] allows only those two repos. Every fork commit links its upstream PR. The SQL Server attention and TLS matrix tests and the PgBouncer suites run weekly (W8-27 puts the workflow on main so the schedule fires).
- No single-instance guard when the D-Bus session bus is unavailable, after W4-13 removes the flock. Mitigation: Per-session workspace write-blocking lands in W4-11 before W4-13. application_uniqueness.rs runs against TestSessionBus. The flock stays until step 40.
- Security regression windows: host keys rejected with no dialog, markup injection, credentials recorded in history. Mitigation: W1-02, W8-04 and W1-03 share one PR (step 6). F-018 lands in step 1 and F-027 in step 20. Driver statement logging is disabled in the switch. W1-16's history classifier lands in step 44 with tests; history is still recorded up to that step.
- Flaky headless and docker suites (xvfb, gnome-keyring, containers, timing). Mitigation: Image digests pinned through test-fixtures. --test-threads=1 for integration. Tokio start_paused for session timing. GTK_A11Y=test, GDK_BACKEND=x11, GSETTINGS_BACKEND=memory and GSK_RENDERER=cairo in one meson env. The keyring is unlocked inside dbus-run-session. Only #[ignore = "requires docker"] is allowed as an ignore reason.
- Merge conflicts on shared manifests inside a step (Cargo.toml, Cargo.lock, build-linux.yml, docs indexes). Mitigation: Merge in the listed order, regenerating the lockfile minimally (cargo update -w). CI checks cargo metadata --locked. W8-26 rewrites the workflow once all suites exist.
- The plan text drifts from code: stale task ids, moved paths, renamed modules. Mitigation: W9-04's reference gate lands at step 6 and checks links, paths, package names and unique ADR numbers on every commit. Each task resolves its file list to the moved path at its landing step, using this plan's path table: main.rs startup code in lib.rs at step 5, editor/ at step 18, connections/ at step 22, secrets/ at step 23, history/ at step 21, connect_dialog/ at step 30, browse_tab/ at step 34, grid/ at step 35, ui/workspace at step 41, history_dialog/ at step 48.

## Definition of done

- [ ] check-regression-map.py passes: docs/regression-tests.md maps every F-001..F-138 to at least one named test or CI check, every named test exists, and each passes in CI.
- [ ] cargo fmt --check passes. cargo clippy --workspace --all-targets --all-features -- -D warnings passes with [workspace.lints] denying unwrap_used, expect_used, panic and too_many_lines. check-source-size.py (at most 800 production lines per file) and check-clippy-shared-keys.py pass.
- [ ] cargo test --workspace and meson test (gtk, data and build-aux unittest suites) pass under xvfb-run -a dbus-run-session with GTK_A11Y=test, GDK_BACKEND=x11, GSETTINGS_BACKEND=memory and GSK_RENDERER=cairo. This includes the harness=false tests: application_uniqueness, application_lifecycle, application_session_restore, accessibility, startup, panic_hook, open_files, desktop_entry, i18n_catalog.
- [ ] The integration matrix generated by build-aux/ci/integration_matrix.py is green for PostgreSQL (direct, and PgBouncer in transaction and session modes), MySQL 8.4, MariaDB 11.4, SQLite (system at least 3.37.0), SQL Server 2022 and ClickHouse. The Connection v2, TLS and DDL conformance macros are instantiated for every applicable engine. The ssh suites (two-hop openssh-server, ssh-agent, keyboard-interactive) and session_postgres and tracker_save_postgres pass.
- [ ] cargo deny check advisories bans licenses sources is clean, with sources limited to the pinned TableProApp/tiberius and TableProApp/rust-postgres revs. cargo tree -e all -i ring, cargo tree -i rustls@0.21.12 and cargo tree -i openssl-sys print nothing.
- [ ] cargo run -p tablepro starts from a clean checkout (cargo build driver, embedded GResource). meson setup, compile, test and install succeed for the default and development profiles. tablepro --help exits 0.
- [ ] The Devel manifest builds with flatpak-builder on org.gnome.Platform//50 (rust-stable//25.08, llvm22), and the rendered Flathub manifest builds. flatpak-builder-lint manifest and flatpak-builder-lint repo pass with only lint-exceptions.json entries. The sandbox smoke test passes: ssh -G alias, ssh-keygen -F, Secret portal or org.freedesktop.secrets fallback.
- [ ] These data checks pass: appstreamcli validate --no-net on the metainfo, desktop-file-validate on the desktop file, glib-compile-schemas --strict, check-metainfo-release.py, check-app-icons.py, check-icon-names.py, check-screenshots.py, check-hig-capitalization.py, check-doc-references.py and check-protected-msgids.py. The i18n drift job regenerates po/tablepro.pot with no diff.
- [ ] The .deb (ubuntu:26.04) and .rpm (fedora:44) build from meson install, install cleanly with Depends/Requires openssh-client >= 9.6p1 and libsqlite3 >= 3.37.0, and launch tablepro --help. release-linux.yml dry-run succeeds.
- [ ] build-linux.yml is byte-identical on main and linux, and the weekly schedule run is green.
- [ ] Docs are complete: ARCHITECTURE.md, docs/* and ROADMAP.md match the code under the reference gate. ADRs 0005-0015 are present and indexed with unique numbers.
- [ ] Manual GNOME HIG check, window and navigation: at the 360x294 floor the AdwBreakpoint collapses the sidebar, AdwTabBar adapts and AdwTabOverview opens. Split header bars put window controls only on the outer panes, as in GNOME Files.
- [ ] Manual HIG check, keyboard only: picker, sidebar, grid (F2, Menu and Shift+F10, Ctrl+BackSpace), editor (Ctrl+F find, Ctrl+H replace), and dialogs (Enter submits, Escape cancels) all work. The shortcuts dialog (Ctrl+?) lists every entry in ACCELERATORS.
- [ ] Manual HIG check, accessibility: Orca announces every icon-only button, entry-row suffix, pending-state marker and connecting page. Pending state stays distinguishable in High Contrast and in the dark style. The GtkSourceView scheme follows AdwStyleManager. Layout holds at 1.5x text scaling and under an RTL locale.
- [ ] Manual HIG check, lifecycle: closing and quitting with unsaved edits, an in-flight save or a running export shows AdwAlertDialog with Cancel and a destructive action. Logout is inhibited while saves run. Suspend/resume and network loss show the health banner, and reconnect replays reads only.
- [ ] Manual HIG check, platform integration: Open With TablePro from Files opens a .sqlite in a new or existing window. A second launch presents the primary instance, and app.new-window opens a picker. The unknown or changed SSH host-key dialog shows the SHA256 fingerprint. A GNotification appears only for work that finishes in an unfocused window or inactive tab. About comes from the metainfo with legal sections. Show in Files reveals the history database.

## Finding to task index

| Finding | Owner | Tasks |
|---|---|---|
| F-001 | W2 | W2-11, W2-12, W2-13, W2-14, W2-15, W2-16, W2-17, W2-19 |
| F-002 | W4 | W4-06, W4-10, W4-11, W4-14, W4-16 |
| F-003 | W1 | W1-05, W1-06 |
| F-004 | W5 | W5-01, W5-02, W5-07, W5-09 |
| F-005 | W5 | W5-06, W5-08 |
| F-006 | W3 | W3-03, W3-05, W3-06, W3-07, W3-08, W3-09, W3-11 |
| F-007 | W8 | W8-15, W8-24, W8-26 |
| F-008 | W2 | W2-04, W2-08, W2-09, W2-10, W2-12, W2-13, W2-15, W2-16, W2-17, W2-19 |
| F-009 | W1 | W1-01, W1-02, W1-03, W1-11, W1-13, W1-14 |
| F-010 | W1 | W1-07, W1-11, W1-12 |
| F-011 | W1 | W1-06, W1-09, W1-10 |
| F-012 | W2 | W2-01, W2-02, W2-03, W2-07, W2-11, W2-12, W2-13, W2-14, W2-15, W2-16, W2-19 |
| F-013 | W2 | W2-01, W2-02, W2-03, W2-11, W2-12, W2-13, W2-14, W2-15, W2-16, W2-19 |
| F-014 | W2 | W2-01, W2-03, W2-12, W2-13, W2-15 |
| F-015 | W2 | W2-04, W2-05, W2-06, W2-15 |
| F-016 | W4 | W4-03, W4-04, W4-06, W4-12 |
| F-017 | W2 | W2-16 |
| F-018 | W3 | W3-01, W3-06, W3-07 |
| F-019 | W4 | W4-02, W4-11, W4-12 |
| F-020 | W3 | W3-12, W3-13, W3-18, W3-19 |
| F-021 | W3 | W3-04, W3-05, W3-08, W3-10, W3-12 |
| F-022 | W3 | W3-06, W3-07, W3-11 |
| F-023 | W3 | W3-02, W3-17 |
| F-024 | W5 | W5-06 |
| F-025 | W5 | W5-06, W5-07 |
| F-026 | W5 | W5-03, W5-04 |
| F-027 | W6 | W6-03, W6-12, W6-13, W6-18, W6-19, W6-21 |
| F-028 | W6 | W6-04, W6-14 |
| F-029 | W6 | W6-12, W6-15 |
| F-030 | W6 | W6-05, W6-06, W6-12 |
| F-031 | W6 | W6-07, W6-13 |
| F-032 | W2 | W2-09, W2-14, W2-17, W2-18 |
| F-033 | W8 | W8-15, W8-24 |
| F-034 | W7 | W7-01 |
| F-035 | W7 | W7-03, W7-07 |
| F-036 | W4 | W4-12, W4-13 |
| F-037 | W8 | W8-13, W8-14 |
| F-038 | W8 | W8-15, W8-24 |
| F-039 | W8 | W8-17 |
| F-040 | W4 | W4-06, W4-10, W4-14 |
| F-041 | W2 | W2-07, W2-09, W2-10, W2-11, W2-12, W2-13, W2-14, W2-15, W2-16, W2-19 |
| F-042 | W5 | W5-10, W5-12, W5-13 |
| F-043 | W5 | W5-15, W5-16, W5-17 |
| F-044 | W4 | W4-05, W4-06, W4-14, W4-17 |
| F-045 | W3 | W3-12, W3-14, W3-16, W3-18 |
| F-046 | W8 | W8-04, W8-05, W8-06, W8-07, W8-08, W8-09, W8-10, W8-25, W8-26 |
| F-047 | W2 | W2-08, W2-09, W2-10, W2-12, W2-13, W2-15, W2-16, W2-17, W2-19 |
| F-048 | W2 | W2-08, W2-09, W2-10, W2-12, W2-13, W2-15, W2-16 |
| F-049 | W2 | W2-09, W2-10, W2-12, W2-13, W2-15, W2-16, W2-17 |
| F-050 | W3 | W3-10, W3-12, W3-15, W3-18 |
| F-051 | W3 | W3-12, W3-16, W3-18, W3-19 |
| F-052 | W3 | W3-03, W3-05, W3-17 |
| F-053 | W3 | W3-07, W3-11, W3-19 |
| F-054 | W3 | W3-04, W3-05, W3-06, W3-07, W3-08, W3-11, W3-12 |
| F-055 | W2 | W2-11, W2-12, W2-13, W2-14, W2-15, W2-16 |
| F-056 | W2 | W2-13 |
| F-057 | W2 | W2-11, W2-12, W2-13, W2-14, W2-15, W2-16 |
| F-058 | W2 | W2-11, W2-12, W2-13, W2-14, W2-15, W2-16, W2-19 |
| F-059 | W9 | W9-01, W9-02, W9-03, W9-05, W9-06, W9-07, W9-08, W9-09, W9-14, W9-16 |
| F-060 | W8 | W8-02, W8-15, W8-16, W8-26, W8-27 |
| F-061 | W1 | W1-05, W1-11, W1-16 |
| F-062 | W1 | W1-05 |
| F-063 | W1 | W1-05, W1-09, W1-10 |
| F-064 | W8 | W8-18, W8-19 |
| F-065 | W1 | W1-01, W1-02, W1-04, W1-11, W1-12, W1-13 |
| F-066 | W1 | W1-07, W1-15 |
| F-067 | W4 | W4-12 |
| F-068 | W4 | W4-01, W4-13, W4-16 |
| F-069 | W8 | W8-22 |
| F-070 | W4 | W4-04, W4-11 |
| F-071 | W4 | W4-04, W4-13, W4-16 |
| F-072 | W4 | W4-01, W4-05, W4-06, W4-10, W4-15 |
| F-073 | W4 | W4-05, W4-12, W4-15 |
| F-074 | W4 | W4-08 |
| F-075 | W4 | W4-09, W4-14 |
| F-076 | W4 | W4-06, W4-07, W4-11, W4-12, W4-13, W4-14, W4-16, W4-17 |
| F-077 | W4 | W4-06, W4-14 |
| F-078 | W4 | W4-06, W4-10, W4-12, W4-14 |
| F-079 | W7 | W7-03 |
| F-080 | W7 | W7-02, W7-03 |
| F-081 | W7 | W7-02 |
| F-082 | W7 | W7-03 |
| F-083 | W7 | W7-05 |
| F-084 | W7 | W7-03, W7-07 |
| F-085 | W7 | W7-04 |
| F-086 | W5 | W5-03 |
| F-087 | W8 | W8-14, W8-15, W8-20, W8-26 |
| F-088 | W7 | W7-02, W7-09 |
| F-089 | W6 | W6-16 |
| F-090 | W6 | W6-06, W6-17 |
| F-091 | W8 | W8-14, W8-19 |
| F-092 | W6 | W6-12 |
| F-093 | W6 | W6-18, W6-19 |
| F-094 | W6 | W6-21 |
| F-095 | W6 | W6-08, W6-22 |
| F-096 | W6 | W6-01, W6-10 |
| F-097 | W6 | W6-09, W6-13 |
| F-098 | W6 | W6-08, W6-13, W6-22 |
| F-099 | W8 | W8-14, W8-15, W8-18, W8-28 |
| F-100 | W5 | W5-10, W5-12 |
| F-101 | W7 | W7-05, W7-06 |
| F-102 | W5 | W5-10, W5-11 |
| F-103 | W5 | W5-06, W5-08, W5-09 |
| F-104 | W5 | W5-14, W5-15, W5-16, W5-19 |
| F-105 | W7 | W7-03, W7-08 |
| F-106 | W9 | W9-10, W9-11, W9-12, W9-13, W9-15 |
| F-107 | W9 | W9-03, W9-04, W9-05, W9-07, W9-17, W9-18 |
| F-108 | W8 | W8-16 |
| F-109 | W2 | W2-14, W2-19 |
| F-110 | W4 | W4-12, W4-13, W4-14 |
| F-111 | W8 | W8-09, W8-10, W8-12, W8-26 |
| F-112 | W8 | W8-11, W8-15, W8-26 |
| F-113 | W8 | W8-01, W8-26 |
| F-114 | W8 | W8-01, W8-03, W8-12 |
| F-115 | W8 | W8-23 |
| F-116 | W2 | W2-11, W2-12, W2-13, W2-14, W2-15, W2-16, W2-17 |
| F-117 | W3 | W3-04, W3-07, W3-10, W3-12 |
| F-118 | W1 | W1-08 |
| F-119 | W1 | W1-07 |
| F-120 | W1 | W1-09 |
| F-121 | W1 | W1-02, W1-04, W1-07, W1-12 |
| F-122 | W1 | W1-11 |
| F-123 | W8 | W8-15, W8-22 |
| F-124 | W8 | W8-15 |
| F-125 | W7 | W7-03, W7-07, W7-08, W7-09, W7-12, W7-13, W7-14 |
| F-126 | W5 | W5-08 |
| F-127 | W5 | W5-18 |
| F-128 | W6 | W6-20 |
| F-129 | W7 | W7-10 |
| F-130 | W8 | W8-21 |
| F-131 | W7 | W7-11 |
| F-132 | W8 | W8-02, W8-26 |
| F-133 | W4 | W4-10 |
| F-134 | W2 | W2-14, W2-18 |
| F-135 | W6 | W6-19 |
| F-136 | W8 | W8-28 |
| F-137 | W7 | W7-12 |
| F-138 | W5 | W5-14, W5-19 |
