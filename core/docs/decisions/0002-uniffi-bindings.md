# 0002: One UniFFI API for Swift and C#, with a C ABI beside it

- **Status**: Accepted
- **Date**: 2026-11-02

## Context

The Windows app (C# on .NET 10, WinUI 3, Native AOT) and the Swift apps (macOS and iOS) reach the core over FFI ([0001](0001-shared-core.md)). macOS moves to the core piece by piece, so Swift and the core live side by side for a long time. The GTK app calls the Rust API directly and needs no bindings.

Both languages need async calls, cancellation, progress, streams of results and typed errors. Rust has no stable ABI, so whatever crosses has to be generated or written by hand.

A spike on 2026-11-02 built one crate with both a UniFFI layer and a hand-written C ABI over a fake engine, and drove it from Swift and from C# under JIT and Native AOT. It ran on macOS 27.0.1, Apple silicon, with Rust 1.98.1, uniffi 0.31.2, uniffi-bindgen-cs v0.11.1+v0.31.0, csbindgen 1.9.8, .NET SDK 10.0.402 and Swift 6.4 in language mode 6. All 51 checks passed, with no `ILxxxx` trim or AOT warning.

## Decision

The core exports one API through UniFFI proc macros, Swift reads it with UniFFI's own generator and C# with uniffi-bindgen-cs pinned to v0.11.1+v0.31.0, each language adds a thin hand-written layer, and hot paths use `extern "C"` functions with csbindgen in the same library.

## Rationale

- **One definition.** One set of `#[uniffi::export]` items builds one library, and both generators read it with `--library`. Every check passed in both languages: an async open that returns on the caller's UI thread or MainActor, a string round trip with accents, emoji, CJK, Greek and a NUL, typed errors with code, message and detail, progress callbacks, cancel and pull streams.
- **uniffi-bindgen-cs fits Native AOT.** It emits `[LibraryImport]` on .NET 8 and later, and the AOT binary passed every check with zero warnings. Its open Mono AOT bug (issue #175) does not reach WinUI 3, which runs on CoreCLR.
- **Swift's generator covers the rest.** Async functions, callback interfaces, error enums and Swift 6 mode all built clean with zero warnings.
- **A C ABI for the whole surface costs too much.** The spike's 7 C entry points took 224 lines of unsafe Rust and 243 lines of C#, or 45 to 86 lines per async function. That is fine for a few hot paths and as the way out, not for every call.

What each language's hand layer adds:

- **Cancellation.** UniFFI does not cancel ("We don't directly support cancellation", uniffi-rs 0.32.2 manual). The generated Swift waits in `withUnsafeContinuation` with no handler, and the C# `UniffiRustCallAsync` takes no token. Without the layer, a cancelled Swift Task ran all 20 batches and returned about 0.4 s later. The core exports a `CancelToken` object. Swift's `withTaskCancellationHandler` and C#'s `CancellationToken.Register` call it, and the core checks it at every await.
- **Progress and streams.** A callback runs on a core runtime thread and only enqueues: `IProgress<T>` posts through the UI thread's `SynchronizationContext` in C#, and `AsyncStream.Continuation.yield` feeds a `for await` on the MainActor in Swift. A pull `next()` becomes `IAsyncEnumerable` and `AsyncThrowingStream` in a few lines and runs no foreign code on runtime threads.
- **Off the UI thread.** The generated C# polls on the thread that awaits (`await tcs.Task` with no `ConfigureAwait(false)`), so a call awaited on the UI thread decodes its result there. The C# layer starts calls through `Task.Run`. In Swift, polling runs off the MainActor unless the bindings module has `NonisolatedNonsendingByDefault`, which Xcode's Approachable Concurrency turns on; with it the spike polled on the main thread.

## Consequences

- Swift stays on the UniFFI minor that uniffi-bindgen-cs supports, since one library carries one scaffolding contract. That is 0.31 today (the crate pinned `=0.31.2`) while upstream is 0.32.2. Issue #183, "Update for 0.32 uniffi", has been open since 2026-08-28.
- One company maintains uniffi-bindgen-cs: NordSecurity, MPL-2.0, 190 stars, 38 open issues, releases on 2025-08-22, 2025-09-09, 2026-06-23 and 2026-10-09. Its own CI runs only on `ubuntu-latest` and tests no AOT, so our CI is the only Windows and AOT check. We pin it by tag and build it in CI. If it stops, the C ABI is the way out.
- The core owns one tokio runtime. Every exported async function spawns onto it and aborts the task when the binding's future is dropped, since a dropped `JoinHandle` alone detaches it.
- The core never calls foreign code while it holds a lock. A slow callback stalls a runtime worker, and the first callbacks into .NET on a runtime thread took up to 3.8 ms.
- `RustBuffer` serializes records and strings on every call. That is fine for control calls. Result rows take the path in [0003](0003-result-windows-for-native-grids.md).
- Panics: UniFFI turns one into an error. A panic out of a C ABI export aborts the process, so each export catches it. In C#, an exception that escapes an `UnmanagedCallersOnly` callback ends the process, so each callback catches too.
- The bindgen binary lives in a crate of its own. With uniffi's `cli` feature in the library, `libtpcore.a` was 39 MB before dead-stripping.
- Unverified in the spike: the Swift XCFramework of the static library, linking and running on an iOS device (the crate built for `aarch64-apple-ios` and the bindings compiled), `DispatcherQueueSynchronizationContext` as the progress target, and the DLL search on Windows. Static linking through `DirectPInvoke` needs the Rust `.lib` built with the same C runtime choice (`/MD` or `/MT`) as the AOT link.
- C# strings are UTF-16, and `Encoding.UTF8` turns a lone surrogate into U+FFFD without an error, so a malformed file name changes silently at the boundary.

## Alternatives considered

- **The C ABI with csbindgen for everything.** It works under Native AOT and gives a real `CancellationToken`, but every function is unsafe code we write and keep. csbindgen 1.9.8 emits `[DllImport]`, not `[LibraryImport]`, which stays blittable only with pointers, integers and function pointers. Kept for hot paths and as the fallback.
- **Interoptopus 0.16.6.** C# is its only tier 1 backend and it has no Swift backend, so it would be a second API definition next to UniFFI. Dropped without a prototype.
- **A separate API definition per language.** Two contracts to keep in step for every change.

## Measurements

Ranges over four runs of each path, single-shot timings, so read them as orders of magnitude.

| Measure | Swift UniFFI | C# UniFFI, AOT | C# C ABI, AOT |
|---|---|---|---|
| Cancel request to exception at the caller | 0.07 to 0.15 ms | 0.05 to 0.22 ms | 0.04 to 1.00 ms |
| Callback time on the runtime thread, median / max | 34 to 65 / 102 to 143 us | 22 to 54 / 64 to 3787 us | 13 to 16 / 23 to 261 us |
| Sync string echo | 132 to 149 ns | 190 to 352 ns | 126 to 225 ns |
| Async ping round trip | 15.6 to 34.5 us | 8.4 to 20.6 us | 8.1 to 19.2 us |
| AOT executable, dynamic / static core | n/a | 1.77 + 1.15 MB / 2.42 MB | 1.44 + 1.15 MB / 2.03 MB |
