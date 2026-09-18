//
//  TableScopedSettingsRegistryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Table-scoped settings registry")
@MainActor
struct TableScopedSettingsRegistryTests {
    @MainActor
    private final class RecordingStore: TableScopedSettingsStore {
        private(set) var purgedConnectionIds: [Set<UUID>] = []

        func renameTable(from oldScope: TableScope, to newScope: TableScope) {}

        func renameContainer(
            connectionId: UUID,
            fromDatabase: String,
            fromSchema: String?,
            toDatabase: String,
            toSchema: String?
        ) {}

        func purgeConnections(_ connectionIds: Set<UUID>) {
            purgedConnectionIds.append(connectionIds)
        }
    }

    @Test("Deleting a connection purges every table-scoped store once with every id")
    func connectionPurgeReachesEveryStore() {
        let first = RecordingStore()
        let second = RecordingStore()
        let deleted: Set<UUID> = [UUID(), UUID()]

        ConnectionLocalState.purge(connectionIds: deleted, origin: .remote, tableScopedStores: [first, second])

        #expect(first.purgedConnectionIds == [deleted])
        #expect(second.purgedConnectionIds == [deleted])
    }

    @Test("An empty delete purges nothing")
    func emptyPurgeReachesNoStore() {
        let store = RecordingStore()

        ConnectionLocalState.purge(connectionIds: [], origin: .remote, tableScopedStores: [store])

        #expect(store.purgedConnectionIds.isEmpty)
    }

    @Test("Every store keyed by a table scope conforms and is registered")
    func everyTableScopedStoreIsRegistered() throws {
        let root = try Self.repoRoot()
        let storageDirectory = root.appendingPathComponent("TablePro/Core/Storage", isDirectory: true)
        let registry = try String(
            contentsOf: storageDirectory.appendingPathComponent("TableScopedSettingsStore.swift"),
            encoding: .utf8
        )

        let keyUsage = try NSRegularExpression(pattern: #"\b(TableScope|CompositeStorageKey|ColumnLayoutTableKey)\b"#)
        let classDeclaration = try NSRegularExpression(pattern: #"\bclass\s+([A-Z]\w*)"#)
        var storeTypes: Set<String> = []
        for text in try Self.swiftSources(under: storageDirectory) where Self.matches(keyUsage, in: text) {
            storeTypes.formUnion(Self.captures(classDeclaration, in: text))
        }

        let conformance = try NSRegularExpression(
            pattern: #"\b(?:class|extension)\s+([A-Z]\w*)\s*:[^{]*\bTableScopedSettingsStore\b"#
        )
        var conformingTypes: Set<String> = []
        for text in try Self.swiftSources(under: root.appendingPathComponent("TablePro", isDirectory: true)) {
            conformingTypes.formUnion(Self.captures(conformance, in: text))
        }

        #expect(storeTypes.isSuperset(of: [
            "FilterSettingsStorage",
            "FileColumnLayoutPersister",
            "HighlightRuleStorage",
            "ValueDisplayFormatStorage",
            "ForeignKeyLabelColumnStore"
        ]))
        let unconformed = storeTypes.subtracting(conformingTypes)
        #expect(
            unconformed.isEmpty,
            "A store keyed by table scope must conform to TableScopedSettingsStore: \(unconformed.sorted())"
        )
        let unregistered = storeTypes.filter { !registry.contains("\($0).shared") }
        #expect(
            unregistered.isEmpty,
            "A table-scoped store must be listed in TableScopedSettingsRegistry.stores: \(unregistered.sorted())"
        )
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func captures(_ regex: NSRegularExpression, in text: String) -> Set<String> {
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return Set(matches.compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        })
    }

    private static func swiftSources(under directory: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }

        var sources: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            sources.append(try String(contentsOf: url, encoding: .utf8))
        }
        return sources
    }

    private static func repoRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 12 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("TablePro.xcodeproj").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw GuardError.repoRootNotFound
    }

    private enum GuardError: Error {
        case repoRootNotFound
    }
}
