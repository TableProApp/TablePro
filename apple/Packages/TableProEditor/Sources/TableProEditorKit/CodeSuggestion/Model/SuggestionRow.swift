//
//  SuggestionRow.swift
//  TableProEditorKit
//

import Foundation

// What a row shows names it: the same entry ranked into another position is the same row. Repeats of one label and
// detail are told apart by their order, so every identity in a list is unique.
struct SuggestionRowID: Hashable {
    let label: String
    let detail: String?
    let occurrence: Int

    private struct Shown: Hashable {
        let label: String
        let detail: String?
    }

    static func ids(for items: [CodeSuggestionEntry]) -> [SuggestionRowID] {
        var seen: [Shown: Int] = [:]
        seen.reserveCapacity(items.count)
        return items.map { item in
            let shown = Shown(label: item.label, detail: item.detail)
            let occurrence = seen[shown, default: 0]
            seen[shown] = occurrence + 1
            return SuggestionRowID(label: item.label, detail: item.detail, occurrence: occurrence)
        }
    }
}

struct SuggestionRow: Identifiable {
    let id: SuggestionRowID
    let index: Int
    let item: CodeSuggestionEntry
}
