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

    private static let logger = Logger(subsystem: "com.TablePro", category: "CustomSlashCommandStorage")
    private static let defaultsKey = "ai.customSlashCommands.v1"
    private let defaults: UserDefaults

    private(set) var commands: [CustomSlashCommand] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.commands = Self.load(from: defaults)
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
