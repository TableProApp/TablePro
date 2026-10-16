//
//  ThemeCatalogSyncTests.swift
//  TableProTests
//
//  Each user theme syncs as the settings record `theme.<id>`. The catalog marks it on every edit,
//  tombstones it after a move to the Trash, and writes what another Mac sent without marking
//  anything, after treating it as untrusted input.
//

import AppKit
import Foundation
import os
@testable import TablePro
import TableProSyncTransport
import TableProTheme
import Testing

@MainActor
struct ThemeCatalogSyncTests {
    @MainActor
    private final class Harness {
        let root: URL
        let center = NotificationCenter()
        let suite: EphemeralDefaults
        let tracker: SyncChangeTracker
        let fileTrash: ThemeFileTrash
        private(set) var catalog: ThemeCatalog

        var themes: URL { root.appendingPathComponent("Themes", isDirectory: true) }
        var trash: URL { root.appendingPathComponent("Trash", isDirectory: true) }
        var dirty: Set<String> { tracker.dirtyRecords(for: .settings) }
        var tombstoned: Set<String> { tracker.tombstonedIds(for: .settings) }

        init(userDirectory: URL? = nil, fileTrash: ThemeFileTrash? = nil) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ThemeCatalogSyncTests-\(UUID().uuidString)", isDirectory: true)
            suite = try EphemeralDefaults()
            tracker = SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: suite.defaults))
            let folders = [
                root.appendingPathComponent("Themes", isDirectory: true),
                root.appendingPathComponent("Trash", isDirectory: true),
            ]
            for folder in folders {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            self.fileTrash = fileTrash ?? .folder(folders[1])
            catalog = ThemeCatalog(
                userDirectory: userDirectory ?? folders[0],
                bundleDirectory: nil,
                notificationCenter: center,
                fileTrash: self.fileTrash,
                syncTracker: tracker
            )
        }

        @discardableResult
        func write(_ theme: ThemeDefinition, as fileName: String? = nil) throws -> URL {
            let url = themes.appendingPathComponent(fileName ?? "\(theme.id).json")
            try ThemeFileFormat.encode(theme).write(to: url)
            return url
        }

        func reopen() {
            catalog = ThemeCatalog(
                userDirectory: themes,
                bundleDirectory: nil,
                notificationCenter: center,
                fileTrash: fileTrash,
                syncTracker: tracker
            )
        }

        func fileNames() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: themes.path).sorted()
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    nonisolated private static func theme(
        _ id: String,
        name: String? = nil,
        appearance: ThemeAppearance = .dark,
        background: String = "#101010"
    ) throws -> ThemeDefinition {
        ThemeDefinition(
            id: id,
            name: name ?? id,
            author: "",
            appearance: appearance,
            overrides: [.editorBackground: try ThemeColor(validating: background)]
        )
    }

    nonisolated private static func category(_ id: String) -> String {
        ThemeCatalog.syncCategory(for: id)
    }

    // MARK: - Local changes

    @Test("Save, rename, duplicate and import each mark the theme's record dirty")
    func editsMarkDirty() throws {
        let harness = try Harness()
        defer { harness.remove() }

        let saved = try Self.theme("user.saved")
        try harness.catalog.save(saved)
        #expect(harness.dirty == [Self.category(saved.id)])

        let renamedTarget = try Self.theme("user.renamed")
        try harness.write(renamedTarget)
        harness.reopen()
        try harness.catalog.rename(id: renamedTarget.id, to: "Night Shift")
        #expect(harness.dirty.contains(Self.category(renamedTarget.id)))

        let copy = try harness.catalog.duplicate(saved)
        #expect(harness.dirty.contains(Self.category(copy.id)))

        let incoming = harness.root.appendingPathComponent("incoming.json")
        try ThemeFileFormat.encode(try Self.theme("user.incoming")).write(to: incoming)
        let imported = try harness.catalog.importTheme(from: incoming)
        #expect(harness.dirty.contains(Self.category(imported.id)))
        #expect(harness.tombstoned.isEmpty)
    }

    @Test("Loading the folder and reloading on activation mark nothing")
    func loadsMarkNothing() throws {
        let harness = try Harness()
        defer { harness.remove() }
        try harness.write(try Self.theme("user.existing"))

        harness.reopen()
        harness.center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        harness.catalog.reloadSynchronously()

        #expect(harness.catalog.theme(id: "user.existing") != nil)
        #expect(harness.dirty.isEmpty)
        #expect(harness.tombstoned.isEmpty)
    }

    @Test("Moving a theme to the Trash tombstones its record only once the file is gone")
    func trashTombstonesAfterTheMove() throws {
        let tombstonedDuringMove = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let probe = TrackerProbe()
        let trashFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThemeCatalogSyncTests-trash-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: trashFolder) }
        let folder = ThemeFileTrash.folder(trashFolder)
        let harness = try Harness(fileTrash: ThemeFileTrash { url in
            tombstonedDuringMove.withLock { $0 = probe.isTombstoned() }
            return try folder.moveToTrash(url)
        })
        defer { harness.remove() }
        let night = try Self.theme("user.night")
        try harness.write(night)
        harness.reopen()
        probe.watch(harness.tracker, category: Self.category(night.id))

        try harness.catalog.trash(id: night.id)

        #expect(tombstonedDuringMove.withLock { $0 } == false)
        #expect(harness.tombstoned == [Self.category(night.id)])
        #expect(!harness.dirty.contains(Self.category(night.id)))
        #expect(try harness.fileNames().isEmpty)
    }

    @Test("Putting a trashed theme back marks its record dirty again")
    func restoreMarksDirty() throws {
        let harness = try Harness()
        defer { harness.remove() }
        let night = try Self.theme("user.night")
        try harness.write(night)
        harness.reopen()

        let receipt = try harness.catalog.trash(id: night.id)
        #expect(receipt.themeId == night.id)
        try harness.catalog.restore(receipt)

        #expect(harness.catalog.theme(id: night.id) != nil)
        #expect(harness.dirty == [Self.category(night.id)])
    }

    @Test("A file that failed to load moves to the Trash and back with no sync mark")
    func rejectedFileTrashAndRestore() throws {
        let harness = try Harness()
        defer { harness.remove() }
        let broken = harness.themes.appendingPathComponent("broken.json")
        try Data("{ not json".utf8).write(to: broken)
        harness.reopen()
        let path = try #require(harness.catalog.rejected.first?.path)

        let receipt = try harness.catalog.trashRejected(path: path)
        #expect(receipt.themeId == nil)
        #expect(receipt.originalURL.lastPathComponent == broken.lastPathComponent)
        #expect(!FileManager.default.fileExists(atPath: broken.path))
        #expect(harness.catalog.rejected.isEmpty)
        #expect(try harness.fileNames().isEmpty)

        try harness.catalog.restore(receipt)
        #expect(harness.catalog.rejected.map(\.fileName) == ["broken.json"])
        #expect(harness.dirty.isEmpty)
        #expect(harness.tombstoned.isEmpty)
    }

    @Test("Trashing a path that is not a failed file is refused")
    func trashRejectedRefusesUnknownPath() throws {
        let harness = try Harness()
        defer { harness.remove() }
        let loaded = try harness.write(try Self.theme("user.loaded"))
        harness.reopen()

        #expect(throws: CocoaError.self) { try harness.catalog.trashRejected(path: loaded.path) }
        #expect(try harness.fileNames() == ["user.loaded.json"])
    }

    // MARK: - Remote apply

    @Test("A synced theme is written as its canonical file, joins the list and marks nothing")
    func remoteThemeIsWrittenUnmarked() throws {
        let harness = try Harness()
        defer { harness.remove() }
        let synced = try Self.theme("user.synced", name: "From the other Mac")
        let payload = try ThemeFileFormat.encode(synced)

        let outcome = harness.catalog.applyRemote(category: Self.category(synced.id), data: payload)

        #expect(outcome == .applied)
        #expect(harness.catalog.theme(id: synced.id) == synced)
        #expect(try Data(contentsOf: harness.themes.appendingPathComponent("user.synced.json")) == payload)
        #expect(harness.dirty.isEmpty)
        #expect(harness.catalog.syncPayload(forCategory: Self.category(synced.id)) == payload)
    }

    @Test("A synced copy of the file already on disk writes nothing")
    func identicalRemoteThemeIsSkipped() throws {
        let harness = try Harness()
        defer { harness.remove() }
        let night = try Self.theme("user.night")
        let url = try harness.write(night)
        harness.reopen()
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        let outcome = harness.catalog.applyRemote(category: Self.category(night.id), data: try ThemeFileFormat.encode(night))

        #expect(outcome == .skipped)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == before)
    }

    @Test("A synced edit replaces the theme in the file it was loaded from")
    func remoteEditUsesTheExistingFile() throws {
        let harness = try Harness()
        defer { harness.remove() }
        let night = try Self.theme("user.night")
        try harness.write(night, as: "My Night.json")
        harness.reopen()

        let edited = try Self.theme("user.night", name: "Edited elsewhere", background: "#202020")
        let outcome = harness.catalog.applyRemote(category: Self.category(night.id), data: try ThemeFileFormat.encode(edited))

        #expect(outcome == .applied)
        #expect(try harness.fileNames() == ["My Night.json"])
        #expect(harness.catalog.theme(id: night.id) == edited)
    }

    @Test("While the local file may be unsynced, a differing record keeps the local version as its own theme")
    func keepBothSavesTheLocalVersionAsANewTheme() throws {
        let harness = try Harness()
        defer { harness.remove() }
        let local = try Self.theme("user.x", name: "Ocean", background: "#101010")
        try harness.write(local, as: "Ocean.json")
        harness.reopen()

        let incoming = try Self.theme("user.x", name: "Ocean", background: "#202020")
        let payload = try ThemeFileFormat.encode(incoming)
        let outcome = harness.catalog.applyRemote(category: Self.category(incoming.id), data: payload, merge: .keepBoth)

        #expect(outcome == .applied)
        #expect(harness.catalog.storedTheme(id: incoming.id) == incoming)
        #expect(try Data(contentsOf: harness.themes.appendingPathComponent("Ocean.json")) == payload)
        let kept = try #require(harness.catalog.themes.first { !$0.isBuiltIn && $0.id != incoming.id })
        #expect(kept.id.hasPrefix(ThemeDefinition.userPrefix))
        #expect(kept.name == "Ocean 2")
        #expect(kept.overrides == local.overrides)
        #expect(harness.catalog.storedTheme(id: kept.id) == kept)
        #expect(try harness.fileNames().count == 2)
        #expect(harness.dirty == [Self.category(kept.id)])

        #expect(harness.catalog.applyRemote(category: Self.category(incoming.id), data: payload, merge: .keepBoth) == .skipped)
        #expect(try harness.fileNames().count == 2)
    }

    @Test("A kept copy keeps its name when the record arrives under another name")
    func keptCopyKeepsAFreeName() throws {
        let harness = try Harness()
        defer { harness.remove() }
        try harness.write(try Self.theme("user.x", name: "Ocean", background: "#101010"))
        harness.reopen()

        let incoming = try Self.theme("user.x", name: "Sea", background: "#202020")
        let payload = try ThemeFileFormat.encode(incoming)
        #expect(harness.catalog.applyRemote(category: Self.category(incoming.id), data: payload, merge: .keepBoth) == .applied)

        let names = Set(harness.catalog.themes.filter { !$0.isBuiltIn }.map(\.name))
        #expect(names == ["Ocean", "Sea"])
    }

    @Test("Keep both makes no copy of a local file that holds the same theme in other bytes")
    func keepBothSkipsAnEqualTheme() throws {
        let harness = try Harness()
        defer { harness.remove() }
        let night = try Self.theme("user.night")
        let reformatted = try JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: try ThemeFileFormat.encode(night))
        )
        try reformatted.write(to: harness.themes.appendingPathComponent("user.night.json"))
        harness.reopen()

        let payload = try ThemeFileFormat.encode(night)
        #expect(payload != reformatted)
        #expect(harness.catalog.applyRemote(category: Self.category(night.id), data: payload, merge: .keepBoth) == .applied)

        #expect(try harness.fileNames() == ["user.night.json"])
        #expect(harness.dirty.isEmpty)
    }

    @Test("A record that cannot land takes its kept copy with it, so a replay makes no second copy")
    func keepBothRollsBackOnAFailedWrite() throws {
        let harness = try Harness()
        defer { harness.remove() }
        let local = try Self.theme("user.x", background: "#101010")
        let url = try harness.write(local)
        harness.reopen()
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path) }

        let incoming = try Self.theme("user.x", background: "#202020")
        let payload = try ThemeFileFormat.encode(incoming)
        #expect(harness.catalog.applyRemote(category: Self.category(incoming.id), data: payload, merge: .keepBoth) == .failed)

        #expect(try harness.fileNames() == ["user.x.json"])
        #expect(harness.catalog.themes.filter { !$0.isBuiltIn } == [local])
        #expect(harness.dirty.isEmpty)
    }

    @Test("A synced theme never lands on a file that failed to load")
    func remoteThemeSparesARejectedFile() throws {
        let harness = try Harness()
        defer { harness.remove() }
        let blocking = harness.themes.appendingPathComponent("user.synced.json")
        let brokenBytes = Data("{ \"schema\": 3, broken".utf8)
        try brokenBytes.write(to: blocking)
        harness.reopen()

        let synced = try Self.theme("user.synced")
        let outcome = harness.catalog.applyRemote(category: Self.category(synced.id), data: try ThemeFileFormat.encode(synced))

        #expect(outcome == .applied)
        #expect(try Data(contentsOf: blocking) == brokenBytes)
        #expect(try harness.fileNames() == ["user.synced-2.json", "user.synced.json"])
        #expect(harness.catalog.theme(id: synced.id) == synced)
    }

    @Test("A disk failure is reported as failed, so the pull is not acknowledged")
    func diskFailureIsFailed() throws {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThemeCatalogSyncTests-blocker-\(UUID().uuidString)")
        #expect(FileManager.default.createFile(atPath: blocker.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: blocker) }
        let harness = try Harness(userDirectory: blocker.appendingPathComponent("Themes", isDirectory: true))
        defer { harness.remove() }
        let synced = try Self.theme("user.synced")

        let outcome = harness.catalog.applyRemote(category: Self.category(synced.id), data: try ThemeFileFormat.encode(synced))

        #expect(outcome == .failed)
        #expect(harness.catalog.theme(id: synced.id) == nil)
    }

    struct Rejection: CustomTestStringConvertible, Sendable {
        let label: String
        let category: String
        let payload: @Sendable () throws -> Data
        var testDescription: String { label }
    }

    nonisolated static let rejections: [Rejection] = [
        Rejection(label: "not a theme category", category: "columnLayout.user.a") {
            try ThemeFileFormat.encode(try theme("user.a"))
        },
        Rejection(label: "id with a path separator", category: "theme.user/../a") {
            Data(#"{"schema":3,"id":"user/../a","name":"a","appearance":"dark"}"#.utf8)
        },
        Rejection(label: "built-in id", category: "theme.tablepro.dracula") {
            Data(#"{"schema":3,"id":"tablepro.dracula","name":"Fake","appearance":"dark"}"#.utf8)
        },
        Rejection(label: "id past the length cap", category: "theme.user." + String(repeating: "a", count: 124)) {
            let id = "user." + String(repeating: "a", count: 124)
            return Data(#"{"schema":3,"id":"\#(id)","name":"Long","appearance":"dark"}"#.utf8)
        },
        Rejection(label: "document for another id", category: "theme.user.a") {
            try ThemeFileFormat.encode(try theme("user.b"))
        },
        Rejection(label: "payload past the size cap", category: "theme.user.a") {
            let body = #"{"schema":3,"id":"user.a","name":"a","appearance":"dark"}"#
            return Data((body + String(repeating: " ", count: ThemeCatalog.maximumSyncPayloadSize)).utf8)
        },
        Rejection(label: "payload nested past the depth cap", category: "theme.user.a") {
            Data(##"{"schema":3,"id":"user.a","name":"a","appearance":"dark","editor":{"a":{"b":{"c":{"d":"#000000"}}}}}"##.utf8)
        },
        Rejection(label: "newer format", category: "theme.user.a") {
            Data(#"{"schema":\#(ThemeSchema.current + 1),"id":"user.a","name":"a","appearance":"dark"}"#.utf8)
        },
        Rejection(label: "unknown key", category: "theme.user.a") {
            Data(#"{"schema":3,"id":"user.a","name":"a","appearance":"dark","script":"run"}"#.utf8)
        },
        Rejection(label: "name with a newline", category: "theme.user.a") {
            Data(#"{"schema":3,"id":"user.a","name":"line\nbreak","appearance":"dark"}"#.utf8)
        },
        Rejection(label: "name past the length cap", category: "theme.user.a") {
            let name = String(repeating: "n", count: ThemeFileFormat.maximumTextLength + 1)
            return Data(#"{"schema":3,"id":"user.a","name":"\#(name)","appearance":"dark"}"#.utf8)
        },
        Rejection(label: "not JSON", category: "theme.user.a") {
            Data("not json".utf8)
        },
    ]

    @Test("A synced record that fails validation is skipped and leaves the disk alone", arguments: rejections)
    func invalidRemoteThemeIsSkipped(_ rejection: Rejection) throws {
        let harness = try Harness()
        defer { harness.remove() }

        let outcome = harness.catalog.applyRemote(category: rejection.category, data: try rejection.payload())

        #expect(outcome == .skipped)
        #expect(try harness.fileNames().isEmpty)
        #expect(!harness.catalog.themes.contains { !$0.isBuiltIn })
        #expect(harness.dirty.isEmpty)
    }

    @Test("A synced edit of a theme removed in Finder brings it back, since only a deletion record removes it")
    func remoteEditAfterAFinderDelete() throws {
        let harness = try Harness()
        defer { harness.remove() }
        let night = try Self.theme("user.night")
        let url = try harness.write(night)
        harness.reopen()
        try FileManager.default.removeItem(at: url)
        harness.catalog.reloadSynchronously()

        let edited = try Self.theme("user.night", background: "#303030")
        let payload = try ThemeFileFormat.encode(edited)
        #expect(harness.catalog.applyRemote(category: Self.category(night.id), data: payload) == .applied)

        #expect(harness.catalog.theme(id: night.id) == edited)
        var local = edited
        local.name = "Edited here"
        try harness.catalog.save(local)
    }

    // MARK: - Remote deletion

    @Test("A theme deleted on another Mac goes to this Mac's Trash with its pending mark and no tombstone")
    func remoteDeletionTrashesWithoutSync() throws {
        let harness = try Harness()
        defer { harness.remove() }
        let night = try Self.theme("user.night")
        try harness.catalog.save(night)
        #expect(harness.dirty == [Self.category(night.id)])

        #expect(harness.catalog.removeWithoutSync(ids: [night.id, "user.unknown"]))

        #expect(harness.catalog.theme(id: night.id) == nil)
        #expect(try harness.fileNames().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: harness.trash.path).count == 1)
        #expect(harness.dirty.isEmpty)
        #expect(harness.tombstoned.isEmpty)
    }

    @Test("A remote deletion leaves alone a file that was replaced by another theme since it loaded")
    func remoteDeletionSparesAReplacedFile() throws {
        let harness = try Harness()
        defer { harness.remove() }
        let night = try Self.theme("user.night")
        try harness.catalog.save(night)
        let replacement = try Self.theme("user.dawn", name: "Dawn", background: "#202020")
        try harness.write(replacement, as: "user.night.json")

        #expect(harness.catalog.removeWithoutSync(ids: [night.id]))

        #expect(try harness.fileNames() == ["user.night.json"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: harness.trash.path).isEmpty)
        #expect(harness.catalog.theme(id: replacement.id) == replacement)
    }

    @Test("An editor saving a theme another Mac deleted does not bring it back")
    func saveAfterRemoteDeletionIsRefused() throws {
        let harness = try Harness()
        defer { harness.remove() }
        let night = try Self.theme("user.night")
        try harness.catalog.save(night)
        harness.catalog.removeWithoutSync(ids: [night.id])

        #expect(throws: ThemeLoadError.self) { try harness.catalog.save(night) }
        #expect(try harness.fileNames().isEmpty)
    }

    // MARK: - Payload

    @Test("Only a user theme on disk has a sync payload")
    func payloadOnlyForUserThemes() throws {
        let harness = try Harness()
        defer { harness.remove() }
        let night = try Self.theme("user.night")
        try harness.catalog.save(night)

        let canonical = try ThemeFileFormat.encode(night)
        #expect(harness.catalog.syncPayload(forCategory: Self.category(night.id)) == canonical)
        #expect(harness.catalog.syncPayload(forCategory: Self.category(BuiltInThemes.defaultDarkId)) == nil)
        #expect(harness.catalog.syncPayload(forCategory: Self.category("user.missing")) == nil)
        #expect(harness.catalog.syncPayload(forCategory: "appearance") == nil)
        #expect(harness.catalog.syncCategories == [Self.category(night.id)])
    }

    // MARK: - Names

    @Test("Two themes with one name show apart in the list, while their files and records keep the name")
    func collidingNamesAreToldApart() throws {
        let harness = try Harness()
        defer { harness.remove() }
        let first = try Self.theme("user.a", name: "Ocean")
        let second = try Self.theme("user.b", name: "Ocean")
        let builtInName = try Self.theme("user.c", name: BuiltInThemes.dark.name.uppercased())
        try harness.write(first)
        try harness.write(second)
        try harness.write(builtInName)
        harness.reopen()

        #expect(harness.catalog.theme(id: first.id)?.name == "Ocean")
        #expect(harness.catalog.theme(id: second.id)?.name == "Ocean 2")
        #expect(harness.catalog.theme(id: builtInName.id)?.name == "\(BuiltInThemes.dark.name.uppercased()) 2")
        #expect(harness.catalog.theme(id: BuiltInThemes.defaultDarkId)?.name == BuiltInThemes.dark.name)
        #expect(harness.catalog.storedTheme(id: second.id) == second)

        let payload = try #require(harness.catalog.syncPayload(forCategory: Self.category(second.id)))
        #expect(try ThemeFileFormat.decode(payload).name == "Ocean")
        let onDisk = try Data(contentsOf: harness.themes.appendingPathComponent("user.b.json"))
        #expect(try ThemeFileFormat.decode(onDisk).name == "Ocean")
        #expect(harness.dirty.isEmpty)
    }

    @Test("A synced theme that takes a local theme's name shows apart without a write")
    func syncedNameCollision() throws {
        let harness = try Harness()
        defer { harness.remove() }
        try harness.write(try Self.theme("user.local", name: "Ocean"))
        harness.reopen()

        let synced = try Self.theme("user.synced", name: "Ocean")
        let payload = try ThemeFileFormat.encode(synced)
        #expect(harness.catalog.applyRemote(category: Self.category(synced.id), data: payload) == .applied)

        let names = harness.catalog.themes.filter { !$0.isBuiltIn }.map(\.name)
        #expect(names == ["Ocean", "Ocean 2"])
        #expect(harness.dirty.isEmpty)
    }

    // MARK: - Trash location

    @Test("A sandboxed run trashes themes inside its sandbox, never into the user's Trash")
    func defaultTrashStaysInTheSandbox() throws {
        let environment = AppStorageEnvironment.shared
        let sandboxTrash = try #require(environment.trashDirectory)
        #expect(sandboxTrash.path.hasPrefix(environment.supportDirectory.path))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThemeCatalogSyncTests-default-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Themes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = try EphemeralDefaults()
        let night = try Self.theme("user.night")
        try ThemeFileFormat.encode(night).write(to: folder.appendingPathComponent("user.night.json"))
        let catalog = ThemeCatalog(
            userDirectory: folder,
            bundleDirectory: nil,
            notificationCenter: NotificationCenter(),
            syncTracker: SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: suite.defaults))
        )

        let receipt = try catalog.trash(id: night.id)
        defer { try? FileManager.default.removeItem(at: receipt.trashedURL.deletingLastPathComponent()) }

        #expect(receipt.trashedURL.standardizedFileURL.path.hasPrefix(sandboxTrash.standardizedFileURL.path))
        #expect(FileManager.default.fileExists(atPath: receipt.trashedURL.path))
        try catalog.restore(receipt)
        #expect(catalog.theme(id: night.id) == night)
    }
}

// Reads the tracker from inside the trash closure, which runs off the main actor's bookkeeping.
private final class TrackerProbe: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<(SyncChangeTracker, String)?>(initialState: nil)

    func watch(_ tracker: SyncChangeTracker, category: String) {
        state.withLock { $0 = (tracker, category) }
    }

    func isTombstoned() -> Bool? {
        guard let (tracker, category) = state.withLock({ $0 }) else { return nil }
        return tracker.tombstonedIds(for: .settings).contains(category)
    }
}
