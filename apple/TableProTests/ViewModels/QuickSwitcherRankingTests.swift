//
//  QuickSwitcherRankingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProUtilities
import Testing

/// The ranking keeps only the rows it shows and scores without allocating. These cases hold it to
/// the order the sort-everything version gave, kept here as `Reference`.
@MainActor
struct QuickSwitcherRankingTests {
    private struct Generator {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    private static let connectionId = UUID()
    private static let otherConnections = [
        (UUID(), "Staging"), (UUID(), "production"), (UUID(), "Production"), (UUID(), "analytics 2"),
    ]

    private static let names = [
        "orders", "order_items", "Orders", "ORDERS", "OrderItems", "user_log", "users", "user", "attendance",
        "timesheet", "attendance_timesheet", "b.c", "café", "cafe\u{301}", "emoji🙂", "lc_t001", "lc_t010",
        "lc_t100", "a", "ab", "public", "app", "order items", "order-items", "items_2", "items_10",
    ]
    private static let schemas: [String?] = ["public", "sales", "attendance", nil]
    private static let kinds: [QuickSwitcherItemKind] = [
        .table, .table, .table, .view, .systemTable, .database, .schema, .procedure, .function, .trigger,
        .userType, .savedQuery, .queryHistory,
    ]

    private static func makeItems(count: Int, seed: UInt64) -> [QuickSwitcherItem] {
        var generator = Generator(seed: seed)
        return (0..<count).map { _ in
            let name = names[generator.next(names.count)]
            let schema = schemas[generator.next(schemas.count)]
            let kind = kinds[generator.next(kinds.count)]
            var item = QuickSwitcherItem(
                frecencyKey: "\(kind.rawValue):\(schema ?? "-"):\(name):\(generator.next(4))",
                name: name,
                kind: kind,
                subtitle: generator.next(3) == 0 ? "" : "app / \(schema ?? "main")",
                keyword: kind == .savedQuery ? ["ord", "", nil, "weekly"][generator.next(4)] : nil,
                isOpenInTab: generator.next(7) == 0,
                schemaName: schema,
                databaseName: generator.next(2) == 0 ? "app" : nil,
                isOutsideBrowsedSchema: generator.next(5) == 0
            )
            if generator.next(4) == 0 {
                let (id, connectionName) = otherConnections[generator.next(otherConnections.count)]
                item.target = QuickSwitcherTarget(
                    connectionId: id,
                    connectionName: connectionName,
                    databaseName: "app",
                    schemaName: schema
                )
            }
            return item
        }
    }

    private static func frecencyScores(for items: [QuickSwitcherItem]) -> [String: Double] {
        var generator = Generator(seed: 7)
        var scores: [String: Double] = [:]
        for item in items where generator.next(9) == 0 {
            scores[item.frecencyKey] = Double(generator.next(5)) / 4
        }
        return scores
    }

    private func summary(_ groups: [QuickSwitcherViewModel.Group]) -> [String] {
        groups.flatMap { group in
            ["[\(group.id) \(group.header ?? "-")]"] + group.items.map { "\($0.id) \($0.matchedIndices)" }
        }
    }

    @Test("Filtered results equal the sort-everything ranking on 5,000 items")
    func filteredMatchesReference() async {
        let items = Self.makeItems(count: 5_000, seed: 42)
        let scores = Self.frecencyScores(for: items)
        let queries = [
            "o", "ord", "OrD", "or_it", "u", "us", "lc_t", "t0", "public.ord", "app.public.", "sales.",
            "app.sales.orders", "b.c", "café", "e", "🙂", "items", "s", "zz", "order items", "weekly",
        ]
        for query in queries {
            let ranked = await QuickSwitcherViewModel.filteredGroups(
                items: items, query: query, frecencyScores: scores, connectionId: Self.connectionId
            )
            let reference = Reference.filteredGroups(
                items: items, query: query, frecencyScores: scores, connectionId: Self.connectionId
            )
            #expect(summary(ranked) == summary(reference), "query \(query)")
        }
    }

    @Test("Browse lists equal the sort-everything lists on 5,000 items")
    func browseMatchesReference() async {
        let items = Self.makeItems(count: 5_000, seed: 9)
        let recentKeys = Array(items.prefix(40).map(\.frecencyKey).reversed())
        for scope in QuickSwitcherScope.allCases {
            let scoped = scope.includedKinds.map { kinds in items.filter { kinds.contains($0.kind) } } ?? items
            for keys in [[], recentKeys] {
                let listed = await QuickSwitcherViewModel.emptyQueryGroups(
                    items: scoped, scope: scope, recentKeys: keys, connectionId: Self.connectionId
                )
                let reference = Reference.emptyQueryGroups(
                    items: scoped, scope: scope, recentKeys: keys, connectionId: Self.connectionId
                )
                #expect(summary(listed) == summary(reference), "scope \(scope.rawValue) recents \(keys.count)")
            }
        }
    }

