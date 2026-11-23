//
//  QuickSwitcherViewModel+Ranking.swift
//  TablePro
//

import Foundation
import TableProUtilities

extension QuickSwitcherViewModel {
    nonisolated static let cancellationCheckStride = 1_024

    // A superseded pass returns empty at the next check; the caller drops it either way.
    @concurrent
    nonisolated static func emptyQueryGroups(
        items: [QuickSwitcherItem],
        scope: QuickSwitcherScope,
        recentKeys: [String],
        connectionId: UUID
    ) async -> [Group] {
        let recent = recentItems(in: items, keys: recentKeys, ownedBy: connectionId)
        guard !Task.isCancelled else { return [] }
        let recentKeySet = Set(recent.map(\.frecencyKey))
        let isRecent: (QuickSwitcherItem) -> Bool = { item in
            item.belongs(to: connectionId) && recentKeySet.contains(item.frecencyKey)
        }

        var result: [Group] = []

        if !recent.isEmpty {
            result.append(Group(id: "recent", header: String(localized: "Recent"), items: recent))
        }

        if scope.usesCrossConnectionCatalog {
            return result + connectionGroups(items: items, excluding: isRecent)
        }

        guard scope != .all else { return result }

        // Each section keeps only the rows it can show, so a large catalog is not sorted whole.
        var sections = QuickSwitcherItemKind.displayOrder.map { _ in
            TopRanked<Int>(capacity: QuickSwitcherRanking.maxResults) { lhs, rhs in
                let lhsItem = items[lhs]
                let rhsItem = items[rhs]
                if lhsItem.isOutsideBrowsedSchema != rhsItem.isOutsideBrowsedSchema {
                    return rhsItem.isOutsideBrowsedSchema
                }
                return lhsItem.name.localizedStandardCompare(rhsItem.name) == .orderedAscending
            }
        }
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: cancellationCheckStride), Task.isCancelled { return [] }
            guard !isRecent(item) else { continue }
            sections[item.kind.displayIndex].insert(index)
        }
        guard !Task.isCancelled else { return [] }

        for (kind, section) in zip(QuickSwitcherItemKind.displayOrder, sections) where !section.isEmpty {
            result.append(Group(
                id: "kind-\(kind.rawValue)",
                header: kind.sectionTitle,
                items: section.sorted().map { items[$0] }
            ))
        }
        return result
    }

    nonisolated private static func recentItems(
        in items: [QuickSwitcherItem],
        keys recentKeys: [String],
        ownedBy connectionId: UUID
    ) -> [QuickSwitcherItem] {
        let rank = Dictionary(recentKeys.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var rankedItems: [Int: QuickSwitcherItem] = [:]
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: cancellationCheckStride), Task.isCancelled { return [] }
            guard item.belongs(to: connectionId),
                  let position = rank[item.frecencyKey],
                  rankedItems[position] == nil else { continue }
            rankedItems[position] = item
        }
        return rankedItems
            .sorted { $0.key < $1.key }
            .prefix(QuickSwitcherRanking.recentLimit)
            .map(\.value)
    }

    nonisolated private static func connectionGroups(
        items: [QuickSwitcherItem],
        excluding isExcluded: (QuickSwitcherItem) -> Bool
    ) -> [Group] {
        let excludedCount = items.reduce(into: 0) { count, item in
            if isExcluded(item) { count += 1 }
        }
        let availableCount = max(0, QuickSwitcherRanking.maxResults - excludedCount)
        var kept = TopRanked<Int>(capacity: availableCount) { lhs, rhs in
            let lhsItem = items[lhs]
            let rhsItem = items[rhs]
            let lhsConnection = lhsItem.target?.connectionName ?? ""
            let rhsConnection = rhsItem.target?.connectionName ?? ""
            let connectionOrder = lhsConnection.localizedStandardCompare(rhsConnection)
            if connectionOrder != .orderedSame { return connectionOrder == .orderedAscending }
            return lhsItem.name.localizedStandardCompare(rhsItem.name) == .orderedAscending
        }
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: cancellationCheckStride), Task.isCancelled { return [] }
            guard !isExcluded(item) else { continue }
            kept.insert(index)
        }
        guard !Task.isCancelled else { return [] }

        var order: [UUID] = []
        var grouped: [UUID: [QuickSwitcherItem]] = [:]
        var names: [UUID: String] = [:]
        for item in kept.sorted().map({ items[$0] }) {
            guard let target = item.target else { continue }
            if grouped[target.connectionId] == nil {
                order.append(target.connectionId)
                names[target.connectionId] = target.connectionName
            }
            grouped[target.connectionId, default: []].append(item)
        }

        return order.compactMap { connectionId in
            guard let items = grouped[connectionId], let name = names[connectionId] else { return nil }
            return Group(id: "connection-\(connectionId.uuidString)", header: name, items: items)
        }
    }

    /// Where an item lands among the results, held as an index so ranking a large catalog does not
    /// copy every matching item.
    private struct RankedIndex {
        let rank: Double
        let kindOrder: Int
        let length: Int
        let index: Int
    }

    // A superseded keystroke stops at the next check instead of competing with the current pass.
    @concurrent
    nonisolated static func filteredGroups(
        items: [QuickSwitcherItem],
        query: String,
        frecencyScores: [String: Double],
        connectionId: UUID
    ) async -> [Group] {
        let qualified = QualifiedSearchQuery(query)
        let prefersShorterNames = qualified.map { !$0.name.isEmpty } ?? true
        let scorer = QuickSwitcherScorer(query: query, qualified: qualified)
        var scratch = FuzzyScratch()
        // Ties keep catalog order: the heap breaks them by insertion, which is the item's index.
        var kept = TopRanked<RankedIndex>(capacity: QuickSwitcherRanking.maxResults) { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
            if lhs.kindOrder != rhs.kindOrder { return lhs.kindOrder < rhs.kindOrder }
            if lhs.length != rhs.length { return lhs.length < rhs.length }
            let lhsName = items[lhs.index].name
            let rhsName = items[rhs.index].name
            guard lhsName != rhsName else { return false }
            return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
        }
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: cancellationCheckStride), Task.isCancelled { return [] }
            guard let matchScore = scorer.bestScore(for: item, scratch: &scratch) else { continue }
            let recalled = item.belongs(to: connectionId) ? frecencyScores[item.frecencyKey] ?? 0 : 0
            let frecency = 1 + recalled * QuickSwitcherRanking.frecencyBoost
            let openBoost = item.isOpenInTab ? QuickSwitcherRanking.openTabBoost : 1
            let location = item.isOutsideBrowsedSchema ? QuickSwitcherRanking.otherSchemaWeight : 1
            kept.insert(RankedIndex(
                rank: matchScore * item.kind.rankWeight * frecency * openBoost * location,
                kindOrder: item.kind.displayIndex,
                length: prefersShorterNames ? item.name.utf16.count : 0,
                index: index
            ))
        }
        guard !Task.isCancelled else { return [] }
        // Only the rows shown carry highlighted characters, so only they pay for the traceback.
        let results = kept.sorted().map { ranked -> QuickSwitcherItem in
            var item = items[ranked.index]
            item.matchedIndices = bestMatch(for: item, query: query, qualified: qualified)?.matchedIndices ?? []
            return item
        }
        guard !results.isEmpty else { return [] }
        return [Group(id: "results", header: nil, items: results)]
    }

    /// A dotted query is read both ways and the better reading wins: as a path, and as plain text,
    /// which is what still finds a table literally named `b.c` and a connection path in a subtitle.
    nonisolated static func bestMatch(
        for item: QuickSwitcherItem,
        query: String,
        qualified: QualifiedSearchQuery?
    ) -> (score: Double, matchedIndices: [Int])? {
        let plain = plainMatch(for: item, query: query)
        guard let qualified, let path = pathMatch(for: item, query: qualified) else { return plain }
        guard let plain, plain.score >= path.score else { return path }
        return plain
    }

    /// Each container the query names has to match the part of the item's location it lines up
    /// with, and the name has to match the item's name. An empty name, `attendance.`, takes every
    /// item in the matched container.
    nonisolated static func pathMatch(
        for item: QuickSwitcherItem,
        query: QualifiedSearchQuery
    ) -> (score: Double, matchedIndices: [Int])? {
        guard let pairs = query.containerPairs(with: item.searchLocation) else { return nil }
        var containerScore = 0.0
        for pair in pairs {
            guard let match = FuzzyMatcher.match(query: pair.query, candidate: pair.candidate) else { return nil }
            containerScore += Double(match.score)
        }
        let weightedContainers = containerScore * QuickSwitcherRanking.containerMatchWeight
        guard !query.name.isEmpty else { return (weightedContainers, []) }
        guard let nameMatch = FuzzyMatcher.match(query: query.name, candidate: item.name) else { return nil }
        return (Double(nameMatch.score) + weightedContainers, nameMatch.matchedIndices)
    }

    nonisolated private static func plainMatch(
        for item: QuickSwitcherItem,
        query: String
    ) -> (score: Double, matchedIndices: [Int])? {
        let nameMatch = FuzzyMatcher.match(query: query, candidate: item.name)
        var secondaryScores: [Double] = []
        if let keyword = item.keyword,
           !keyword.isEmpty,
           let keywordMatch = FuzzyMatcher.match(query: query, candidate: keyword) {
            secondaryScores.append(Double(keywordMatch.score) * QuickSwitcherRanking.keywordMatchWeight)
        }
        if !item.subtitle.isEmpty, let subtitleMatch = FuzzyMatcher.match(query: query, candidate: item.subtitle) {
            secondaryScores.append(Double(subtitleMatch.score) * QuickSwitcherRanking.subtitleMatchPenalty)
        }
        let subtitleScore = secondaryScores.max()

        switch (nameMatch, subtitleScore) {
        case let (match?, score?) where score > Double(match.score):
            return (score, [])
        case let (match?, _):
            return (Double(match.score), match.matchedIndices)
        case let (nil, score?):
            return (score, [])
        case (nil, nil):
            return nil
        }
    }
}

