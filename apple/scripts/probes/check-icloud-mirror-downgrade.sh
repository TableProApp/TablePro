#!/usr/bin/env bash
# T-DWN for the iCloud engine's downgrade mirror (core ADR 0054, Downgrade mirror): the previous stable's own sync
# metadata code reads what this build's mirror writes. The mirror, built from this tree over the core's bindings,
# writes a committed pass and a journal's marks into one defaults suite and record cache; the previous
# stable's `SyncMetadataStorage` and `SyncRecordCache`, built from its tag, read them back as that build syncs from
# them. Run `apple/scripts/build-core.sh` first, since the writer links the core.
#
# Usage: check-icloud-mirror-downgrade.sh [previous stable tag, default v0.88.0]
set -euo pipefail

PREVIOUS="${1:-v0.88.0}"
APPLE="$(cd "$(dirname "$0")/../.." && pwd)"
REPO="$(cd "$APPLE/.." && pwd)"
[ -d "$APPLE/Packages/TableProFFI/Build/TableProFFIC.xcframework" ] \
    || { echo "Build the core first: apple/scripts/build-core.sh" >&2; exit 2; }
git -C "$REPO" rev-parse --verify --quiet "$PREVIOUS^{commit}" > /dev/null \
    || { echo "No such ref: $PREVIOUS" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tablepro-icloud-mirror-downgrade.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Sources/PreviousSyncTransport" "$WORK/Sources/TableProSyncTransport" "$WORK/Sources/check"

SYNC=apple/Packages/TableProCore/Sources/TableProSyncTransport
git -C "$REPO" ls-tree --name-only "$PREVIOUS" "$SYNC/" | while read -r path; do
    git -C "$REPO" show "$PREVIOUS:$path" > "$WORK/Sources/PreviousSyncTransport/$(basename "$path")"
done
cp "$REPO/$SYNC"/*.swift "$WORK/Sources/TableProSyncTransport/"
cp "$APPLE"/TablePro/Core/Sync/LegacyMirror/*.swift \
    "$APPLE/TablePro/Core/Sync/Transport/CloudKitRecordConversion.swift" \
    "$APPLE/TablePro/Core/Sync/Transport/CloudKitChangeToken.swift" \
    "$WORK/Sources/check/"

cat > "$WORK/Package.swift" << EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IcloudMirrorDowngrade",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "$APPLE/Packages/TableProFFI")],
    targets: [
        .target(name: "PreviousSyncTransport", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "TableProSyncTransport", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "check",
            dependencies: ["PreviousSyncTransport", "TableProSyncTransport",
                           .product(name: "TableProFFI", package: "TableProFFI")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
EOF

cat > "$WORK/Sources/check/main.swift" << 'EOF'
import CloudKit
import Foundation
import PreviousSyncTransport
import TableProFFI
import TableProSyncTransport

var failures: [String] = []
func expect(_ condition: Bool, _ what: String) {
    if !condition { failures.append(what) }
}

let suiteName = "com.TablePro.probe.mirror-downgrade.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suiteName)!
let cacheDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("mirror-downgrade-\(UUID().uuidString)", isDirectory: true)
defer {
    defaults.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: cacheDirectory)
}

let zone = CKRecordZone.ID(zoneName: TableProSyncTransport.CloudKitSyncEngine.zoneName, ownerName: "_alice")
let base = CKRecord(recordType: "ConnectionTag", recordID: CKRecord.ID(recordName: "Tag_A", zoneID: zone))
let owner = UUID()
let syncing = UUID()
let localOnly = UUID()
let readable = ["Connection", "ConnectionGroup", "ConnectionTag"]

let mirror = LegacySyncMetadataMirror(
    metadata: TableProSyncTransport.SyncMetadataStorage(userDefaults: defaults),
    recordCache: TableProSyncTransport.SyncRecordCache(directory: cacheDirectory, defaults: nil)
)
try mirror.write(metadata: LegacyMetadataArg(
    token: nil,
    dirty: [LegacyRecordArg(recordType: "Connection", id: syncing.uuidString)],
    tombstones: [LegacyTombstoneArg(
        record: LegacyRecordArg(recordType: "ConnectionGroup", id: "G1"),
        deletedAtMs: 1_767_225_600_000,
        owner: owner.uuidString
    )],
    deferredDeletions: ["Favorite_X"],
    changesHeldForUnreadable: ["Connection_C"],
    removalsPendingForUnreadable: [],
    deletionsHeldForUnreadable: ["Connection_D"],
    ownersKeptOffSync: [owner.uuidString],
    standing: [
        LegacyStandingArg(connection: syncing.uuidString, standing: .syncs),
        LegacyStandingArg(connection: localOnly.uuidString, standing: .localOnly)
    ],
    readableRecordTypes: readable,
    account: "_alice",
    zoneState: "confirmed",
    cache: [CloudKitRecord(
        recordType: "ConnectionTag",
        name: "Tag_A",
        systemFields: CloudKitRecordConversion.systemFields(of: base),
        createdMs: nil,
        fields: [CloudKitField(name: "name", value: .text(value: "Production"))]
    )]
))
// An edit and a deletion made offline after that pass, as the engine marks them from the journal.
try mirror.mark(
    dirty: [LegacyRecordArg(recordType: "ConnectionTag", id: "T9")],
    tombstones: [LegacyTombstoneArg(
        record: LegacyRecordArg(recordType: "Connection", id: syncing.uuidString),
        deletedAtMs: 1_767_225_700_000,
        owner: nil
    )]
)

let previous = PreviousSyncTransport.SyncMetadataStorage(userDefaults: defaults)
let previousCache = PreviousSyncTransport.SyncRecordCache(directory: cacheDirectory, defaults: nil)
expect(previous.dirtyIds(for: .tag) == ["T9"], "the offline edit is not dirty for the previous stable")
expect(previous.dirtyIds(for: .connection).isEmpty, "a deleted record kept its dirty mark")
expect(previous.tombstones(for: .connection).map(\.id) == [syncing.uuidString], "the offline deletion has no tombstone")
expect(previous.tombstones(for: .group).first?.owner == owner, "a tombstone lost its owner")
expect(
    previous.tombstones(for: .group).first?.deletedAt == Date(timeIntervalSince1970: 1_767_225_600),
    "a tombstone lost its deletion time"
)
expect(previous.deferredDeletions == ["Favorite_X"], "the deferred deletions did not come across")
expect(previous.changesHeldForUnreadableCopies == ["Connection_C"], "the held changes did not come across")
expect(previous.deletionsHeldForUnreadableCopies == ["Connection_D"], "the held deletions did not come across")
expect(previous.ownersKeptOffSync() == [owner], "the owners kept off sync did not come across")
expect(previous.standing(ofConnection: syncing) == .syncs, "a syncing connection lost its standing")
expect(previous.standing(ofConnection: localOnly) == .keptOff, "a Local only connection lost its standing")
expect(previous.lastAccountId == "_alice", "the account did not come across")
expect(previous.zoneState == .confirmed, "the zone state did not come across")
expect(previous.lastSyncDate != nil, "the previous stable shows no last sync")
expect(!previous.adoptReadableRecordTypes(Set(readable)), "the previous stable would fetch the zone again")
let cached = previousCache.record(named: "Tag_A")
expect(cached?["name"] as? String == "Production", "the cached record lost its fields")
expect(cached?.recordID.zoneID == zone, "the cached record lost its zone")

if failures.isEmpty {
    print("PASS")
} else {
    failures.forEach { print("FAIL: \($0)") }
    exit(1)
}
EOF

swift run --package-path "$WORK" -c debug check 2>&1 | tail -40
