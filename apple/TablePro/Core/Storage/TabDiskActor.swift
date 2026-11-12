//
//  TabDiskActor.swift
//  TablePro
//

import CryptoKit
import Foundation
import os

internal struct TabDiskState: Codable {
    let tabs: [PersistedTab]
    let selectedTabId: UUID?
    let lastActiveDatabase: String?
    let lastActiveSchema: String?

    init(
        tabs: [PersistedTab],
        selectedTabId: UUID?,
        lastActiveDatabase: String? = nil,
        lastActiveSchema: String? = nil
    ) {
        self.tabs = tabs
        self.selectedTabId = selectedTabId
        self.lastActiveDatabase = lastActiveDatabase
        self.lastActiveSchema = lastActiveSchema
    }

    private enum CodingKeys: String, CodingKey {
        case tabs
        case selectedTabId
        case lastActiveDatabase
        case lastActiveSchema
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try container.decode([LossyTab].self, forKey: .tabs).compactMap(\.value)
        selectedTabId = try container.decodeIfPresent(UUID.self, forKey: .selectedTabId)
        lastActiveDatabase = try container.decodeIfPresent(String.self, forKey: .lastActiveDatabase)
        lastActiveSchema = try container.decodeIfPresent(String.self, forKey: .lastActiveSchema)
    }
}

private struct LossyTab: Decodable {
    let value: PersistedTab?

    init(from decoder: Decoder) throws {
        value = try? PersistedTab(from: decoder)
    }
}

// What this process last wrote or read for one connection, so an unchanged save leaves the disk alone.
internal struct TabDiskWrittenState {
    var stateDigest: SHA256.Digest?
    var sidecars = TabQueryOverflowStore.WrittenSidecars()
}

private final class TabDiskConnectionWriteGate: @unchecked Sendable {
    private let generation = OSAllocatedUnfairLock(initialState: UInt64.zero)
    private let operation = OSAllocatedUnfairLock(initialState: TabDiskWrittenState())

    func issueToken() -> UInt64 {
        generation.withLock { value in
            value &+= 1
            return value
        }
    }

    func performIfCurrent<T>(
        token: UInt64,
        operation work: (inout TabDiskWrittenState) throws -> T
    ) rethrows -> T? {
        try operation.withLockUnchecked { written in
            guard generation.withLock({ $0 == token }) else { return nil }
            return try work(&written)
        }
    }

    func perform<T>(_ work: (inout TabDiskWrittenState) throws -> T) rethrows -> T {
        try operation.withLockUnchecked { written in
            try work(&written)
        }
    }
}

private enum TabDiskWriteGate {
    private static let gates = OSAllocatedUnfairLock(
        initialState: [UUID: TabDiskConnectionWriteGate]()
    )

    static func gate(for connectionId: UUID) -> TabDiskConnectionWriteGate {
        gates.withLock { gates in
            if let gate = gates[connectionId] {
                return gate
            }
            let gate = TabDiskConnectionWriteGate()
            gates[connectionId] = gate
            return gate
        }
    }
}

