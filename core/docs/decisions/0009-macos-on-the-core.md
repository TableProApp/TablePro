# 0009: The macOS app moves to the core in slices, starting with the connection library

- **Status**: Accepted
- **Date**: 2026-11-04

## Context

The macOS app keeps everything in Swift: its connection library, sync, history, editor and a plugin per engine. The core has the same library ([0006](0006-connection-library.md)), the drivers, sessions, storage and the SQL script reader, and the Windows app already reaches them over UniFFI ([0002](0002-uniffi-bindings.md)). The Mac app has users and data, so it cannot switch at once: each piece has to move with its tests passing and its data intact.

The library is the first piece both apps model alike, but the Mac syncs it through CloudKit in a shape of its own. A `ConnectionGroup` record per group holds `groupId`, `name`, `color`, `iconName`, `parentId` and `sortOrder`. Each `Connection` record holds `groupId`, `sortOrder` and `isFavorite`, and the favourites' order is a list each Mac keeps in its defaults. The core holds one ordered favourites list and a group tree. Both apps pin the CloudKit container to Production, where a field nobody deployed makes CloudKit refuse the whole record.

## Decision

The Mac app moves to the core one slice at a time, reaching it through UniFFI's Swift bindings in an XCFramework of the core's static library, while its UI, the Keychain and the CloudKit transport stay in Swift. The first slice is the connection library, whose CloudKit records the core maps both ways.

## Slices

Each slice ships on its own, in this order:

1. **The connection library and its CloudKit mapping.**
   - 1a, this decision's change: the mapping in `tablepro_storage::cloudkit`, `ConnectionLibrary::cloud_edits` and `apply_cloud_pull` in `ffi`, `apple/scripts/build-core.sh`, and the `TableProFFI` package with its tests.
   - 1b: the app keeps its groups, each connection's group and place, and the favourites in the core's library. `GroupStorage`, the favourites order in `ConnectionListPreferences` and the placement fields of `DatabaseConnection` read and write through `ConnectionLibrary`, and `SyncCoordinator` turns `CKRecord` fields into `CloudLibraryRecords` and back.
2. **The connections themselves**: every field the `Connection` record carries, with passwords in the Keychain through `HostSecrets`, and the tags.
3. **Query history and saved queries.**
4. **The SQL script reader** (`sql_syntax::script`) for the editor's runs, splitting and formatting.
5. **Engines**, one at a time, when the driver ABI ([0004](0004-driver-plugin-abi.md)) or a linked engine replaces that engine's plugin.

The iOS app follows once 1b ships, with iOS slices in the same XCFramework.

## How Swift reaches the core

- **One UniFFI API.** `uniffi-bindgen-swift` comes from `core/crates/bindgen`, a crate of its own as 0002 says. The bindings are generated from the static library each build makes and are not in git: UniFFI checks at load that the Swift code and the library carry the same API checksums, and the library is built on the Mac anyway, so a committed copy would be one more thing to keep in step.
- **The XCFramework.** `TableProFFIC.xcframework` holds one `macos-arm64_x86_64` slice, a universal static library made with `lipo`, since an XCFramework splits by platform and never by architecture. Its headers and `module.modulemap` make the C module `TableProFFIC`; the generated Swift is the module `TableProFFI` in `apple/Packages/TableProFFI`. iOS adds `ios-arm64` and `ios-arm64-simulator` slices.
- **The static library.** `cargo rustc -p tablepro-ffi --release --no-default-features --crate-type staticlib`: the crate stays a cdylib for Windows, and `--no-default-features` leaves out the `engines` feature, every driver, which no Mac slice uses before slice 5.
- **The floor.** `MACOSX_DEPLOYMENT_TARGET` is the app's deployment target from `apple/project.yml`, macOS 13.0 today, read through `apple/scripts/lib/deployment-target.sh`, and the script fails when any object in the library asks for a newer macOS. The libraries in `apple/Libs/` are built for macOS 14.0; the core's library does not follow them.
- **Off the main thread.** The `TableProFFI` module turns on no `NonisolatedNonsendingByDefault`, so its async calls poll off the main actor (0002).
- **One SQLite in the app.** On Apple targets `tablepro-storage` builds the SQLite sqlx bundles, and the app links its own. Two copies in one process break each other's POSIX locks on the same file ([How To Corrupt An SQLite Database File](https://www.sqlite.org/howtocorrupt.html), 2.2.1). Before 1b links the library into the app, the Apple build of the core links the app's SQLite, as the Linux build links the distribution's.

## What stays Swift

- The UI, in AppKit and SwiftUI.
- The Keychain, which the core reaches through the `HostSecrets` callback interface.
- The CloudKit transport: the container and zone, subscriptions, the record cache, dirty and deleted tracking, push batches and the rebase of a refused push. The core sees field values and returns field values; it never names CloudKit.
- Per-device view settings: sort mode, the Recent switch and the recent count (0006).
- Every engine's plugin until slice 5.

## The CloudKit mapping

`tablepro_storage::cloudkit` maps the library to the records the Mac syncs today and uses only their existing fields, so no slice deploys a CloudKit schema. `modifiedAtLocal` and `schemaVersion` stay the Swift side's to stamp.

