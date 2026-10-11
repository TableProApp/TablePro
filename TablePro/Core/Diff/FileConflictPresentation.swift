//
//  FileConflictPresentation.swift
//  TablePro
//

import Foundation

internal enum FileConflictSide: Sendable {
    case mine
    case disk
}

internal enum FileConflictRowHighlight: Equatable, Sendable {
    case plain
    case removed
    case added
    case filler

    init(kind: DiffPair.Kind, side: FileConflictSide) {
        switch (kind, side) {
        case (.unchanged, _):
            self = .plain
        case (.removed, .mine), (.changed, .mine):
            self = .removed
        case (.added, .disk), (.changed, .disk):
            self = .added
        case (.removed, .disk), (.added, .mine):
            self = .filler
        }
    }
}

internal struct FileConflictRow: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String?
    let highlight: FileConflictRowHighlight
}

internal struct FileConflictPresentation: Equatable, Sendable {
    let mineRows: [FileConflictRow]
    let diskRows: [FileConflictRow]
    let showsLineDiff: Bool

    init(comparison: FileConflictComparison) {
        switch comparison {
        case .lineDiff(let pairs):
            mineRows = Self.diffRows(pairs, side: .mine)
            diskRows = Self.diffRows(pairs, side: .disk)
            showsLineDiff = true
        case .withoutLineDiff(let mine, let disk):
            mineRows = Self.plainRows(mine)
            diskRows = Self.plainRows(disk)
            showsLineDiff = false
        }
    }

    @concurrent
    static func load(mine: String, disk: String) async -> FileConflictPresentation {
        FileConflictPresentation(comparison: FileConflictDiff.comparison(mine: mine, disk: disk))
    }

    private static func diffRows(_ pairs: [DiffPair], side: FileConflictSide) -> [FileConflictRow] {
        pairs.enumerated().map { index, pair in
            FileConflictRow(
                id: index,
                text: side == .mine ? pair.before : pair.after,
                highlight: FileConflictRowHighlight(kind: pair.kind, side: side)
            )
        }
    }

    private static func plainRows(_ lines: [String]) -> [FileConflictRow] {
        lines.enumerated().map { index, line in
            FileConflictRow(id: index, text: line, highlight: .plain)
        }
    }
}
