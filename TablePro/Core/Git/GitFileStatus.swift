//
//  GitFileStatus.swift
//  TablePro
//

import Foundation

internal struct GitFileStatus: Hashable, Sendable {
    internal enum Change: Hashable, Sendable {
        case unmodified
        case modified
        case added
        case deleted
        case renamed
        case copied
        case typeChanged
        case unmerged

        init(code: Character) {
            switch code {
            case "M": self = .modified
            case "A": self = .added
            case "D": self = .deleted
            case "R": self = .renamed
            case "C": self = .copied
            case "T": self = .typeChanged
            case "U": self = .unmerged
            default: self = .unmodified
            }
        }
    }

    internal enum Badge: Hashable, Sendable {
        case modified
        case added
        case renamed
        case untracked
        case conflicted

        var letter: String {
            switch self {
            case .modified: return "M"
            case .added: return "A"
            case .renamed: return "R"
            case .untracked: return "U"
            case .conflicted: return "!"
            }
        }

        var label: String {
            switch self {
            case .modified: return String(localized: "Modified")
            case .added: return String(localized: "Added")
            case .renamed: return String(localized: "Renamed")
            case .untracked: return String(localized: "Untracked")
            case .conflicted: return String(localized: "Conflicted")
            }
        }
    }

    let staged: Change
    let unstaged: Change
    let isUntracked: Bool
    let isConflicted: Bool

    static let untracked = GitFileStatus(staged: .unmodified, unstaged: .unmodified, isUntracked: true)

    init(staged: Change, unstaged: Change, isUntracked: Bool = false, isUnmergedEntry: Bool = false) {
        self.staged = staged
        self.unstaged = unstaged
        self.isUntracked = isUntracked
        self.isConflicted = isUnmergedEntry || staged == .unmerged || unstaged == .unmerged
    }

    init(code: Substring, isUnmergedEntry: Bool = false) {
        let characters = Array(code)
        self.init(
            staged: Change(code: characters.first ?? "."),
            unstaged: Change(code: characters.count > 1 ? characters[1] : "."),
            isUnmergedEntry: isUnmergedEntry
        )
    }

    var hasStagedChanges: Bool {
        !isUntracked && staged != .unmodified
    }

    var hasUnstagedChanges: Bool {
        isUntracked || unstaged != .unmodified
    }

    var badge: Badge {
        if isConflicted { return .conflicted }
        if isUntracked { return .untracked }
        switch staged {
        case .added: return .added
        case .renamed, .copied: return .renamed
        default: return .modified
        }
    }

    var canDiscardChanges: Bool {
        guard !isUntracked, !isConflicted else { return false }
        return unstaged == .modified || unstaged == .typeChanged
    }

    var hasCommittedHistory: Bool {
        guard !isUntracked else { return false }
        switch staged {
        case .added, .renamed, .copied: return false
        default: return true
        }
    }

    var accessibilityDescription: String {
        guard !isUntracked, !isConflicted else { return badge.label }
        switch (hasStagedChanges, unstaged != .unmodified) {
        case (true, false):
            return String(format: String(localized: "%@, staged"), badge.label)
        case (true, true):
            return String(format: String(localized: "%@, partly staged"), badge.label)
        default:
            return badge.label
        }
    }
}
