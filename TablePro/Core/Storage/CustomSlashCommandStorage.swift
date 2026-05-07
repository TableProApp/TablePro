//
//  CustomSlashCommandStorage.swift
//  TablePro
//

import Foundation
import Observation
import os

/// UserDefaults-backed store for `CustomSlashCommand`s. Observable so the
/// chat composer's slash menu and the Settings list rerender on edits.
@MainActor
@Observable
final class CustomSlashCommandStorage {
    static let shared = CustomSlashCommandStorage()

    private static let logger = Logger(subsystem: "com.TablePro", category: "CustomSlashCommandStorage")
    private static let defaultsKey = "ai.customSlashCommands.v1"
    private let defaults: UserDefaults

    private(set) var commands: [CustomSlashCommand] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.commands = Self.load(from: defaults)
    }

    func add(_ command: CustomSlashCommand) {
        commands.append(command)
        persist()
    }

    func update(_ command: CustomSlashCommand) {
        guard let idx = commands.firstIndex(where: { $0.id == command.id }) else { return }
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

    private func persist() {
        do {
            let data = try JSONEncoder().encode(commands)
            defaults.set(data, forKey: Self.defaultsKey)
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
