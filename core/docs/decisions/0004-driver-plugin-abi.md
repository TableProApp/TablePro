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

- **A static descriptor.** `tablepro_driver_descriptor` holds a magic, its size, the ABI major and minor, a `panic_unwind` flag, the driver id and its version, at offsets that never move. Mapping a native library can run its initializers; signature verification precedes mapping. The host reads the descriptor before calling any driver ABI entry point and refuses another major, a wrong magic or a `panic=abort` build. A driver claiming ABI 2.0 and a foreign library were both refused before any of their ABI entry points ran.
- **Minor versions negotiate down.** `tablepro_driver_open` fills a table with `call`, `cancel` and `shutdown`. Both sides use `min(host, driver)`, and both API tables start with their size. Open also receives the host output capacity and refuses a buffer smaller than the negotiated table prefix, so a later minor can append fields.
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
- The first Windows release links its 9 drivers statically. The apps still link every driver they offer at compile time; the ABI below adds drivers beside them.
- [Linux ADR 0001](../../../linux/docs/decisions/0001-no-plugin-system.md) is superseded.

What is built (2026-11-04):

- `crates/driver-abi` holds the table (`include/tablepro_driver.h`), the messages, the driver's side of the table, and `CoreDriver`, which serves any core `DatabaseDriver` over it. The message kinds are Describe, OpenFile, Probe, ListSchemas, ListObjects, Read and Close; Read returns one statement's first result set as one Arrow batch.
- A thin `<engine>-plugin` crate is the library: `crates/drivers/sqlite-plugin` exports the core's SQLite driver, versioned by its own `Cargo.toml`. Its tests run one matrix on the loaded library and on the same driver linked in.
- `crates/driver-host` loads a library, reads its descriptor before calling its ABI entry points, calls it, and keeps installed drivers under `<storage>/drivers`: one folder per install and an `installed.json` index with each file's sha256. Every load checks that checksum and the signature again, holding the file open so it cannot be swapped before it maps. A replaced or removed driver stays mapped until the app quits, and its folder goes at the next start.
- Windows checks the Authenticode signature with revocation on install, falling back to no revocation check when no answer comes offline, and without the network on each later load. The signer is matched on two things the app passes in `HostConfig.driver_signers`: the signing certificate's subject as `CertNameToStrW` writes it with `CERT_NAME_STR_REVERSE_FLAG` (the form `X509Certificate2.Subject` shows), and the SHA-256 of the certificate that issued it. A subject alone is a name any trusted CA can issue; the issuer pins the CA, and a renewed certificate from it still matches. macOS and Linux refuse every driver until their check is built.
- The catalog, `drivers/v1.json`, lists entries in the shape of a `plugins/v3.json` entry (`id`, `name`, `databaseTypeIds`, `releases`). A release carries `abi`, `os` and `arch` (Rust's `std::env::consts` names) in place of `pluginKit` and `minimumSystemVersion`; a file of its own keeps PluginKit apps from reading it. The app downloads a release, and the core checks its sha256, the driver id and the version against the entry.
- The Windows app lists installed drivers in Settings, installs one from a file or from the catalog, and removes one.

Left to build:

- The rest of the driver surface as message kinds (`Connection`, `SqlDialect`, `DdlDialect`, `EditorSession`), with a `DatabaseDriver` over a `DriverHandle`. Until then a loaded driver is listed in Settings and not offered to connect, and nothing decides yet between a driver the app links and a downloaded one with the same id.
- Host calls with the same call and completion pattern: opening a stream through the host's transport, secrets and askpass. OpenFile is the only connect until they land.
- Rows by cursor or `ArrowArrayStream` that keep the sink's backpressure; Read returns one batch.
- Arrow extension types for the values ADR 0014 keeps lossless. Today a column whose values have no Arrow type of their own, or several kinds, carries the export's exact text and names the kind in its field metadata.
- A `.proto` file for drivers in other languages; the Rust derives are the schema.
- TablePro's Authenticode certificate, its subject and issuer in the app, and a release workflow that builds, signs and publishes each driver per architecture with the catalog. A signature on the catalog, as `plugins/v3.json` has, would add rollback protection; the Authenticode check is the gate today.
- The macOS check (`SecStaticCodeCheckValidity` against the Team ID) and a Linux one in the core.
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