    @Test("A catalog smaller than the cap lists every match")
    func smallCatalogListsEveryMatch() async {
        let items = Self.makeItems(count: 120, seed: 3)
        let ranked = await QuickSwitcherViewModel.filteredGroups(
            items: items, query: "o", frecencyScores: [:], connectionId: Self.connectionId
        )
        let reference = Reference.filteredGroups(
            items: items, query: "o", frecencyScores: [:], connectionId: Self.connectionId
        )
        #expect(summary(ranked) == summary(reference))
        #expect((ranked.first?.items.count ?? 0) < QuickSwitcherRanking.maxResults)
    }
}

/// The ranking as it was before it kept only the rows shown: every match copied, sorted whole and cut.
private enum Reference {
    typealias Group = QuickSwitcherViewModel.Group

    static func filteredGroups(
        items: [QuickSwitcherItem],
        query: String,
        frecencyScores: [String: Double],
        connectionId: UUID
    ) -> [Group] {
        let qualified = QualifiedSearchQuery(query)
        let prefersShorterNames = qualified.map { !$0.name.isEmpty } ?? true
        var ranked: [(item: QuickSwitcherItem, rank: Double)] = []
        for item in items {
            guard let (matchScore, matchedIndices) = QuickSwitcherViewModel.bestMatch(
                for: item, query: query, qualified: qualified
            ) else { continue }
            var matched = item
            matched.matchedIndices = matchedIndices
            let recalled = item.belongs(to: connectionId) ? frecencyScores[item.frecencyKey] ?? 0 : 0
            let frecency = 1 + recalled * QuickSwitcherRanking.frecencyBoost
            let openBoost = item.isOpenInTab ? QuickSwitcherRanking.openTabBoost : 1
            let location = item.isOutsideBrowsedSchema ? QuickSwitcherRanking.otherSchemaWeight : 1
            ranked.append((item: matched, rank: matchScore * item.kind.rankWeight * frecency * openBoost * location))
        }
        ranked.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
            let lhsOrder = QuickSwitcherItemKind.displayOrder.firstIndex(of: lhs.item.kind) ?? Int.max
            let rhsOrder = QuickSwitcherItemKind.displayOrder.firstIndex(of: rhs.item.kind) ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            let lhsLength = (lhs.item.name as NSString).length
            let rhsLength = (rhs.item.name as NSString).length
            if prefersShorterNames, lhsLength != rhsLength { return lhsLength < rhsLength }
            return lhs.item.name.localizedStandardCompare(rhs.item.name) == .orderedAscending
        }
        let kept = Array(ranked.prefix(QuickSwitcherRanking.maxResults).map(\.item))
        guard !kept.isEmpty else { return [] }
        return [Group(id: "results", header: nil, items: kept)]
    }

    static func emptyQueryGroups(
        items: [QuickSwitcherItem],
        scope: QuickSwitcherScope,
        recentKeys: [String],
        connectionId: UUID
    ) -> [Group] {
        let recent = recentItems(in: items, keys: recentKeys, ownedBy: connectionId)
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
        for kind in QuickSwitcherItemKind.displayOrder {
            let kindItems = items
                .filter { $0.kind == kind && !isRecent($0) }
                .sorted { lhs, rhs in
                    if lhs.isOutsideBrowsedSchema != rhs.isOutsideBrowsedSchema { return rhs.isOutsideBrowsedSchema }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            guard !kindItems.isEmpty else { continue }
            result.append(Group(
                id: "kind-\(kind.rawValue)",
                header: kind.sectionTitle,
                items: Array(kindItems.prefix(QuickSwitcherRanking.maxResults))
            ))
        }
        return result
    }

    private static func recentItems(
        in items: [QuickSwitcherItem],
        keys recentKeys: [String],
        ownedBy connectionId: UUID
    ) -> [QuickSwitcherItem] {
        let rank = Dictionary(recentKeys.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var rankedItems: [Int: QuickSwitcherItem] = [:]
        for item in items {
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

    private static func connectionGroups(
        items: [QuickSwitcherItem],
        excluding isExcluded: (QuickSwitcherItem) -> Bool
    ) -> [Group] {
        let excludedCount = items.reduce(into: 0) { count, item in
            if isExcluded(item) { count += 1 }
        }
        let availableCount = max(0, QuickSwitcherRanking.maxResults - excludedCount)
        let sortedItems = items.filter { !isExcluded($0) }
            .sorted { lhs, rhs in
                let lhsConnection = lhs.target?.connectionName ?? ""
                let rhsConnection = rhs.target?.connectionName ?? ""
                let connectionOrder = lhsConnection.localizedStandardCompare(rhsConnection)
                if connectionOrder != .orderedSame { return connectionOrder == .orderedAscending }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .prefix(availableCount)
        var order: [UUID] = []
        var grouped: [UUID: [QuickSwitcherItem]] = [:]
        var names: [UUID: String] = [:]
        for item in sortedItems {
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
}
