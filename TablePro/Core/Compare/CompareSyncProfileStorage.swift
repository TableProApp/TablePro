//
//  CompareSyncProfileStorage.swift
//  TablePro
//
//  Named comparison setups, keyed by source, target, and mode.
//

import Foundation
import os

internal struct CompareSyncProfile: Codable, Hashable, Identifiable {
    internal var id = UUID()
    internal var name: String
    internal var sourceConnectionId: UUID
    internal var targetConnectionId: UUID
    internal var mode: CompareSyncMode
    internal var structureOptions: StructureCompareOptions
    internal var dataOptions: DataCompareOptions
    internal var selectedTables: [String]

    internal var storageKey: String {
        "\(sourceConnectionId.uuidString)|\(targetConnectionId.uuidString)|\(mode.rawValue)"
    }
}

internal final class CompareSyncProfileStorage: @unchecked Sendable {
    internal static let shared = CompareSyncProfileStorage()

    private static let logger = Logger(subsystem: "com.TablePro", category: "CompareSyncProfileStorage")
    private static let defaultsKey = "compareSyncProfiles"

    private let defaults: UserDefaults

    internal init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    internal func allProfiles() -> [CompareSyncProfile] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        do {
            return try JSONDecoder().decode([CompareSyncProfile].self, from: data)
        } catch {
            Self.logger.error("Failed to decode profiles: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    internal func profiles(source: UUID, target: UUID, mode: CompareSyncMode) -> [CompareSyncProfile] {
        let key = "\(source.uuidString)|\(target.uuidString)|\(mode.rawValue)"
        return allProfiles().filter { $0.storageKey == key }
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
            Self.logger.error("Failed to encode profiles: \(error.localizedDescription, privacy: .public)")
        }
    }
}
