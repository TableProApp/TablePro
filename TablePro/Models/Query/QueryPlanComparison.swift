//
//  QueryPlanComparison.swift
//  TablePro
//
//  Deterministic comparison between an older and a current query plan.
//

import Foundation

struct QueryPlanMetricDelta: Equatable, Sendable {
    let previous: Double?
    let current: Double?

    var delta: Double? {
        guard let previous, let current else { return nil }
        return current - previous
    }

    var percentChange: Double? {
        guard let previous, let current,
              previous != 0,
              previous.isFinite,
              current.isFinite else { return nil }
        return ((current - previous) / previous) * 100
    }

    var hasChanges: Bool {
        previous != current
    }
}

struct QueryPlanSummaryComparison: Equatable, Sendable {
    let rootEstimatedTotalCost: QueryPlanMetricDelta
    let rootEstimatedRows: QueryPlanMetricDelta
    let planningTime: QueryPlanMetricDelta
    let executionTime: QueryPlanMetricDelta
    let nodeCount: QueryPlanMetricDelta

    var hasChanges: Bool {
        rootEstimatedTotalCost.hasChanges ||
            rootEstimatedRows.hasChanges ||
            planningTime.hasChanges ||
            executionTime.hasChanges ||
            nodeCount.hasChanges
    }
}

enum QueryPlanNodeChangeKind: String, Equatable, Sendable {
    case added
    case removed
    case modified
}

enum QueryPlanNodeValueCategory: String, Equatable, Sendable {
    case metric
    case property
}

struct QueryPlanNodeValueChange: Equatable, Identifiable, Sendable {
    let category: QueryPlanNodeValueCategory
    let name: String
    let previousValue: String?
    let currentValue: String?

    var id: String {
        "\(category.rawValue):\(name)"
    }
}

struct QueryPlanNodeChange: Equatable, Identifiable, Sendable {
    let kind: QueryPlanNodeChangeKind
    let semanticPathID: String
    let operation: String
    let relation: String?
    let schema: String?
    let alias: String?
    let valueChanges: [QueryPlanNodeValueChange]

    var id: String {
        "\(kind.rawValue):\(semanticPathID)"
    }
}

struct QueryPlanComparison: Equatable, Sendable {
    /// Exact sibling LCS is bounded; wider plans use deterministic linear matching.
    static let maximumLCSCellCount = 1_000_000

    let summary: QueryPlanSummaryComparison
    let nodeChanges: [QueryPlanNodeChange]

    var hasChanges: Bool {
        summary.hasChanges || !nodeChanges.isEmpty
    }

    static func usesLinearSiblingMatcher(previousCount: Int, currentCount: Int) -> Bool {
        let (cellCount, overflow) = previousCount.multipliedReportingOverflow(by: currentCount)
        return overflow || cellCount > maximumLCSCellCount
    }

    init(previous: QueryPlan, current: QueryPlan) {
        summary = QueryPlanSummaryComparison(
            rootEstimatedTotalCost: QueryPlanMetricDelta(
                previous: previous.rootNode.estimatedTotalCost,
                current: current.rootNode.estimatedTotalCost
            ),
            rootEstimatedRows: QueryPlanMetricDelta(
                previous: previous.rootNode.estimatedRows.map(Double.init),
                current: current.rootNode.estimatedRows.map(Double.init)
            ),
            planningTime: QueryPlanMetricDelta(
                previous: previous.planningTime,
                current: current.planningTime
            ),
            executionTime: QueryPlanMetricDelta(
                previous: previous.executionTime,
                current: current.executionTime
            ),
            nodeCount: QueryPlanMetricDelta(
                previous: Double(Self.nodeCount(in: previous.rootNode)),
                current: Double(Self.nodeCount(in: current.rootNode))
            )
        )

        var changes: [QueryPlanNodeChange] = []
        Self.compareRoots(previous.rootNode, current.rootNode, changes: &changes)
        nodeChanges = changes.sorted(by: Self.changeOrder)
    }
}

private extension QueryPlanComparison {
    struct SemanticKey: Hashable, Comparable {
        let operation: String
        let schema: String?
        let relation: String?
        let alias: String?
        let identifyingProperties: [(key: String, value: String)]

        static func == (lhs: SemanticKey, rhs: SemanticKey) -> Bool {
            lhs.operation == rhs.operation &&
                lhs.schema == rhs.schema &&
                lhs.relation == rhs.relation &&
                lhs.alias == rhs.alias &&
                lhs.identifyingProperties.elementsEqual(rhs.identifyingProperties) {
                    $0.key == $1.key && $0.value == $1.value
                }
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(operation)
            hasher.combine(schema)
            hasher.combine(relation)
            hasher.combine(alias)
            for property in identifyingProperties {
                hasher.combine(property.key)
                hasher.combine(property.value)
            }
        }

