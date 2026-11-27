//
//  CompareSyncProfileStorage.swift
//  TablePro
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

    // Column exclusions saved before they became per table, so an old comparison keeps leaving them out.
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
        case legacyExcludedColumns
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
        // Carried once read: every save rewrites the whole array, and a profile not yet loaded would lose them.
        if let carried = try container.decodeIfPresent(Set<String>.self, forKey: .legacyExcludedColumns) {
            legacyExcludedColumns = carried
            return
        }
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
    private static let profilesKey = JSONDefaultsKey<[CompareSyncProfile]>("compareSyncProfiles")
    // The same entry as written when a profile was keyed by the connection pair alone.
    private static let legacyProfilesKey = JSONDefaultsKey<[LegacyProfile]>("compareSyncProfiles")
    private static let lastSetupKey = JSONDefaultsKey<CompareSyncProfile>("compareSyncLastSetup")

    private let defaults: UserDefaults

    internal init(defaults: UserDefaults = AppStorageEnvironment.shared.defaults) {
        self.defaults = defaults
    }

    // MARK: - Last setup

    // Holds no included objects: re-arming them before the report runs would put a stale choice behind Apply.
    internal func lastSetup() -> CompareSyncProfile? {
        defaults.read(Self.lastSetupKey).value
    }

    internal func rememberSetup(_ profile: CompareSyncProfile) {
        try? defaults.write(profile, to: Self.lastSetupKey)
    }

    // MARK: - Saved comparisons

    internal func allProfiles() -> [CompareSyncProfile] {
        switch defaults.read(Self.profilesKey) {
        case .missing: return []
        case .value(let profiles): return profiles
        case .unreadable: return migrateLegacyProfiles()
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
        try? defaults.write(profiles, to: Self.profilesKey)
    }

    // Adopted onto the database each connection points at now, which is where it was saved from.
    private func migrateLegacyProfiles() -> [CompareSyncProfile] {
        guard let legacy = defaults.read(Self.legacyProfilesKey).value else { return [] }
        let connections = ConnectionStorage.shared.loadConnections()
        let databaseByConnection = Dictionary(
            connections.map { ($0.id, $0.database) }, uniquingKeysWith: { first, _ in first }
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
                selectedObjects: entry.selectedTables,
                legacyExcludedColumns: entry.excludedColumns
            )
        }
        persist(migrated)
        Self.logger.notice("Migrated \(migrated.count, privacy: .public) saved comparisons onto database scopes")
        return migrated
    }

    private struct LegacyProfile: Decodable {
        let id: UUID
        let name: String
        let sourceConnectionId: UUID
        let targetConnectionId: UUID
        let mode: CompareSyncMode
        let structureOptions: StructureCompareOptions
        let dataOptions: DataCompareOptions
        let selectedTables: [String]
        // Stored inside the options, which no longer carry it, so the migration is the last chance to read it.
        let excludedColumns: Set<String>

        private enum CodingKeys: String, CodingKey {
            case id, name, sourceConnectionId, targetConnectionId, mode
            case structureOptions, dataOptions, selectedTables
        }

        private enum LegacyDataOptionsKeys: String, CodingKey {
            case excludedFromComparison
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            sourceConnectionId = try container.decode(UUID.self, forKey: .sourceConnectionId)
            targetConnectionId = try container.decode(UUID.self, forKey: .targetConnectionId)
            mode = try container.decode(CompareSyncMode.self, forKey: .mode)
            structureOptions = try container.decodeIfPresent(
                StructureCompareOptions.self, forKey: .structureOptions
            ) ?? .default
            dataOptions = try container.decodeIfPresent(DataCompareOptions.self, forKey: .dataOptions) ?? .default
            selectedTables = try container.decodeIfPresent([String].self, forKey: .selectedTables) ?? []
            guard container.contains(.dataOptions) else {
                excludedColumns = []
                return
            }
            let legacy = try container.nestedContainer(keyedBy: LegacyDataOptionsKeys.self, forKey: .dataOptions)
            excludedColumns = try legacy.decodeIfPresent(Set<String>.self, forKey: .excludedFromComparison) ?? []
        }
    }
}
