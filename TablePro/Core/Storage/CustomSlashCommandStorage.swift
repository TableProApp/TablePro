//
//  CustomSlashCommandStorage.swift
//  TablePro
//

import Foundation
import Observation
import os

enum CustomSlashCommandError: LocalizedError, Equatable {
    case duplicateName(String)

    var errorDescription: String? {
        switch self {
        case .duplicateName(let name):
            return String(
                format: String(localized: "A command named \"/%@\" already exists."),
                name
            )
        }
    }
}

@MainActor
@Observable
final class CustomSlashCommandStorage {
    static let shared = CustomSlashCommandStorage()

    static let syncCategory = "customSlashCommands"

    private static let logger = Logger(subsystem: "com.TablePro", category: "CustomSlashCommandStorage")
    private static let defaultsKey = "ai.customSlashCommands.v1"
    private let defaults: UserDefaults
    private let syncTracker: SyncChangeTracker

    private(set) var commands: [CustomSlashCommand] = []

    init(defaults: UserDefaults = .standard, syncTracker: SyncChangeTracker = .shared) {
        self.defaults = defaults
        self.syncTracker = syncTracker
        self.commands = Self.load(from: defaults)
    }

    /// Replaces all commands from a remote sync without re-marking them dirty.
    func applyRemote(_ commands: [CustomSlashCommand]) {
        self.commands = commands
        persist(markDirty: false)
    }

    func isDuplicate(_ name: String, excluding id: UUID? = nil) -> Bool {
        commands.contains { existing in
            if let id, existing.id == id { return false }
            return existing.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    func add(_ command: CustomSlashCommand) throws {
        if isDuplicate(command.name) {
            throw CustomSlashCommandError.duplicateName(command.name)
        }
        commands.append(command)
        persist()
    }

    func update(_ command: CustomSlashCommand) throws {
        guard let idx = commands.firstIndex(where: { $0.id == command.id }) else { return }
        if isDuplicate(command.name, excluding: command.id) {
            throw CustomSlashCommandError.duplicateName(command.name)
        }
        commands[idx] = command
        persist()
    }

    func delete(id: UUID) {
        commands.removeAll { $0.id == id }
        persist()
    }

    func command(named name: String) -> CustomSlashCommand? {
        commands.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func persist(markDirty: Bool = true) {
        do {
            let data = try JSONEncoder().encode(commands)
            defaults.set(data, forKey: Self.defaultsKey)
            if markDirty {
                syncTracker.markDirty(.settings, id: Self.syncCategory)
            }
        } catch {
            Self.logger.warning("Failed to persist custom slash commands: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load(from defaults: UserDefaults) -> [CustomSlashCommand] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        do {
            return try JSONDecoder().decode([CustomSlashCommand].self, from: data)
        } catch {
            Self.logger.warning("Failed to load custom slash commands: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
