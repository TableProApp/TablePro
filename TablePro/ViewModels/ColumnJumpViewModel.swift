//
//  ColumnJumpViewModel.swift
//  TablePro
//

import Foundation
import Observation

@MainActor @Observable
final class ColumnJumpViewModel {
    struct Match: Identifiable, Equatable {
        let entry: GridColumnEntry
        let matchedIndices: [Int]

        var id: String { entry.id }
    }

    let entries: [GridColumnEntry]
    private(set) var matches: [Match] = []
    var selectedId: String?
    var searchText: String {
        didSet { refilter() }
    }

    @ObservationIgnored private var rankedQuery: String

    /// - Parameter cursorColumnIndex: the data index under the grid's cell cursor, which the empty
    ///   list opens on so Return with nothing typed goes nowhere the reader is not already looking.
    init(entries: [GridColumnEntry], initialQuery: String = "", cursorColumnIndex: Int? = nil) {
        self.entries = entries
        let query = initialQuery.trimmingCharacters(in: .whitespaces)
        self.searchText = initialQuery
        self.rankedQuery = query
        let ranked = Self.rank(entries, query: query)
        self.matches = ranked
        let cursorMatch = cursorColumnIndex.flatMap { index in
            ranked.first { $0.entry.dataIndex == index && !$0.entry.isHidden }
        }
        self.selectedId = (cursorMatch ?? ranked.first)?.id
    }

    var presentedColumnCount: Int {
        entries.filter { !$0.isHidden }.count
    }

    var selectedEntry: GridColumnEntry? {
        matches.first { $0.id == selectedId }?.entry
    }

    func moveSelection(by offset: Int) {
        guard !matches.isEmpty else { return }
        let current = selectedId.flatMap { id in matches.firstIndex { $0.id == id } } ?? 0
        let next = min(max(current + offset, 0), matches.count - 1)
        selectedId = matches[next].id
    }

    func listHeight(rowHeight: CGFloat, maxVisibleRows: Int) -> CGFloat {
        CGFloat(min(max(matches.count, 1), maxVisibleRows)) * rowHeight
    }

    /// A query that ranks the same rows keeps the selection; a new query moves it to the best
    /// match, because the row the reader had was chosen against a list that no longer exists.
    private func refilter() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard query != rankedQuery else { return }
        rankedQuery = query
        matches = Self.rank(entries, query: query)
        selectedId = matches.first?.id
    }

    private static func rank(_ entries: [GridColumnEntry], query: String) -> [Match] {
        let ordered = entries.enumerated().map { (entry: $0.element, catalogOrder: $0.offset) }
        guard !query.isEmpty else {
            return ordered
                .sorted { precedes($0, $1) }
                .map { Match(entry: $0.entry, matchedIndices: []) }
        }
        return ordered
            .compactMap { candidate -> (match: Match, score: Int, candidate: (entry: GridColumnEntry, catalogOrder: Int))? in
                guard let fuzzy = FuzzyMatcher.match(query: query, candidate: candidate.entry.name) else { return nil }
                return (Match(entry: candidate.entry, matchedIndices: fuzzy.matchedIndices), fuzzy.score, candidate)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return precedes(lhs.candidate, rhs.candidate)
            }
            .map { $0.match }
    }

    /// Presented columns first, in the order the grid shows them; hidden ones after, in catalog order.
    private static func precedes(
        _ lhs: (entry: GridColumnEntry, catalogOrder: Int),
        _ rhs: (entry: GridColumnEntry, catalogOrder: Int)
    ) -> Bool {
        switch (lhs.entry.position, rhs.entry.position) {
        case let (left?, right?):
            return left < right
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (nil, nil):
            return lhs.catalogOrder < rhs.catalogOrder
        }
    }
}
