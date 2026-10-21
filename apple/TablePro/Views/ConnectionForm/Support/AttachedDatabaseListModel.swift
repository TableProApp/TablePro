//
//  AttachedDatabaseListModel.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct AttachedDatabaseRow: Identifiable, Equatable {
    let id: UUID
    var name: String
    var path: String

    init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
}

/// The rows of the Attached Databases list in the connection form, kept apart from the view so adding,
/// removing, renaming and the stored value can be tested without AppKit.
struct AttachedDatabaseListModel: Equatable {
    private(set) var rows: [AttachedDatabaseRow]
    private(set) var isUnreadable: Bool

    init(encoded: String) {
        do {
            rows = try AttachedDatabaseList.decode(encoded).map { AttachedDatabaseRow(name: $0.name, path: $0.path) }
            isUnreadable = false
        } catch {
            rows = []
            isUnreadable = true
        }
    }

    var databases: [AttachedDatabase] {
        rows
            .map { AttachedDatabase(name: $0.name, path: $0.path) }
            .filter { !$0.path.isEmpty }
    }

    var encoded: String {
        AttachedDatabaseList.encode(databases)
    }

    func matches(encoded: String) -> Bool {
        (try? AttachedDatabaseList.decode(encoded)) == databases
    }

    /// Appends the chosen files, each named after its file, and answers the rows to select. A file
    /// already in the list is selected rather than attached a second time.
    mutating func add(paths: [String]) -> Set<UUID> {
        var selection = Set<UUID>()
        for path in paths {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = rows.first(where: { $0.path.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed }) {
                selection.insert(existing.id)
                continue
            }
            let name = AttachedDatabaseList.uniqueName(forPath: trimmed, taken: rows.map(\.name))
            let row = AttachedDatabaseRow(name: name, path: trimmed)
            rows.append(row)
            selection.insert(row.id)
        }
        isUnreadable = false
        return selection
    }

    /// Removes the rows and answers the selection that takes their place, the row that moved into the
    /// first removed position, the way a table keeps a selection after Delete.
    mutating func remove(_ ids: Set<UUID>) -> Set<UUID> {
        let next = ListRemovalSelection.nextSelection(afterRemoving: ids, from: rows.map(\.id))
        rows.removeAll { ids.contains($0.id) }
        return next
    }

    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { rows[$0] }
        var remaining = rows.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertion = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: min(max(insertion, 0), remaining.count))
        rows = remaining
    }

    mutating func setName(_ name: String, for id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].name = name
    }

    mutating func setPath(_ path: String, for id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].path = path
    }
}

/// What is wrong with a row's file as far as the form can tell. A file that is gone is not an error
/// here: the connection still opens and names it, since a file on an unmounted volume comes back.
enum AttachedDatabaseFileIssue: Equatable {
    case notFullPath
    case missing

    var message: String {
        switch self {
        case .notFullPath:
            return String(localized: "Not a full path. Use a path that starts with / or ~.")
        case .missing:
            return String(localized: "No file at this path.")
        }
    }

    static func issue(forPath path: String, fileManager: FileManager = .default) -> AttachedDatabaseFileIssue? {
        let database = AttachedDatabase(name: "", path: path)
        guard !database.path.isEmpty else { return nil }
        guard database.expandedPath.hasPrefix("/") else { return .notFullPath }
        return fileManager.fileExists(atPath: database.expandedPath) ? nil : .missing
    }
}