        static func < (lhs: SemanticKey, rhs: SemanticKey) -> Bool {
            lhs.sortKey < rhs.sortKey
        }

        var pathComponent: String {
            let fields = [
                "operation=\(Self.escape(operation))",
                "schema=\(Self.escape(schema))",
                "relation=\(Self.escape(relation))",
                "alias=\(Self.escape(alias))",
            ]
            let properties = identifyingProperties.map {
                "property.\(Self.escape($0.key))=\(Self.escape($0.value))"
            }
            return (fields + properties).joined(separator: "&")
        }

        private var sortKey: String {
            let properties = identifyingProperties.flatMap { [$0.key, $0.value] }
            return ([operation, schema, relation, alias].map(Self.sortField) + properties.map(Self.sortField))
                .joined(separator: "|")
        }

        private static func escape(_ value: String?) -> String {
            guard let value else { return "~" }
            return value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
        }

        private static func sortField(_ value: String?) -> String {
            guard let value else { return "N" }
            return "S\(value.utf8.count):\(value)"
        }
    }

    struct IndexedNode {
        let node: QueryPlanNode
        let key: SemanticKey
        let occurrence: Int
    }

    struct NodeMatch {
        let previousIndex: Int
        let currentIndex: Int
    }

    struct ValueKey: Hashable, Comparable {
        let category: QueryPlanNodeValueCategory
        let name: String

        static func < (lhs: ValueKey, rhs: ValueKey) -> Bool {
            if lhs.category.rawValue != rhs.category.rawValue {
                return lhs.category.rawValue < rhs.category.rawValue
            }
            return lhs.name < rhs.name
        }
    }

    static let identifyingPropertyKeys: Set<String> = [
        "CTE Name",
        "Index Name",
        "Join Type",
        "Parent Relationship",
        "Strategy",
        "Subplan Name",
    ]

    static func nodeCount(in node: QueryPlanNode) -> Int {
        1 + node.children.reduce(0) { $0 + nodeCount(in: $1) }
    }

    static func compareRoots(
        _ previous: QueryPlanNode,
        _ current: QueryPlanNode,
        changes: inout [QueryPlanNodeChange]
    ) {
        let previousKey = semanticKey(for: previous)
        let currentKey = semanticKey(for: current)

        guard previousKey == currentKey else {
            appendSubtree(
                previous,
                kind: .removed,
                path: semanticPathComponent(for: previousKey, occurrence: 1),
                changes: &changes
            )
            appendSubtree(
                current,
                kind: .added,
                path: semanticPathComponent(for: currentKey, occurrence: 1),
                changes: &changes
            )
            return
        }

        compareMatched(
            previous,
            current,
            path: semanticPathComponent(for: currentKey, occurrence: 1),
            changes: &changes
        )
    }

    static func compareMatched(
        _ previous: QueryPlanNode,
        _ current: QueryPlanNode,
        path: String,
        changes: inout [QueryPlanNodeChange]
    ) {
        let valueChanges = valueChanges(previous: previous, current: current)
        if !valueChanges.isEmpty {
            changes.append(change(kind: .modified, node: current, path: path, valueChanges: valueChanges))
        }

        let previousNodes = indexedNodes(previous.children)
        let currentNodes = indexedNodes(current.children)
        let matches = longestCommonSubsequenceMatches(previousNodes, currentNodes)
        var previousIndex = 0
        var currentIndex = 0

        for match in matches {
            while previousIndex < match.previousIndex {
                appendChild(
                    previousNodes[previousIndex],
                    kind: .removed,
                    parentPath: path,
                    changes: &changes
                )
                previousIndex += 1
            }
            while currentIndex < match.currentIndex {
                appendChild(
                    currentNodes[currentIndex],
                    kind: .added,
                    parentPath: path,
                    changes: &changes
                )
                currentIndex += 1
            }

            let previousNode = previousNodes[match.previousIndex]
            let currentNode = currentNodes[match.currentIndex]
            let currentPathComponent = semanticPathComponent(
                for: currentNode.key,
                occurrence: currentNode.occurrence
            )
            compareMatched(
                previousNode.node,
                currentNode.node,
                path: "\(path)/\(currentPathComponent)",
                changes: &changes
            )
            previousIndex = match.previousIndex + 1
            currentIndex = match.currentIndex + 1
        }

        while previousIndex < previousNodes.count {
            appendChild(
                previousNodes[previousIndex],
                kind: .removed,
                parentPath: path,
                changes: &changes
            )
            previousIndex += 1
        }
        while currentIndex < currentNodes.count {
            appendChild(
                currentNodes[currentIndex],
                kind: .added,
                parentPath: path,
                changes: &changes
            )
            currentIndex += 1
        }
    }

