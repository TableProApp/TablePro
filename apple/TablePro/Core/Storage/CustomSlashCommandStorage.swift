//
//  CustomSlashCommandStorage.swift
//  TablePro
//

import Combine
import Foundation
import TableProSyncTransport

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
final class CustomSlashCommandStorage: ObservableObject {
    static let shared = CustomSlashCommandStorage()

    nonisolated static let syncCategory = "customSlashCommands"

    private static let defaultsKey = JSONDefaultsKey<[CustomSlashCommand]>("ai.customSlashCommands.v1")
    private let defaults: UserDefaults
    private let syncJournal: SyncHostJournal

    @Published private(set) var commands: [CustomSlashCommand] = []

    init(defaults: UserDefaults = AppStorageEnvironment.shared.defaults, syncJournal: SyncHostJournal = .shared) {
        self.defaults = defaults
        self.syncJournal = syncJournal
        self.commands = Self.load(from: defaults)
    }

    func applyRemote(_ commands: [CustomSlashCommand]) {
        self.commands = commands
        persist(markDirty: false)
    }

    // Two Macs can each add a command under one name before they sync, and a name picks one command, so a later one takes a free name.
    nonisolated static func renamingCollisions(_ commands: [CustomSlashCommand]) -> [CustomSlashCommand] {
        var kept: [CustomSlashCommand] = []
        for command in commands {
            var named = command
            var suffix = 2
            while kept.contains(where: { $0.name.caseInsensitiveCompare(named.name) == .orderedSame }) {
                named.name = "\(command.name)-\(suffix)"
                suffix += 1
            }
            kept.append(named)
        }
        return kept
    }

    // An empty list once saved is a choice, unlike a list never saved.
    var holdsValue: Bool {
        defaults.object(forKey: Self.defaultsKey.name) != nil
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
            try defaults.write(commands, to: Self.defaultsKey)
        } catch {
            return
        }
        if markDirty {
            syncJournal.recorded(.settings, written: [Self.syncCategory])
        }
    }

    private static func load(from defaults: UserDefaults) -> [CustomSlashCommand] {
        defaults.read(Self.defaultsKey).value ?? []
    }
}
