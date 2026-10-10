//
//  ForeignImportTestSupport.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProImport

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