/// The score `QuickSwitcherViewModel.bestMatch` gives an item, from queries folded once per
/// keystroke and without the matched indices, which only the rows kept for display need.
struct QuickSwitcherScorer {
    private let plain: FuzzyQuery
    private let containers: [FuzzyQuery]
    private let name: FuzzyQuery?

    init(query: String, qualified: QualifiedSearchQuery?) {
        plain = FuzzyQuery(query)
        containers = qualified?.containers.map(FuzzyQuery.init) ?? []
        name = qualified.map { FuzzyQuery($0.name) }
    }

    func bestScore(for item: QuickSwitcherItem, scratch: inout FuzzyScratch) -> Double? {
        let plainScore = plainScore(for: item, scratch: &scratch)
        guard let name, let path = pathScore(for: item, name: name, scratch: &scratch) else { return plainScore }
        guard let plainScore, plainScore >= path else { return path }
        return plainScore
    }

    private func pathScore(for item: QuickSwitcherItem, name: FuzzyQuery, scratch: inout FuzzyScratch) -> Double? {
        let location = item.searchLocation
        guard containers.count <= location.count else { return nil }
        var containerScore = 0.0
        for (container, candidate) in zip(containers, location.suffix(containers.count)) {
            guard let score = FuzzyMatcher.score(container, candidate, scratch: &scratch) else { return nil }
            containerScore += Double(score)
        }
        let weightedContainers = containerScore * QuickSwitcherRanking.containerMatchWeight
        guard !name.text.isEmpty else { return weightedContainers }
        guard let nameScore = FuzzyMatcher.score(name, item.name, scratch: &scratch) else { return nil }
        return Double(nameScore) + weightedContainers
    }