    static func longestCommonSubsequenceMatches(
        _ previous: [IndexedNode],
        _ current: [IndexedNode]
    ) -> [NodeMatch] {
        guard !previous.isEmpty, !current.isEmpty else { return [] }
        if usesLinearSiblingMatcher(previousCount: previous.count, currentCount: current.count) {
            return orderedLinearMatches(previous, current)
        }

        let cellCount = previous.count * current.count

        let wordCount = (cellCount / 64) + (cellCount.isMultiple(of: 64) ? 0 : 1)
        var skipsPrevious = [UInt64](repeating: 0, count: wordCount)
        var suffixAfter = [Int](repeating: 0, count: current.count + 1)
        var suffixCurrent = suffixAfter

        for previousIndex in stride(from: previous.count - 1, through: 0, by: -1) {
            suffixCurrent[current.count] = 0
            for currentIndex in stride(from: current.count - 1, through: 0, by: -1) {
                if previous[previousIndex].key == current[currentIndex].key {
                    suffixCurrent[currentIndex] = suffixAfter[currentIndex + 1] + 1
                } else if suffixAfter[currentIndex] >= suffixCurrent[currentIndex + 1] {
                    suffixCurrent[currentIndex] = suffixAfter[currentIndex]
                    let bitIndex = (previousIndex * current.count) + currentIndex
                    skipsPrevious[bitIndex / 64] |= UInt64(1) << UInt64(bitIndex % 64)
                } else {
                    suffixCurrent[currentIndex] = suffixCurrent[currentIndex + 1]
                }
            }
            swap(&suffixAfter, &suffixCurrent)
        }

        var matches: [NodeMatch] = []
        matches.reserveCapacity(suffixAfter[0])
        var previousIndex = 0
        var currentIndex = 0
        while previousIndex < previous.count, currentIndex < current.count {
            if previous[previousIndex].key == current[currentIndex].key {
                matches.append(NodeMatch(
                    previousIndex: previousIndex,
                    currentIndex: currentIndex
                ))
                previousIndex += 1
                currentIndex += 1
                continue
            }

            let bitIndex = (previousIndex * current.count) + currentIndex
            let shouldSkipPrevious = skipsPrevious[bitIndex / 64]
                & (UInt64(1) << UInt64(bitIndex % 64)) != 0
            if shouldSkipPrevious {
                previousIndex += 1
            } else {
                currentIndex += 1
            }
        }
        return matches
    }

    static func orderedLinearMatches(
        _ previous: [IndexedNode],
        _ current: [IndexedNode]
    ) -> [NodeMatch] {
        var prefixCount = 0
        let shortestCount = min(previous.count, current.count)
        while prefixCount < shortestCount,
              previous[prefixCount].key == current[prefixCount].key {
            prefixCount += 1
        }

        var previousEnd = previous.count
        var currentEnd = current.count
        var suffixMatches: [NodeMatch] = []
        while previousEnd > prefixCount, currentEnd > prefixCount,
              previous[previousEnd - 1].key == current[currentEnd - 1].key {
            previousEnd -= 1
            currentEnd -= 1
            suffixMatches.append(NodeMatch(
                previousIndex: previousEnd,
                currentIndex: currentEnd
            ))
        }

        var matches = (0..<prefixCount).map {
            NodeMatch(previousIndex: $0, currentIndex: $0)
        }
        let middleCount = min(previousEnd - prefixCount, currentEnd - prefixCount)
        for offset in 0..<middleCount {
            let previousIndex = prefixCount + offset
            let currentIndex = prefixCount + offset
            if previous[previousIndex].key == current[currentIndex].key {
                matches.append(NodeMatch(
                    previousIndex: previousIndex,
                    currentIndex: currentIndex
                ))
            }
        }
        matches.append(contentsOf: suffixMatches.reversed())
        return matches
    }

    static func appendChild(
        _ indexedNode: IndexedNode,
        kind: QueryPlanNodeChangeKind,
        parentPath: String,
        changes: inout [QueryPlanNodeChange]
    ) {
        let childPathComponent = semanticPathComponent(
            for: indexedNode.key,
            occurrence: indexedNode.occurrence
        )
        appendSubtree(
            indexedNode.node,
            kind: kind,
            path: "\(parentPath)/\(childPathComponent)",
            changes: &changes
        )
    }

    static func appendSubtree(
        _ node: QueryPlanNode,
        kind: QueryPlanNodeChangeKind,
        path: String,
        changes: inout [QueryPlanNodeChange]
    ) {
        changes.append(change(
            kind: kind,
            node: node,
            path: path,
            valueChanges: allValueChanges(for: node, kind: kind)
        ))

        for child in indexedNodes(node.children) {
            appendSubtree(
                child.node,
                kind: kind,
                path: "\(path)/\(semanticPathComponent(for: child.key, occurrence: child.occurrence))",
                changes: &changes
            )
        }
    }