internal actor TabDiskActor {
    internal static let shared = TabDiskActor()

    private static let logger = Logger(subsystem: "com.TablePro", category: "TabDiskActor")

    // MARK: - Legacy UserDefaults Keys (for migration)

    private static let legacyTabStateKeyPrefix = "com.TablePro.tabs."
    private static let migrationCompleteKey = "com.TablePro.tabStateMigrationComplete"

    // MARK: - File Storage

    private let tabStateDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        let directory = Self.resolvedTabStateDirectory()
        tabStateDirectory = directory
        encoder = Self.makeEncoder()
        decoder = JSONDecoder()

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("Failed to create directory \(directory.path): \(error.localizedDescription)")
        }
        Self.performMigrationIfNeeded(tabStateDirectory: directory)
    }

    // MARK: - Public API

    internal func save(
        connectionId: UUID,
        tabs: [PersistedTab],
        selectedTabId: UUID?,
        lastActiveDatabase: String? = nil,
        lastActiveSchema: String? = nil,
        writeToken: UInt64
    ) throws -> Bool {
        let result = try Self.writeGate(for: connectionId).performIfCurrent(token: writeToken) { written in
            try Self.write(
                tabs: tabs,
                selectedTabId: selectedTabId,
                lastActiveDatabase: lastActiveDatabase,
                lastActiveSchema: lastActiveSchema,
                connectionId: connectionId,
                directory: tabStateDirectory,
                encoder: encoder,
                written: &written
            )
        }
        return result != nil
    }

    // Sorted keys, so a dictionary rebuilt in another order encodes to the same bytes and the unchanged check holds.
    nonisolated private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    // Every save funnels here: the 30 s timer, the draft and tab-switch saves, and quit. Most find nothing new.
    nonisolated private static func write(
        tabs: [PersistedTab],
        selectedTabId: UUID?,
        lastActiveDatabase: String?,
        lastActiveSchema: String?,
        connectionId: UUID,
        directory: URL,
        encoder: JSONEncoder,
        written: inout TabDiskWrittenState
    ) throws {
        let state = TabDiskState(
            tabs: TabQueryOverflowStore.externalize(
                tabs,
                connectionId: connectionId,
                tabStateDirectory: directory,
                written: &written.sidecars
            ),
            selectedTabId: selectedTabId,
            lastActiveDatabase: lastActiveDatabase,
            lastActiveSchema: lastActiveSchema
        )
        let data = try encoder.encode(state)
        let digest = SHA256.hash(data: data)
        let fileURL = directory.appendingPathComponent("\(connectionId.uuidString).json")
        if digest == written.stateDigest, FileManager.default.fileExists(atPath: fileURL.path) {
            return
        }
        try data.write(to: fileURL, options: .atomic)
        written.stateDigest = digest
    }

    internal func load(connectionId: UUID) -> TabDiskState? {
        Self.writeGate(for: connectionId).perform { written in
            let fileURL = tabStateFileURL(for: connectionId)

            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return nil
            }

            do {
                let data = try Data(contentsOf: fileURL)
                let state = try decoder.decode(TabDiskState.self, from: data)
                written.stateDigest = SHA256.hash(data: data)
                return TabDiskState(
                    tabs: TabQueryOverflowStore.inline(
                        state.tabs,
                        tabStateDirectory: tabStateDirectory,
                        written: &written.sidecars
                    ),
                    selectedTabId: state.selectedTabId,
                    lastActiveDatabase: state.lastActiveDatabase,
                    lastActiveSchema: state.lastActiveSchema
                )
            } catch {
                // The file no longer holds what this process wrote, so the next save must write it.
                written = TabDiskWrittenState()
                Self.logger.error("Failed to load tab state for \(connectionId): \(error.localizedDescription)")
                return nil
            }
        }
    }

    internal func clear(connectionId: UUID, writeToken: UInt64) -> Bool {
        let result = Self.writeGate(for: connectionId).performIfCurrent(token: writeToken) { written in
            written = TabDiskWrittenState()
            TabQueryOverflowStore.removeAll(connectionId: connectionId, tabStateDirectory: tabStateDirectory)
            let fileURL = tabStateFileURL(for: connectionId)

            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                Self.logger.error("Failed to clear tab state for \(connectionId): \(error.localizedDescription)")
            }
        }
        return result != nil
    }

    // MARK: - Static Path Helpers

    nonisolated private static func resolvedTabStateDirectory() -> URL {
        let appSupport = AppStorageEnvironment.shared.applicationSupportRoot
        let baseDirectory = appSupport.appendingPathComponent("TablePro", isDirectory: true)
        return baseDirectory.appendingPathComponent("TabState", isDirectory: true)
    }

    nonisolated private static func tabStateFileURL(for connectionId: UUID) -> URL {
        resolvedTabStateDirectory().appendingPathComponent("\(connectionId.uuidString).json")
    }

    nonisolated internal static func issueWriteToken(for connectionId: UUID) -> UInt64 {
        writeGate(for: connectionId).issueToken()
    }

    nonisolated private static func writeGate(for connectionId: UUID) -> TabDiskConnectionWriteGate {
        TabDiskWriteGate.gate(for: connectionId)
    }

    // MARK: - Synchronous Save (quit-time only)

    nonisolated internal static func saveSync(
        connectionId: UUID,
        tabs: [PersistedTab],
        selectedTabId: UUID?,
        lastActiveDatabase: String? = nil,
        lastActiveSchema: String? = nil
    ) {
        let writeToken = issueWriteToken(for: connectionId)
        let directory = resolvedTabStateDirectory()
        do {
            _ = try writeGate(for: connectionId).performIfCurrent(token: writeToken) { written in
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try write(
                    tabs: tabs,
                    selectedTabId: selectedTabId,
                    lastActiveDatabase: lastActiveDatabase,
                    lastActiveSchema: lastActiveSchema,
                    connectionId: connectionId,
                    directory: directory,
                    encoder: makeEncoder(),
                    written: &written
                )
            }
        } catch {
            logger.fault("saveSync failed for \(connectionId): \(error.localizedDescription)")
        }
    }

    nonisolated internal static func clearSync(connectionId: UUID) {
        let writeToken = issueWriteToken(for: connectionId)
        _ = writeGate(for: connectionId).performIfCurrent(token: writeToken) { written in
            written = TabDiskWrittenState()
            TabQueryOverflowStore.removeAll(
                connectionId: connectionId,
                tabStateDirectory: resolvedTabStateDirectory()
            )
            let fileURL = tabStateFileURL(for: connectionId)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                logger.fault("clearSync failed for \(connectionId): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private Helpers

    private func tabStateFileURL(for connectionId: UUID) -> URL {
        tabStateDirectory.appendingPathComponent("\(connectionId.uuidString).json")
    }

    // MARK: - Migration from UserDefaults

    private static func performMigrationIfNeeded(tabStateDirectory: URL) {
        let defaults = AppStorageEnvironment.shared.defaults

        guard !defaults.bool(forKey: migrationCompleteKey) else { return }

        logger.trace("Starting one-time migration of tab state from UserDefaults to file storage")

        var migratedTabStates = 0

        let allKeys = defaults.dictionaryRepresentation().keys
        let tabStateKeys = allKeys.filter { $0.hasPrefix(legacyTabStateKeyPrefix) }

        for key in tabStateKeys {
            let uuidString = String(key.dropFirst(legacyTabStateKeyPrefix.count))
            guard let connectionId = UUID(uuidString: uuidString),
                  let data = defaults.data(forKey: key) else { continue }

            let fileURL = tabStateDirectory.appendingPathComponent("\(connectionId.uuidString).json")
            do {
                try data.write(to: fileURL, options: .atomic)
                defaults.removeObject(forKey: key)
                migratedTabStates += 1
            } catch {
                logger.error("Failed to migrate tab state for \(uuidString): \(error.localizedDescription)")
            }
        }

        defaults.set(true, forKey: migrationCompleteKey)

        if migratedTabStates > 0 {
            logger.trace("Migration complete: \(migratedTabStates) tab states")
        } else {
            logger.trace("Migration complete: no legacy data found")
        }
    }
}