| Record field | Core |
| --- | --- |
| `ConnectionGroup.groupId`, `parentId` | `ConnectionGroup.id`, `parent_id`; ids are written upper case, as `uuidString` gives them |
| `ConnectionGroup.name` | `name`, cleaned of control characters as on Linux; the record keeps the name as written |
| `ConnectionGroup.color` | `None`, `Red`, `Orange`, `Yellow`, `Green`, `Blue`, `Purple`, `Pink`, `Gray` for `Slate`, and `Teal`, which a Mac reads as no colour |
| `ConnectionGroup.iconName` | `GroupIcon::Named` for the 15 symbols that draw the named icons (`server.rack` for Server), `GroupIcon::Symbol` for any other well-formed SF Symbol name |
| `ConnectionGroup.sortOrder`, `Connection.sortOrder` | `order` among the siblings |
| `Connection.groupId` | `SavedConnection.group_id` |
| `Connection.isFavorite` and the Mac's favourites order | `favorites`: the order the device keeps, then any other favourite by name |
| `Connection.name` | read only to break a tie in the order; slice 2 maps it |

Reading follows the Mac's own rules: a group whose parent the records lack, or one on a cycle, sits at the top; siblings go by `sortOrder`, a missing one reading as 0, then by name, then by id. The Mac compares names with `localizedStandardCompare`, which follows its locale; the core uses that order as it stands in English (digit runs by value, then letters without accents or case, then accents, then lower case first), which `apple/scripts/probes/check-library-name-order.sh` checks against Foundation. Only ties and favourites outside the order list depend on it, and reading never writes, so a Mac in another locale can list a tie differently without either side sending anything. A record the core cannot hold, such as a group with a blank name, is left out and left alone.

Writing keeps every value the server holds while it still reads as the library's. A library read from records therefore writes them back unchanged, and a colour, icon or parent that only another build understands survives. A list in the order its records read keeps their `sortOrder`, a new sibling takes a free value between its neighbours, and any other change numbers the list from 0, writing only the values that moved, as the Mac does.

A pull merges three ways. The server's records are the cache updated by the pull; each field this device changed since the cache is laid over them, which is the same edit `SyncRecordEdit` rebases when CloudKit refuses a push. A deletion wins from either side, a record with no cached copy takes the server's whole, and a record missing from the library is never read as a deletion. A group moved here that would close a cycle with a move another device pushed first keeps the server's parent: a tree cannot hold both, and laying out the cycle would root both groups and undo the other move on the next push.

A push sends what the library differs from the cache in, so the cache may hold only records the library has read. The Swift side therefore takes every record it caches through `apply_cloud_pull`: a pull's, and a push's saved copies, which CloudKit may have rebased onto another device's change, with the cache from before the push as the base. A copy cached without that step would read as an edit here and undo the other device's change on the next push.

## Rationale

- **Slices keep the app shippable.** Each slice replaces one Swift store behind tests that already pass, and the next waits for it.
- **The library first.** It is the one store whose model 0006 already made the same on both sides, and it gates every later slice: connections, history and sessions all key on it.
- **The mapping lives in the core**, beside the library it maps, so its rules have Rust tests, and the Windows app gets the same rules if it ever syncs through iCloud.
- **Only existing fields.** A new field needs a Production deploy before any build writes it, and an older build would still ignore it. The order and the favourites map onto what is there.
- **No engines in the Apple library.** The Mac keeps its plugins until slice 5, so linking nine engines, DuckDB among them, would add their size and a second copy of DuckDB next to its plugin's.

## Consequences

- 1b must keep the Swift stores readable by the previous stable release: a beta user can turn betas off, and Sparkle never downgrades (`apple/RELEASING.md`, Storage check).
- `tablepro-ffi` has an `engines` feature, on by default. The Windows app and the tests keep every engine.
- `core.yml` builds the library for Apple silicon and runs the `TableProFFI` tests on every core change.
- A CloudKit field the core cannot hold yet stays the Swift side's until its slice, which means 1b reads and writes the library fields through the core and every other `Connection` field as today.
- Two Macs that reorder the same list at once keep the order the field-by-field merge gives, the same result the Swift merge gives today.

## Verification

Each slice ships when all of these pass:

- **Rust**: the crate's tests. For slice 1, `cargo test -p tablepro-storage cloudkit` reads arbitrary records, malformed ones included, and checks that writing them back sends nothing, and plays two devices editing apart through a server that rebases each push, checking that they converge and then send nothing; `cargo test -p tablepro-ffi --test cloud_library` runs the same through the FFI.
- **Bindings**: `apple/scripts/build-core.sh` then `swift test --package-path apple/Packages/TableProFFI`, which `core.yml` runs on macOS.
- **App**: the app's existing suites for the store a slice replaces pass unchanged against the core, with new tests for the Swift side's adapter, and `ProductionSchemaParityTests` shows no new CloudKit field.

The hosted [verification run 41696940325](https://github.com/TableProApp/TablePro/actions/runs/41696940325/job/126129842605) built both macOS architectures with Rust 1.98. The universal archive occupied 43 MiB, and its highest recorded minimum OS was macOS 13.0. The package linked with its declared system libraries and passed all three Swift tests. The Foundation ordering probe passed all 16 pairs.

## Alternatives considered

- **Move the whole app at once.** One change touching every store, with no release in between to find what broke.
- **Map CloudKit in Swift.** The rules would live apart from the library they keep whole, with no Rust test, and the next app would write them again.
- **A favourites order field on the `Connection` record.** It needs a Production deploy, and an older build would neither read nor keep it.
- **Commit the generated Swift, as Windows commits its C#.** The Swift build needs the Rust library either way, so the copy saves no generator run and can drift from the library it binds.