    private func plainScore(for item: QuickSwitcherItem, scratch: inout FuzzyScratch) -> Double? {
        let nameScore = FuzzyMatcher.score(plain, item.name, scratch: &scratch)
        var secondaryScore: Double?
        if let keyword = item.keyword,
           !keyword.isEmpty,
           let keywordScore = FuzzyMatcher.score(plain, keyword, scratch: &scratch) {
            secondaryScore = Double(keywordScore) * QuickSwitcherRanking.keywordMatchWeight
        }
        if !item.subtitle.isEmpty, let subtitleScore = FuzzyMatcher.score(plain, item.subtitle, scratch: &scratch) {
            let weighted = Double(subtitleScore) * QuickSwitcherRanking.subtitleMatchPenalty
            secondaryScore = max(secondaryScore ?? weighted, weighted)
        }

        switch (nameScore, secondaryScore) {
        case let (score?, secondary?) where secondary > Double(score):
            return secondary
        case let (score?, _):
            return Double(score)
        case let (nil, secondary?):
            return secondary
        case (nil, nil):
            return nil
        }
    }
}

extension QuickSwitcherItemKind {
    static let displayOrder: [QuickSwitcherItemKind] = [
        .table, .view, .systemTable, .database, .schema,
        .procedure, .function, .trigger, .userType, .savedQuery, .queryHistory
    ]

    /// This kind's position in `displayOrder`.
    var displayIndex: Int {
        switch self {
        case .table: return 0
        case .view: return 1
        case .systemTable: return 2
        case .database: return 3
        case .schema: return 4
        case .procedure: return 5
        case .function: return 6
        case .trigger: return 7
        case .userType: return 8
        case .savedQuery: return 9
        case .queryHistory: return 10
        }
    }

    var rankWeight: Double {
        switch self {
        case .table: return 1.0
        case .view: return 0.98
        case .systemTable: return 0.85
        case .database: return 0.95
        case .schema: return 0.93
        case .procedure: return 0.92
        case .function: return 0.92
        case .trigger: return 0.91
        case .userType: return 0.91
        case .savedQuery: return 0.9
        case .queryHistory: return 0.7
        }
    }

    var sectionTitle: String {
        switch self {
        case .table: return String(localized: "Tables")
        case .view: return String(localized: "Views")
        case .systemTable: return String(localized: "System Tables")
        case .database: return String(localized: "Databases")
        case .schema: return String(localized: "Schemas")
        case .procedure: return String(localized: "Procedures")
        case .function: return String(localized: "Functions")
        case .trigger: return String(localized: "Triggers")
        case .userType: return String(localized: "Types")
        case .savedQuery: return String(localized: "Saved Queries")
        case .queryHistory: return String(localized: "Recent Queries")
        }
    }
}
