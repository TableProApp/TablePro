//
//  LinkedFolderCommitDraft.swift
//  TablePro
//

import Foundation

internal struct LinkedFolderCommitEntry: Identifiable, Equatable, Sendable {
    let path: String
    let folderRelativePath: String
    let originalPath: String?
    let status: GitFileStatus

    var id: String { path }

    var canCommit: Bool { !status.isConflicted }

    var comparedPath: String {
        switch status.staged {
        case .renamed, .copied: return originalPath ?? path
        default: return path
        }
    }

    // `.A` is a file added with `git add --intent-to-add`: in the index, but not in HEAD either.
    var isNewFile: Bool {
        status.isUntracked || status.staged == .added || status.unstaged == .added
    }
}

internal struct LinkedFolderCommitDraft: Equatable, Sendable {
    let prefix: String
    let entries: [LinkedFolderCommitEntry]
    private(set) var checked: Set<String>
    var message = ""

    init(records: [GitStatusRecord], prefix: String, preselecting folderRelativePath: String? = nil) {
        self.prefix = prefix
        var seen: Set<String> = []
        entries = records
            .filter { $0.path.hasPrefix(prefix) }
            .sorted { lhs, rhs in Self.isTracked(lhs) && !Self.isTracked(rhs) }
            .filter { seen.insert($0.path).inserted }
            .map { record in
                LinkedFolderCommitEntry(
                    path: record.path,
                    folderRelativePath: String(record.path.dropFirst(prefix.count)),
                    originalPath: record.originalPath,
                    status: record.status
                )
            }
            .sorted { $0.folderRelativePath.localizedStandardCompare($1.folderRelativePath) == .orderedAscending }
        let committable = entries.filter(\.canCommit)
        if let folderRelativePath,
           let preselected = committable.first(where: { $0.folderRelativePath == folderRelativePath }) {
            checked = [preselected.id]
        } else {
            checked = Set(committable.map(\.id))
        }
    }

    var checkedEntries: [LinkedFolderCommitEntry] {
        entries.filter { $0.canCommit && checked.contains($0.id) }
    }

    var canCommit: Bool {
        !checkedEntries.isEmpty && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // A staged rename brings its old path along, unless that path is outside the folder or is listed
    // again because a new file sits there: then its own checkbox decides.
    var commitPaths: [String] {
        let listed = Set(entries.map(\.path))
        let renamedFrom = checkedEntries.compactMap { entry -> String? in
            guard entry.status.staged == .renamed, let original = entry.originalPath,
                  original.hasPrefix(prefix), !listed.contains(original) else { return nil }
            return original
        }
        return checkedEntries.map(\.path) + renamedFrom
    }

    var untrackedPaths: [String] {
        checkedEntries.filter(\.status.isUntracked).map(\.path)
    }

    func isChecked(_ entry: LinkedFolderCommitEntry) -> Bool {
        entry.canCommit && checked.contains(entry.id)
    }

    mutating func setChecked(_ entry: LinkedFolderCommitEntry, _ isChecked: Bool) {
        guard entry.canCommit else { return }
        if isChecked {
            checked.insert(entry.id)
        } else {
            checked.remove(entry.id)
        }
    }

    // An index deletion and an untracked file at the same path are two status records for one file.
    private static func isTracked(_ record: GitStatusRecord) -> Bool {
        !record.status.isUntracked
    }
}
