//
//  ForeignImportTestSupport.swift
//  TableProTests
//

import Foundation
import os
@testable import TablePro
import TableProImport

struct RecordingImporter: ForeignAppImporter {
    final class Calls: Sendable {
        private let log = OSAllocatedUnfairLock<[String]>(initialState: [])

        func record(_ call: String) {
            log.withLock { $0.append(call) }
        }

        func count(of call: String) -> Int {
            log.withLock { recorded in recorded.count { $0 == call } }
        }
    }

    let id: String
    let calls = Calls()

    // Differs from the id, so a test sees which one a caller shows.
    var displayName: String { id.capitalized }
    var symbolName: String { "cylinder" }
    var appBundleIdentifier: String { "test.\(id)" }
    var readsPasswordsFromKeychain: Bool { false }
    var savedQuerySupport: ForeignSavedQuerySupport { .unavailable(reason: "none") }

    func installedAppURL() -> URL? {
        calls.record("installedAppURL")
        return URL(fileURLWithPath: "/Applications/\(id).app")
    }

    func hasDataAtDefaultLocation() -> Bool {
        calls.record("hasDataAtDefaultLocation")
        return false
    }

    func isAvailable() -> Bool {
        calls.record("isAvailable")
        return true
    }

    func inventory() throws -> ForeignAppInventory {
        calls.record("inventory")
        return ForeignAppInventory(connections: 2, savedQueries: 0)
    }

    func collect(_ request: ForeignImportRequest) throws -> CollectedImport {
        calls.record("collect")
        throw CocoaError(.featureUnsupported)
    }
}

extension ForeignImportRequest {
    static let connectionsOnly = ForeignImportRequest(includePasswords: false, includeSavedQueries: false)
    static let withPasswords = ForeignImportRequest(includePasswords: true, includeSavedQueries: false)
    static let withSavedQueries = ForeignImportRequest(includePasswords: false, includeSavedQueries: true)
}

extension CollectedImport {
    var connections: [ExportableConnection] {
        bundle.connections.map(\.settings)
    }

    func credentials(at index: Int) -> ExportableCredentials? {
        guard bundle.connections.indices.contains(index) else { return nil }
        return bundle.credentials[bundle.connections[index].ref]
    }

    func groupPath(at index: Int) -> [String] {
        bundle.groupChain(bundle.connections[index].groupRef).map(\.name)
    }

    func connectionRef(named name: String) -> BundleRef? {
        bundle.connections.first { $0.settings.name == name }?.ref
    }

    func notes(named name: String) -> [String] {
        connectionRef(named: name).flatMap { connectionNotes[$0] } ?? []
    }

    func savedQuery(named name: String) -> BundleSavedQuery? {
        bundle.savedQueries.first { $0.name == name }
    }

    func folderPath(of query: BundleSavedQuery) -> [String] {
        bundle.folderChain(query.folderRef).map(\.name)
    }

    func isSuggested(_ query: BundleSavedQuery) -> Bool {
        !unsuggestedQueries.contains(query.ref)
    }

    var savedQueryNames: Set<String> {
        Set(bundle.savedQueries.map(\.name))
    }
}

enum ForeignFixture {
    static func makeTempDirectory(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }
}