    static func change(
        kind: QueryPlanNodeChangeKind,
        node: QueryPlanNode,
        path: String,
        valueChanges: [QueryPlanNodeValueChange]
    ) -> QueryPlanNodeChange {
        QueryPlanNodeChange(
            kind: kind,
            semanticPathID: path,
            operation: node.operation,
            relation: node.relation,
            schema: node.schema,
            alias: node.alias,
            valueChanges: valueChanges
        )
    }

    static func indexedNodes(_ nodes: [QueryPlanNode]) -> [IndexedNode] {
        var occurrences: [SemanticKey: Int] = [:]
        return nodes.map { node in
            let key = semanticKey(for: node)
            let occurrence = occurrences[key, default: 0] + 1
            occurrences[key] = occurrence
            return IndexedNode(node: node, key: key, occurrence: occurrence)
        }
    }

    static func semanticKey(for node: QueryPlanNode) -> SemanticKey {
        let identifyingProperties = QueryPlanLabels.visibleProperties(of: node)
            .filter { identifyingPropertyKeys.contains($0.key) }
        return SemanticKey(
            operation: node.operation,
            schema: node.schema,
            relation: node.relation,
            alias: node.alias,
            identifyingProperties: identifyingProperties
        )
    }

    static func semanticPathComponent(for key: SemanticKey, occurrence: Int) -> String {
        "\(key.pathComponent)#\(occurrence)"
    }

    static func valueChanges(
        previous: QueryPlanNode,
        current: QueryPlanNode
    ) -> [QueryPlanNodeValueChange] {
        let previousValues = values(for: previous)
        let currentValues = values(for: current)
        let keys = Set(previousValues.keys).union(currentValues.keys).sorted()

        return keys.compactMap { key in
            let previousValue = previousValues[key]
            let currentValue = currentValues[key]
            guard previousValue != currentValue else { return nil }
            return QueryPlanNodeValueChange(
                category: key.category,
                name: displayName(for: key),
                previousValue: previousValue,
                currentValue: currentValue
            )
        }
    }

    static func allValueChanges(
        for node: QueryPlanNode,
        kind: QueryPlanNodeChangeKind
    ) -> [QueryPlanNodeValueChange] {
        values(for: node).sorted { $0.key < $1.key }.map { key, value in
            QueryPlanNodeValueChange(
                category: key.category,
                name: displayName(for: key),
                previousValue: kind == .removed ? value : nil,
                currentValue: kind == .added ? value : nil
            )
        }
    }

    static func values(for node: QueryPlanNode) -> [ValueKey: String] {
        var values: [ValueKey: String] = [:]

        func addMetric<T>(_ name: String, _ value: T?) {
            if let value {
                values[ValueKey(category: .metric, name: name)] = String(describing: value)
            }
        }

        addMetric("Estimated Startup Cost", node.estimatedStartupCost)
        addMetric("Estimated Total Cost", node.estimatedTotalCost)
        addMetric("Estimated Rows", node.estimatedRows)
        addMetric("Estimated Width", node.estimatedWidth)
        addMetric("Actual Startup Time", node.actualStartupTime)
        addMetric("Actual Total Time", node.actualTotalTime)
        addMetric("Actual Rows", node.actualRows)
        addMetric("Actual Loops", node.actualLoops)

        for property in QueryPlanLabels.visibleProperties(of: node) {
            values[ValueKey(category: .property, name: property.key)] = property.value
        }
        return values
    }

    static func displayName(for key: ValueKey) -> String {
        guard key.category == .metric else { return key.name }
        switch key.name {
        case "Estimated Startup Cost": return String(localized: "Estimated Startup Cost")
        case "Estimated Total Cost": return String(localized: "Estimated Total Cost")
        case "Estimated Rows": return String(localized: "Estimated Rows")
        case "Estimated Width": return String(localized: "Estimated Width")
        case "Actual Startup Time": return String(localized: "Actual Startup Time")
        case "Actual Total Time": return String(localized: "Actual Total Time")
        case "Actual Rows": return String(localized: "Actual Rows")
        case "Actual Loops": return String(localized: "Actual Loops")
        default: return key.name
        }
    }

    static func changeOrder(_ lhs: QueryPlanNodeChange, _ rhs: QueryPlanNodeChange) -> Bool {
        if lhs.semanticPathID != rhs.semanticPathID {
            return lhs.semanticPathID < rhs.semanticPathID
        }
        return kindOrder(lhs.kind) < kindOrder(rhs.kind)
    }

    static func kindOrder(_ kind: QueryPlanNodeChangeKind) -> Int {
        switch kind {
        case .removed: 0
        case .added: 1
        case .modified: 2
        }
    }
}
