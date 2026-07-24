//
//  SqlDiff.swift
//  TablePro
//

import Foundation

enum SqlNormalizer {
    static func normalize(_ sql: String) -> String {
        sql
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func lines(_ sql: String) -> [String] {
        normalize(sql)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }
}

struct DiffPair: Equatable, Sendable {
    enum Kind: Sendable { case unchanged, added, removed, changed }
    let before: String?
    let after: String?
    let kind: Kind
}

struct DiffUnifiedLine: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case context, added, removed }
    let id: Int
    let beforeLineNumber: Int?
    let afterLineNumber: Int?
    let text: String
    let kind: Kind
}

enum DiffComputer {
    static func computeSplit(before: [String], after: [String]) -> [DiffPair] {
        let difference = after.difference(from: before)

        var removals: [Int: String] = [:]
        var insertions: [Int: String] = [:]
        for change in difference {
            switch change {
            case .remove(let offset, let element, _):
                removals[offset] = element
            case .insert(let offset, let element, _):
                insertions[offset] = element
            }
        }

        var pairs: [DiffPair] = []
        var beforeIndex = 0
        var afterIndex = 0

        while beforeIndex < before.count || afterIndex < after.count {
            let removed = removals[beforeIndex]
            let inserted = insertions[afterIndex]

            switch (removed, inserted) {
            case (let removed?, let inserted?):
                pairs.append(DiffPair(before: removed, after: inserted, kind: .changed))
                beforeIndex += 1
                afterIndex += 1
            case (let removed?, nil):
                pairs.append(DiffPair(before: removed, after: nil, kind: .removed))
                beforeIndex += 1
            case (nil, let inserted?):
                pairs.append(DiffPair(before: nil, after: inserted, kind: .added))
                afterIndex += 1
            case (nil, nil):
                if beforeIndex < before.count, afterIndex < after.count {
                    pairs.append(DiffPair(before: before[beforeIndex], after: after[afterIndex], kind: .unchanged))
                    beforeIndex += 1
                    afterIndex += 1
                } else {
                    return pairs
                }
            }
        }

        return pairs
    }

    static func computeUnified(before: [String], after: [String]) -> [DiffUnifiedLine] {
        computeUnified(from: computeSplit(before: before, after: after))
    }

    /// Derives unified rows from already-computed pairs so a caller that needs both
    /// layouts runs the underlying diff once instead of twice.
    static func computeUnified(from pairs: [DiffPair]) -> [DiffUnifiedLine] {
        var result: [DiffUnifiedLine] = []
        var beforeNumber = 1
        var afterNumber = 1
        var id = 0

        for pair in pairs {
            switch pair.kind {
            case .unchanged:
                result.append(DiffUnifiedLine(
                    id: id,
                    beforeLineNumber: beforeNumber,
                    afterLineNumber: afterNumber,
                    text: pair.before ?? "",
                    kind: .context
                ))
                beforeNumber += 1
                afterNumber += 1
            case .removed:
                result.append(DiffUnifiedLine(
                    id: id,
                    beforeLineNumber: beforeNumber,
                    afterLineNumber: nil,
                    text: pair.before ?? "",
                    kind: .removed
                ))
                beforeNumber += 1
            case .added:
                result.append(DiffUnifiedLine(
                    id: id,
                    beforeLineNumber: nil,
                    afterLineNumber: afterNumber,
                    text: pair.after ?? "",
                    kind: .added
                ))
                afterNumber += 1
            case .changed:
                result.append(DiffUnifiedLine(
                    id: id,
                    beforeLineNumber: beforeNumber,
                    afterLineNumber: nil,
                    text: pair.before ?? "",
                    kind: .removed
                ))
                id += 1
                result.append(DiffUnifiedLine(
                    id: id,
                    beforeLineNumber: nil,
                    afterLineNumber: afterNumber,
                    text: pair.after ?? "",
                    kind: .added
                ))
                beforeNumber += 1
                afterNumber += 1
            }
            id += 1
        }

        return result
    }
}
