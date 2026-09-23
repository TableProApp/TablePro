//
//  LoadableExtensionListModel.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct LoadableExtensionRow: Identifiable, Equatable {
    let id: UUID
    var path: String
    var entryPoint: String

    init(id: UUID = UUID(), path: String, entryPoint: String = "") {
        self.id = id
        self.path = path
        self.entryPoint = entryPoint
    }
}

/// The rows of the Extensions list in the connection form, kept apart from the view so adding,
/// removing, reordering and the stored value can be tested without AppKit.
struct LoadableExtensionListModel: Equatable {
    private(set) var rows: [LoadableExtensionRow]
    private(set) var isUnreadable: Bool

    init(encoded: String) {
        do {
            rows = try LoadableExtensionList.decode(encoded).map {
                LoadableExtensionRow(path: $0.path, entryPoint: $0.entryPoint ?? "")
            }
            isUnreadable = false
        } catch {
            rows = []
            isUnreadable = true
        }
    }

    var extensions: [LoadableExtension] {
        rows
            .map { LoadableExtension(path: $0.path, entryPoint: $0.entryPoint) }
            .filter { !$0.path.isEmpty }
    }

    var encoded: String {
        LoadableExtensionList.encode(extensions)
    }

    func matches(encoded: String) -> Bool {
        (try? LoadableExtensionList.decode(encoded)) == extensions
    }

    /// Appends the chosen files and answers the rows to select. A file already in the list with the
    /// default entry point is selected rather than added twice, since loading it twice fails.
    mutating func add(paths: [String]) -> Set<UUID> {
        var selection = Set<UUID>()
        for path in paths {
            let candidate = LoadableExtension(path: path)
            if let existing = rows.first(where: { LoadableExtension(path: $0.path, entryPoint: $0.entryPoint) == candidate }) {
                selection.insert(existing.id)
                continue
            }
            let row = LoadableExtensionRow(path: candidate.path)
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

    mutating func setPath(_ path: String, for id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].path = path
    }

    mutating func setEntryPoint(_ entryPoint: String, for id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].entryPoint = entryPoint
    }
}

/// What is wrong with a row's file as far as the form can tell without loading it. Loading is
/// what runs the file's code, so the form only ever looks at it, and only at its first bytes: the
/// code signature check hashes the whole file and waits for the connect.
enum LoadableExtensionFileIssue: Equatable {
    case notFullPath
    case missing
    case notALibrary

    var message: String {
        switch self {
        case .notFullPath:
            return String(localized: "Not a full path. Use a path that starts with / or ~.")
        case .missing:
            return String(localized: "No file at this path.")
        case .notALibrary:
            return String(localized: "This file is not a library.")
        }
    }

    static func issue(forPath path: String, fileManager: FileManager = .default) -> LoadableExtensionFileIssue? {
        let item = LoadableExtension(path: path)
        guard !item.path.isEmpty else { return nil }
        guard item.expandedPath.hasPrefix("/") else { return .notFullPath }
        for file in [item.expandedPath, item.expandedPath + ".dylib"] {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: file, isDirectory: &isDirectory) else { continue }
            return !isDirectory.boolValue && MachOFile.isMachO(atPath: file) ? nil : .notALibrary
        }
        return .missing
    }
}

enum MachOFile {
    private static let magics: [[UInt8]] = [
        [0xCF, 0xFA, 0xED, 0xFE],
        [0xCE, 0xFA, 0xED, 0xFE],
        [0xCA, 0xFE, 0xBA, 0xBE],
        [0xCA, 0xFE, 0xBA, 0xBF]
    ]

    static func isMachO(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4) else { return false }
        return magics.contains(Array(header))
    }
}
