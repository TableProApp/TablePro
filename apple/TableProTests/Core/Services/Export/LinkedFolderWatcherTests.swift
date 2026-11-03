//
//  LinkedFolderWatcherTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProImport
import TableProTestSupport
import Testing

@MainActor
struct LinkedFolderWatcherTests {
    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("linked-folders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func bundleData(name: String) throws -> Data {
        let settings = ExportableConnection(
            name: name, host: "db.example.com", port: 5_432, database: "app", username: "reader", type: "PostgreSQL"
        )
        return try ConnectionBundleCodec.encode(
            ConnectionBundle(appVersion: "1.0", connections: [BundleConnection(ref: "c1", settings: settings)])
        )
    }

    private func folder(_ url: URL, isEnabled: Bool = true) -> LinkedFolder {
        LinkedFolder(path: url.path, isEnabled: isEnabled)
    }

    @Test("A scan reports connections and unreadable files per folder, and a missing or unreadable folder")
    func scanReportsEachFolder() throws {
        let root = try makeRoot()
        let good = root.appendingPathComponent("good", isDirectory: true)
        let sealed = root.appendingPathComponent("sealed", isDirectory: true)
        let off = root.appendingPathComponent("off", isDirectory: true)
        let locked = good.appendingPathComponent("locked.tablepro")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sealed.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
        for dir in [good, sealed, off] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try bundleData(name: "Shared").write(to: good.appendingPathComponent("shared.tablepro"))
        try Data("not a bundle".utf8).write(to: good.appendingPathComponent("broken.tablepro"))
        try (Data("TPRO".utf8) + Data(repeating: 1, count: 128)).write(to: good.appendingPathComponent("sealed.tablepro"))
        try bundleData(name: "Locked").write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        try Data("ignored".utf8).write(to: good.appendingPathComponent("notes.txt"))
        try bundleData(name: "Off").write(to: off.appendingPathComponent("off.tablepro"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sealed.path)

        let goodFolder = folder(good)
        let missingFolder = folder(root.appendingPathComponent("gone", isDirectory: true))
        let sealedFolder = folder(sealed)
        let offFolder = folder(off, isEnabled: false)

        let scan = LinkedFolderWatcher.scanFolders([goodFolder, missingFolder, sealedFolder, offFolder])

        #expect(scan.contents[goodFolder.id] == .connections(1, unreadableFiles: 3))
        #expect(scan.contents[missingFolder.id] == .missing)
        #expect(scan.contents[sealedFolder.id] == .unreadable)
        #expect(scan.contents[offFolder.id] == nil)
        #expect(scan.connections.map(\.connection.name) == ["Shared"])
    }

    @Test("The watcher publishes each folder's status and whether it is watched")
    func watcherPublishesStatuses() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try bundleData(name: "Shared").write(to: root.appendingPathComponent("shared.tablepro"))
        let present = folder(root)
        let missing = folder(root.appendingPathComponent("gone", isDirectory: true))
        let watcher = LinkedFolderWatcher(loadFolders: { [present, missing] }, isFeatureAvailable: { true })
        defer { watcher.stop() }

        watcher.start()
        try await waitUntil { watcher.folderStatuses.count == 2 }

        #expect(watcher.folderStatuses[present.id] == LinkedFolderStatus(contents: .connections(1, unreadableFiles: 0), isWatched: true))
        #expect(watcher.folderStatuses[missing.id] == LinkedFolderStatus(contents: .missing, isWatched: false))
        #expect(watcher.linkedConnections.count == 1)
    }

    @Test("A scan a reload cancelled never lands over the newer one")
    func cancelledScanDoesNotLand() async throws {
        let kept = LinkedFolder(path: "/nonexistent/kept")
        let removed = LinkedFolder(path: "/nonexistent/removed")
        let state = ScanState(folders: [kept, removed])
        let gate = AsyncGate()
        let watcher = LinkedFolderWatcher(
            loadFolders: { state.folders },
            isFeatureAvailable: { true },
            scan: { folders in
                state.calls += 1
                let isFirst = state.calls == 1
                if isFirst { await gate.wait() }
                var scan = LinkedFolderScan()
                for folder in folders {
                    scan.contents[folder.id] = .connections(0, unreadableFiles: 0)
                }
                if isFirst { state.firstReturned = true }
                return scan
            }
        )
        defer { watcher.stop() }

        watcher.start()
        await gate.arrived(1)
        state.folders = [kept]
        watcher.reload()
        try await waitUntil { Set(watcher.folderStatuses.keys) == [kept.id] }

        await gate.open()
        try await waitUntil { state.firstReturned }

        #expect(Set(watcher.folderStatuses.keys) == [kept.id])
    }

    @Test("The status copy picks singular and plural keys")
    func statusCopyCounts() {
        #expect(LinkedFolderStatusCopy.connections(1) == "1 connection")
        #expect(LinkedFolderStatusCopy.connections(3) == "3 connections")
        #expect(LinkedFolderStatusCopy.unreadableFiles(1) == "1 file couldn't be read")
        #expect(LinkedFolderStatusCopy.unreadableFiles(2) == "2 files couldn't be read")
    }
}

@MainActor
private final class ScanState {
    var folders: [LinkedFolder]
    var calls = 0
    var firstReturned = false

    init(folders: [LinkedFolder]) {
        self.folders = folders
    }
}
