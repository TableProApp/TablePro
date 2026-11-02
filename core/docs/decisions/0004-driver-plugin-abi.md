# 0004: Downloadable drivers over a small C ABI of our own

- **Status**: Accepted
- **Date**: 2026-11-02

## Context

Drivers stay downloadable on every platform from a registry, as the macOS app's `.tableplugin` bundles are today. [Linux ADR 0001](../../../linux/docs/decisions/0001-no-plugin-system.md) chose no plugin system for Linux, and [0001](0001-shared-core.md) kept drivers linked at compile time until this decision.

Rust has no stable ABI, so a driver built apart from the app needs a boundary that both sides agree on. That boundary has to carry the whole driver surface:

- Linux, `tablepro-core`: `Connection` 29 methods, `SqlDialect` 42, `DdlDialect` 13, `EditorSession` 7 and `DatabaseDriver` 4, about 95 in all. Every call takes a deadline and a cancel token, results stream into a sink, and the host's transport opens the socket ([Linux ADR 0016](../../../linux/docs/decisions/0016-driver-contract-v2.md)).
- macOS, `TableProPluginKit`: `PluginDatabaseDriver` has 210 requirements, plus users and roles, live messaging, routine debugging and about 44 static metadata properties.

A spike on 2026-11-02 compared four options and built the C ABI with a SQLite driver. It ran on macOS 27.0.1, arm64, with rustc 1.98.1, tokio 1.54.1, rusqlite 0.41.1, arrow 60.1.0, prost 0.14.4 and libloading 0.9.0. The dynamic and the static run passed every scenario.

## Decision

Each driver is a Rust crate that exports a small C ABI of our own, the app loads it from a signed library the registry ships per platform and architecture, and the same crate links statically where code cannot be downloaded.

## Rationale

The parts of the ABI, and what the spike showed for each:

- **A static descriptor.** `tablepro_driver_descriptor` holds a magic, its size, the ABI major and minor, a `panic_unwind` flag, the driver id and its version, at offsets that never move. The host reads it before running any driver code and refuses another major, a wrong magic or a `panic=abort` build. A driver claiming ABI 2.0 and a foreign library were both refused before any of their code ran.
- **Minor versions negotiate down.** `tablepro_driver_open` fills a table with `call`, `cancel` and `shutdown`. Both sides use `min(host, driver)`, and every struct starts with its size, so a later minor appends fields.
- **Requests and responses are protobuf.** One `Request` oneof has a kind per capability. Unknown fields are skipped, and an unknown kind is answered `UNSUPPORTED`, so a new host learns an old driver lacks a feature without a minor bump. Tests of both directions of a version skew pass. One inline call took 183 to 275 ns warm.
- **Rows are Arrow C Data.** The host moves the `ArrowSchema` and `ArrowArray` structs out and builds a `RecordBatch`. The release callback frees them later in the driver's own code, so memory never crosses sides to be freed. This matches the core's columnar store ([0003](0003-result-windows-for-native-grids.md)).
- **Each driver runs its own tokio runtime.** A library has its own copy of std and tokio, and tokio keeps its runtime context in a thread-local, so the host's runtime cannot be shared. A plugin handed the host's future panicked in `TcpStream::connect` with "there is no reactor running". The driver builds a runtime in `open`; the process went from 1 to 3 threads.
- **`catch_unwind` at every export.** Work on driver threads runs guarded too, and a completion dropped during an unwind still answers `PANIC`. The driver answered again after both panics. The control case, an export with no guard, aborted the process with SIGABRT.
- **Calls complete once.** `call` returns OK and then exactly one completion follows, on any thread. Cancel answered `CANCELLED` in 32 us to 3.9 ms. `shutdown` cancels every call, waits for the completions and joins the driver's threads.
- **The host dials.** The host opens the stream (direct, SSH forward or proxy) and hands the driver the socket. A client crate that dials by itself gets the route instead.
- **The same crate builds static.** The crate is `rlib` plus `cdylib`, and only its `plugin` feature emits the two exports. The static build calls the same adapter and gets the same table, messages and runtime per driver, so one test matrix covers both. Built for `aarch64-apple-ios`, the bundle exports no `tablepro_driver_*` symbol, so many drivers link into one binary. iOS needs this: App Review Guideline 2.5.2 forbids downloading code that adds features.

## Consequences

