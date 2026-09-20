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
        struct DroppedContainer: Equatable {
            let connectionId: UUID
            let database: String
            let schema: String?
        }

        private(set) var purgedConnectionIds: [Set<UUID>] = []
        private(set) var purgedTombstoneFlags: [Bool] = []
        private(set) var droppedTables: [TableScope] = []
        private(set) var droppedContainers: [DroppedContainer] = []

        func renameTable(from oldScope: TableScope, to newScope: TableScope) {}

        func renameContainer(
            connectionId: UUID,
            fromDatabase: String,
            fromSchema: String?,
            toDatabase: String,
            toSchema: String?
        ) {}

        func dropTable(_ scope: TableScope) {
            droppedTables.append(scope)
        }

        func dropContainer(connectionId: UUID, database: String, schema: String?) {
            droppedContainers.append(DroppedContainer(connectionId: connectionId, database: database, schema: schema))
        }

        func purgeConnections(_ connectionIds: Set<UUID>, leavesTombstones: Bool) {
            purgedConnectionIds.append(connectionIds)
            purgedTombstoneFlags.append(leavesTombstones)
        }
    }

    @Test("Deleting a connection purges every table-scoped store once with every id")
    func connectionPurgeReachesEveryStore() {
        let first = RecordingStore()
        let second = RecordingStore()
        let deleted: Set<UUID> = [UUID(), UUID()]

        ConnectionLocalState.purge(
            connectionIds: deleted,
            origin: .remote,
            tableScopedStores: [first, second],
            queryHistory: Self.isolatedQueryHistory()
        )

        #expect(first.purgedConnectionIds == [deleted])
        #expect(second.purgedConnectionIds == [deleted])
    }

    /// A synced store must not tombstone what another device already deleted, or it sends that
    /// device's own deletion back at it.
    @Test("A remote delete purges every store without leaving tombstones")
    func remotePurgeLeavesNoTombstones() {
        let store = RecordingStore()

        ConnectionLocalState.purge(
            connectionIds: [UUID()],
            origin: .remote,
            tableScopedStores: [store],
            queryHistory: Self.isolatedQueryHistory()
        )

        #expect(store.purgedTombstoneFlags == [false])
    }

    @Test("A local delete purges every store and leaves tombstones")
    func localPurgeLeavesTombstones() {
        let store = RecordingStore()

        ConnectionLocalState.purge(
            connectionIds: [UUID()],
            origin: .local,
            tableScopedStores: [store],
            queryHistory: Self.isolatedQueryHistory()
        )

        #expect(store.purgedTombstoneFlags == [true])
    }

    @Test("An empty delete purges nothing")
    func emptyPurgeReachesNoStore() {
        let store = RecordingStore()

        ConnectionLocalState.purge(
            connectionIds: [],
            origin: .remote,
            tableScopedStores: [store],
            queryHistory: Self.isolatedQueryHistory()
        )

        #expect(store.purgedConnectionIds.isEmpty)
    }

    /// Every type that persists state keyed by a connection and a database must either conform to
    /// `TableScopedSettingsStore`, so the rename, drop and purge hooks reach it, or be named here
    /// with a reason.
    ///
    /// The list is the point. The previous version looked for three sentinel type names inside one
    /// directory, so `FavoriteTablesStorage`, whose key is its own `FavoriteEntry` struct, was
    /// invisible to it, and a dropped table went on leaving its star behind with nothing failing.
    /// A store is found by the shape of its key now, so one that invents a fourth key type is still
    /// seen, and an exemption is a line in a diff someone has to justify.
    private static let exemptStoreTypes: [String: String] = [
        "FavoriteTablesStorage": """
        Its lifecycle turns on the local-or-remote origin that TableScopedSettingsStore does not         carry, so ConnectionLocalState and CatalogEditAdoption drive it by name.
        """,
        "FavoriteDatabasesStorage": """
        Keyed by connection and database with no table, and origin-sensitive like its sibling, so         it is driven by name from the same two places.
        """,
    ]

    @Test("Every store keyed by a connection and a database conforms, or is a named exception")
    func everyConnectionScopedStoreIsRegisteredOrExempt() throws {
        let app = try Self.repoRoot().appendingPathComponent("TablePro", isDirectory: true)
        let sources = try Self.swiftSources(under: app)
        let registry = try String(
            contentsOf: app.appendingPathComponent("Core/Storage/TableScopedSettingsStore.swift"),
            encoding: .utf8
        )

        let keyTypes = Set(sources.flatMap(Self.connectionScopedKeyTypes(in:)))
        #expect(keyTypes.isSuperset(of: ["TableScope", "FavoriteEntry", "FavoriteDatabaseEntry"]))

        let storeTypes = Set(sources.flatMap { Self.storesSpeaking(keyTypes, in: $0) })
            .subtracting(Self.exemptStoreTypes.keys)
        #expect(storeTypes.isSuperset(of: [
            "FilterSettingsStorage",
            "FileColumnLayoutPersister",
            "HighlightRuleStorage",
            "ValueDisplayFormatStorage",
            "ForeignKeyLabelColumnStore"
        ]))

        let conformance = try NSRegularExpression(
            pattern: #"\b(?:class|extension)\s+([A-Z]\w*)\s*:[^{]*\bTableScopedSettingsStore\b"#
        )
        let conforming = Set(sources.flatMap { Self.captures(conformance, in: $0) })

        let unconformed = storeTypes.subtracting(conforming)
        #expect(
            unconformed.isEmpty,
            """
            A store keyed by a connection and a database conforms to TableScopedSettingsStore,             or is listed in exemptStoreTypes with a reason: \(unconformed.sorted())
            """
        )
        let unregistered = storeTypes.filter { !registry.contains("\($0).shared") }
        #expect(
            unregistered.isEmpty,
            "A table-scoped store must be listed in TableScopedSettingsRegistry.stores: \(unregistered.sorted())"
        )
    }

    /// An exemption naming a type that no longer exists reads as a decision someone made about code
    /// that has since moved, which is worse than no exemption at all.
    @Test("Every exemption still names a store the scan finds")
    func everyExemptionNamesAStoreTheScanFinds() throws {
        let app = try Self.repoRoot().appendingPathComponent("TablePro", isDirectory: true)
        let sources = try Self.swiftSources(under: app)
        let keyTypes = Set(sources.flatMap(Self.connectionScopedKeyTypes(in:)))
        let detected = Set(sources.flatMap { Self.storesSpeaking(keyTypes, in: $0) })

        let stale = Self.exemptStoreTypes.keys.filter { !detected.contains($0) }
        #expect(stale.isEmpty, "An exemption names a type the scan no longer finds: \(stale.sorted())")
    }

    /// A key carrying both a connection and a database is what makes its owner's data outlive a
    /// rename or a drop of either. The name of the type is deliberately not consulted; the cap on
    /// the property count is what keeps a whole model out of the result.
    private static func connectionScopedKeyTypes(in text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var found: [String] = []
        for (index, line) in lines.enumerated() {
            guard line.contains("{"), let name = Self.declaredStructName(in: line) else { continue }
            var depth = line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            var properties: [String] = []
            var cursor = index + 1
            while cursor < lines.count, depth > 0 {
                let body = lines[cursor]
                if depth == 1, let property = Self.declaredPropertyName(in: body) {
                    properties.append(property)
                }
                depth += body.filter { $0 == "{" }.count - body.filter { $0 == "}" }.count
                cursor += 1
            }
            guard properties.count <= 6,
                  properties.contains("connectionId"),
                  properties.contains("database") || properties.contains("databaseName") else { continue }
            found.append(name)
        }
        return found
    }

    /// A type that takes one of those keys in a function signature and writes something somewhere.
    ///
    /// A write rather than a mention of a persistence type, because a view model that reads
    /// `FileManager` to decide what to draw is not a store, and one of them takes a display target
    /// shaped exactly like a storage key.
    private static func storesSpeaking(_ keyTypes: Set<String>, in text: String) -> [String] {
        let writes = [
            ".set(", "setDataValue(", ".write(to:", "removeObject(forKey:",
            "removeValues(withPrefix:", "sqlite3_step",
        ]
        guard writes.contains(where: text.contains) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let speaks = lines.contains { line in
            guard line.contains("func ") else { return false }
            return !Self.identifiers(in: line).isDisjoint(with: keyTypes)
        }
        guard speaks else { return [] }
        return lines.compactMap(Self.declaredClassName(in:))
    }

    /// Whole identifiers only. Matching a key type as a substring made the nested `Key` of one
    /// cache match every `forKey:` parameter in the app, and the scan reported twenty-two stores
    /// that persist nothing table-scoped at all.
    private static func identifiers(in line: String) -> Set<String> {
        Set(
            line.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
                .map(String.init)
        )
    }

    private static func declaredStructName(in line: String) -> String? {
        Self.name(after: "struct ", in: line)
    }

    private static func declaredClassName(in line: String) -> String? {
        guard !line.hasPrefix(" "), !line.hasPrefix("\t") else { return nil }
        return Self.name(after: "class ", in: line)
    }

    private static func name(after keyword: String, in line: String) -> String? {
        guard let range = line.range(of: keyword) else { return nil }
        let name = String(line[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" })
        guard let first = name.first, first.isUppercase else { return nil }
        return name
    }

    private static func declaredPropertyName(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for keyword in ["let ", "var "] {
            guard let range = trimmed.range(of: keyword) else { continue }
            let prefix = trimmed[trimmed.startIndex..<range.lowerBound]
            guard prefix.isEmpty || ["internal ", "public ", "private ", "fileprivate "].contains(String(prefix))
            else { continue }
            let rest = trimmed[range.upperBound...]
            let name = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
            guard !name.isEmpty, rest.dropFirst(name.count).hasPrefix(":") else { continue }
            return name
        }
        return nil
    }

    /// `purge` fires its async stores, so a test that injects `tableScopedStores` to stay off the
    /// real ones has to inject this too, or the unstructured task opens the app's own history
    /// database and runs a delete against it while another test is using it.
    private static func isolatedQueryHistory() -> QueryHistoryManager {
        QueryHistoryManager(
            storage: QueryHistoryStorage(
                databaseURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("tablepro-tests")
                    .appendingPathComponent("registry_\(UUID().uuidString).db"),
                removeDatabaseOnDeinit: true
            ),
            isCapturePaused: { false }
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
