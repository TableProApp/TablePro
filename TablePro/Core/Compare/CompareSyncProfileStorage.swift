//
//  CompareSyncProfileStorage.swift
//  TablePro
//
//  Named comparison setups, keyed by source scope, target scope, and mode.
//
//  The key used to be the pair of connection ids alone, which cannot tell two
//  databases on one server apart. A profile saved under the old key is read back
//  and adopted onto whatever database each connection currently points at, which
//  is the same place it was saved from, so nothing is silently retargeted and
//  nothing is thrown away.
//

import Foundation
import os

internal struct CompareSyncProfile: Codable, Hashable, Identifiable {
    internal var id = UUID()
    internal var name: String
    internal var source: DatabaseScope
    internal var target: DatabaseScope
    internal var mode: CompareSyncMode
    internal var includedKinds: Set<CompareObjectKind>
    internal var structureOptions: StructureCompareOptions
    internal var dataOptions: DataCompareOptions
    internal var selectedObjects: [String]
    internal var tableScopes: [String: DataTableScope]

    /// The compared-column exclusions a profile saved before they became per table. Read so a
    /// saved comparison keeps leaving out the columns it left out, never written back.
    internal var legacyExcludedColumns: Set<String>

    internal init(
        id: UUID = UUID(),
        name: String,
        source: DatabaseScope,
        target: DatabaseScope,
        mode: CompareSyncMode,
        includedKinds: Set<CompareObjectKind> = [.table],
        structureOptions: StructureCompareOptions,
        dataOptions: DataCompareOptions,
        selectedObjects: [String],
        tableScopes: [String: DataTableScope] = [:],
        legacyExcludedColumns: Set<String> = []
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.target = target
        self.mode = mode
        self.includedKinds = includedKinds
        self.structureOptions = structureOptions
        self.dataOptions = dataOptions
        self.selectedObjects = selectedObjects
        self.tableScopes = tableScopes
        self.legacyExcludedColumns = legacyExcludedColumns
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case source
        case target
        case mode
        case includedKinds
        case structureOptions
        case dataOptions
        case selectedObjects
        case tableScopes
    }

    private enum LegacyDataOptionsKeys: String, CodingKey {
        case excludedFromComparison
    }

    internal init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        source = try container.decode(DatabaseScope.self, forKey: .source)
        target = try container.decode(DatabaseScope.self, forKey: .target)
        mode = try container.decode(CompareSyncMode.self, forKey: .mode)
        includedKinds = try container.decodeIfPresent(Set<CompareObjectKind>.self, forKey: .includedKinds) ?? [.table]
        structureOptions = try container.decodeIfPresent(StructureCompareOptions.self, forKey: .structureOptions)
            ?? .default
        dataOptions = try container.decodeIfPresent(DataCompareOptions.self, forKey: .dataOptions) ?? .default
        selectedObjects = try container.decodeIfPresent([String].self, forKey: .selectedObjects) ?? []
        tableScopes = try container.decodeIfPresent([String: DataTableScope].self, forKey: .tableScopes) ?? [:]
        guard container.contains(.dataOptions) else {
            legacyExcludedColumns = []
            return
        }
        let legacy = try container.nestedContainer(keyedBy: LegacyDataOptionsKeys.self, forKey: .dataOptions)
        legacyExcludedColumns = try legacy.decodeIfPresent(Set<String>.self, forKey: .excludedFromComparison) ?? []
    }
}

extension DatabaseScope: Codable {
    private enum CodingKeys: String, CodingKey {
        case connectionId
        case database
        case schema
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            connectionId: try container.decode(UUID.self, forKey: .connectionId),
            database: try container.decodeIfPresent(String.self, forKey: .database) ?? "",
            schema: try container.decodeIfPresent(String.self, forKey: .schema)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(connectionId, forKey: .connectionId)
        try container.encode(database, forKey: .database)
        try container.encodeIfPresent(schema, forKey: .schema)
    }
}

@MainActor
internal final class CompareSyncProfileStorage {
    internal static let shared = CompareSyncProfileStorage()

    private static let logger = Logger(subsystem: "com.TablePro", category: "CompareSyncProfileStorage")
    private static let defaultsKey = "compareSyncProfiles"
    private static let lastSetupKey = "compareSyncLastSetup"

    private let defaults: UserDefaults

    internal init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Last setup

    /// The pair, the mode and the options the window last held, so reopening it lands on the same
    /// comparison rather than on two empty pickers. It carries no included objects: what to change
    /// is a decision about one comparison's results, and re-arming it against a report that has not
    /// run yet would put a stale choice behind an Apply button.
    internal func lastSetup() -> CompareSyncProfile? {
        guard let data = defaults.data(forKey: Self.lastSetupKey) else { return nil }
        do {
            return try JSONDecoder().decode(CompareSyncProfile.self, from: data)
        } catch {
            Self.logger.error("Failed to decode last setup: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    internal func rememberSetup(_ profile: CompareSyncProfile) {
        do {
            defaults.set(try JSONEncoder().encode(profile), forKey: Self.lastSetupKey)
        } catch {
            Self.logger.error("Failed to persist last setup: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Saved comparisons

    internal func allProfiles() -> [CompareSyncProfile] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        do {
            return try JSONDecoder().decode([CompareSyncProfile].self, from: data)
        } catch {
            Self.logger.error("Failed to decode profiles: \(error.localizedDescription, privacy: .public)")
            return migrateLegacyProfiles(from: data)
        }
    }

    internal func save(_ profile: CompareSyncProfile) {
        var profiles = allProfiles()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        persist(profiles)
    }

    internal func delete(_ profile: CompareSyncProfile) {
        persist(allProfiles().filter { $0.id != profile.id })
    }

    private func persist(_ profiles: [CompareSyncProfile]) {
        do {
            defaults.set(try JSONEncoder().encode(profiles), forKey: Self.defaultsKey)
        } catch {
            Self.logger.error("Failed to persist profiles: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A profile written before an endpoint carried a database is adopted onto whichever database
    /// its connections currently point at, which is where it was saved from. Discarding them
    /// instead would lose setups the user had already named.
    private func migrateLegacyProfiles(from data: Data) -> [CompareSyncProfile] {
        guard let legacy = try? JSONDecoder().decode([LegacyProfile].self, from: data) else { return [] }
        let connections = ConnectionStorage.shared.loadConnections()
        let databaseByConnection = Dictionary(
            connections.map { ($0.id, $0.database ?? "") }, uniquingKeysWith: { first, _ in first }
        )
        let migrated = legacy.map { entry in
            CompareSyncProfile(
                id: entry.id,
                name: entry.name,
                source: DatabaseScope(
                    connectionId: entry.sourceConnectionId,
                    database: databaseByConnection[entry.sourceConnectionId] ?? "",
                    schema: nil
                ),
                target: DatabaseScope(
                    connectionId: entry.targetConnectionId,
                    database: databaseByConnection[entry.targetConnectionId] ?? "",
                    schema: nil
                ),
                mode: entry.mode,
                includedKinds: [.table],
                structureOptions: entry.structureOptions,
                dataOptions: entry.dataOptions,
                selectedObjects: entry.selectedTables
            )
        }
        persist(migrated)
        Self.logger.notice("Migrated \(migrated.count, privacy: .public) saved comparisons onto database scopes")
        return migrated
    }

    private struct LegacyProfile: Codable {
        let id: UUID
        let name: String
        let sourceConnectionId: UUID
        let targetConnectionId: UUID
        let mode: CompareSyncMode
        let structureOptions: StructureCompareOptions
        let dataOptions: DataCompareOptions
        let selectedTables: [String]
    }
}