- **No unload.** macOS never unloads an image with thread-local variables (`MH_HAS_TLV_DESCRIPTORS`, dyld's `neverUnload()`), and every Rust library that uses std has them. `shutdown` frees the driver's state and joins its threads, the image stays mapped until the app quits, and Arrow batches are released before shutdown. A driver update takes effect after a restart. Unload on Linux and Windows was not tested.
- **macOS signing.** The registry signs every driver with TablePro's Team ID and notarizes it. A bare library cannot carry a stapled ticket, so Gatekeeper looks it up online. The installer keeps today's checks: sha256, `SecStaticCodeCheckValidity` against the Team ID requirement, and removing quarantine. Drivers then load under library validation, and `disable-library-validation` stays only for SQLite and DuckDB extensions. With a Developer ID host on the hardened runtime:
  - unsigned: "missing code signature";
  - ad hoc: "different Team IDs";
  - TablePro's Team ID: loaded;
  - TablePro's Team ID, quarantined, not notarized: "library load disallowed by system policy".
- **Windows signing.** Every driver DLL carries an Authenticode signature, since Smart App Control blocks unknown unsigned code. The app checks it with `WinVerifyTrust` and matches the signer to TablePro's certificate, because `WinVerifyTrust` alone only checks the chain and the code-signing EKU. It loads by full path with `LoadLibraryExW` and `LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS`, after `SetDefaultDllDirectories`.
- **One build per architecture.** An x64 app that loaded an Arm64 DLL got `BadImageFormatException` (0x8007000B). An unpackaged Arm64 AOT app loaded an Arm64 driver DLL from `%LOCALAPPDATA%` with `NativeLibrary.Load`.
- Each driver carries its own std and tokio: 302 KB for a std-only driver, 2.66 MB for SQLite with tokio, arrow and prost. Each loaded driver adds runtime threads.
- The first `dlopen` of a newly signed library took 120 to 560 ms, later loads 0.8 to 47 ms.
- A workspace-wide build unifies features and builds a library with no exports. A thin `<engine>-plugin` crate per driver avoids that.
- A contained panic still closes its connection, since the driver's state may be poisoned. A memory fault in a C library inside a driver (SQLite, DuckDB, librdkafka) still ends the app. Out-of-process drivers were not evaluated.
- The first Windows release links its 9 drivers statically, as the crates without the `plugin` feature. The ABI lands in a later PR, and until then every app links its drivers at compile time.
- [Linux ADR 0001](../../../linux/docs/decisions/0001-no-plugin-system.md) is superseded.

Open:

- About 95 trait methods and 210 PluginKit requirements become message kinds. The work is large but mechanical. The dialect's many small synchronous calls could become one static descriptor plus a few calls.
- The SQL, Redis and mongosh grammars and the document builders sit in `tablepro-core`. A downloadable new engine either brings its grammar in the driver, or the core ships it ahead. Not decided.
- Microsoft Store Policy 10.2.2 forbids changing or extending a product's described functionality "through any form of dynamic inclusion of code", while 10.1.5 allows extensions with the user's consent. Store review of driver downloads is a risk.
- Flatpak: `dlopen` from `~/.var/app/$FLATPAK_ID` is untested at runtime. bubblewrap mounts it without `MS_NOEXEC`, so it should work. Drivers build against the oldest glibc of the channels they serve.
- Opening an SSH forward, reading a secret and an askpass prompt take time, so host calls need the same call and completion pattern.
- Intervals, wide integers, `TimeTz`, `Other` and `Undecodable` need Arrow extension types to stay lossless ([Linux ADR 0014](../../../linux/docs/decisions/0014-lossless-values-and-dialects.md)).
- The prototype returns one batch. A fetch by cursor or an `ArrowArrayStream` that keeps the sink's backpressure is not built.
- MSIX loading from the package's `LocalState` is untested.

## Alternatives considered

- **ADBC** (arrow-adbc 25, spec 1.1.0). It covers SQL execution and part of the catalog. It has no indexes, triggers, routines, sequences, view definitions or user-defined types (open for the unreleased spec 1.2.0), no DDL, explain plans, users, activity, documents or pub/sub, no socket handed in by the host, and no async. Its driver table has a fixed size, so a driver cannot add a call. No ADBC driver exists for Redis, MongoDB or Kafka. Against the Apache SQLite ADBC driver 1.13.0, indexes and triggers came back as tables with no definition, `UNIQUE` and `CHECK` were missing, an empty table's text column read as `Int64`, and cancel was not implemented, so the query ran 4.5 s past the cancel. ADBC can come later as one TablePro driver that hosts the ADBC driver manager.
- **abi_stable and stabby.** abi_stable 0.11.3 was last released and committed on 2023-10-12, has no FFI-safe future and never unloads. stabby 72.1.16 is active but "doesn't support async traits yet". Neither shares tokio, contains panics or settles who owns the rows, and both tie the ABI to Rust, while a C ABI also admits C, C++ and Go drivers and the ADBC bridge.
- **WASM components** on wasmtime 50.0.1. No Unix sockets, which SSH forwards are ([Linux ADR 0013](../../../linux/docs/decisions/0013-openssh-client-transport.md)). Only tokio's current-thread runtime, and `spawn_blocking` panics. tokio-postgres, sqlx MySQL and mongodb did not compile, and DuckDB, librdkafka, Oracle OCI and ODBC drivers cannot run in it. Synchronous calls cost about 3.5x. The sandbox gains little, since a driver holds the user's credentials anyway.
- **Static drivers only.** Every new engine would wait for an app release on every platform, while macOS already ships drivers from a registry.
