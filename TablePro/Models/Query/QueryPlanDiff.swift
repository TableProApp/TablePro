//
//  QueryPlanDiff.swift
//  TablePro
//
//  What changed between an earlier plan and the current one.
//
//  Siblings are matched with the standard library's `CollectionDifference`, which is Myers' diff
//  over the nodes' semantic keys. A plan node has no stable identity across two runs, so identity
//  is what the node says it is: the operation, the relation it reads, its alias, and the properties
//  that decide what kind of node it is (the join type, the index it uses, the CTE it belongs to).
//
//  Everything here is a pure function over two parsed plans, so it can be measured in a test and
//  run off the main actor without dragging a view along.
//

import Foundation

struct QueryPlanNodeChange: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case added
        case removed
        case changed
    }

    let kind: Kind
    let path: String
    let operation: String
    let relation: String?
    let schema: String?
    let alias: String?
    let fieldChanges: [QueryPlanFieldChange]

    var id: String { "\(kind.rawValue):\(path)" }

    var title: String {
        guard let relation, !relation.isEmpty else { return operation }
        return "\(operation) · \(relation)"
    }
}

/// The one-line answer the pane leads with. A list of forty field changes does not tell a reader
/// whether the query got better, and that is the only question they opened the comparison to ask.
enum QueryPlanVerdict: Hashable, Sendable {
    /// Both plans reported an execution time and the difference is outside the noise band.
    case slower(ratio: Double)
    case faster(ratio: Double)
    /// Nodes were added or removed, with no measured time to judge the effect by.
    case shapeChanged
    /// Same nodes, but some of their values moved.
    case valuesChanged
    case unchanged
}

struct QueryPlanDiff: Hashable, Sendable {
    /// Two runs of an unchanged plan differ by a few percent on timing alone. Below this, the
    /// comparison says the run is unchanged rather than manufacturing a regression out of jitter.
    static let noiseRatio = 1.15

    let verdict: QueryPlanVerdict
    let summary: [QueryPlanFieldChange]
    let nodeChanges: [QueryPlanNodeChange]

    var hasChanges: Bool {
        verdict != .unchanged
    }

    static func compare(baseline: QueryPlan, current: QueryPlan) -> QueryPlanDiff {
        let summary = summaryChanges(baseline: baseline, current: current)
        var nodeChanges: [QueryPlanNodeChange] = []
        compareRoots(baseline.rootNode, current.rootNode, into: &nodeChanges)
        return QueryPlanDiff(
            verdict: verdict(summary: summary, nodeChanges: nodeChanges),
            summary: summary,
            nodeChanges: nodeChanges
        )
    }
}

// MARK: - Verdict

private extension QueryPlanDiff {
    static func verdict(
        summary: [QueryPlanFieldChange],
        nodeChanges: [QueryPlanNodeChange]
    ) -> QueryPlanVerdict {
        if let executionRatio = summary.first(where: { $0.field == .summary(.executionTime) })?.ratio {
            if executionRatio >= noiseRatio { return .slower(ratio: executionRatio) }
            if executionRatio <= 1 / noiseRatio { return .faster(ratio: 1 / executionRatio) }
        }
        if nodeChanges.contains(where: { $0.kind != .changed }) { return .shapeChanged }
        if !nodeChanges.isEmpty || summary.contains(where: isMeaningful) { return .valuesChanged }
        return .unchanged
    }

    /// Two runs of one unchanged plan differ by a few percent on timing alone. Counting that as a
    /// change makes every rerun read as a difference, which is exactly the noise that makes a
    /// comparison feature untrustworthy. A timing metric therefore only counts once it leaves the
    /// noise band; everything else counts as soon as it moves.
    static func isMeaningful(_ change: QueryPlanFieldChange) -> Bool {
        guard change.hasChange else { return false }
        guard change.field.unit == .milliseconds else { return true }
        guard let ratio = change.ratio else { return true }
        return ratio >= noiseRatio || ratio <= 1 / noiseRatio
    }

    static func summaryChanges(baseline: QueryPlan, current: QueryPlan) -> [QueryPlanFieldChange] {
        let values: [(QueryPlanSummaryMetric, Double?, Double?)] = [
            (.totalCost, baseline.rootNode.estimatedTotalCost, current.rootNode.estimatedTotalCost),
            (.estimatedRows, baseline.rootNode.estimatedRows.map(Double.init), current.rootNode.estimatedRows.map(Double.init)),
            (.planningTime, baseline.planningTime, current.planningTime),
            (.executionTime, baseline.executionTime, current.executionTime),
            (.nodeCount, Double(nodeCount(in: baseline.rootNode)), Double(nodeCount(in: current.rootNode))),
        ]
        return values.map { metric, before, after in
            QueryPlanFieldChange(
                field: .summary(metric),
                before: before.map(QueryPlanFieldValue.number),
                after: after.map(QueryPlanFieldValue.number)
            )
        }
    }

    static func nodeCount(in node: QueryPlanNode) -> Int {
        node.children.reduce(1) { $0 + nodeCount(in: $1) }
    }
}

// MARK: - Node identity

private extension QueryPlanDiff {
    /// The properties that say what kind of node this is rather than how it performed. A node whose
    /// join type or index changed is a different node, not the same node with a different number.
    static let identifyingPropertyKeys: Set<String> = [
        "CTE Name",
        "Index Name",
        "Join Type",
        "Parent Relationship",
        "Strategy",
        "Subplan Name",
    ]

    struct NodeKey: Hashable {
        let operation: String
        let schema: String?
        let relation: String?
        let alias: String?
        let identifiers: [String]
    }

    struct KeyedNode {
        let node: QueryPlanNode
        let key: NodeKey
        let occurrence: Int
    }

    static func key(for node: QueryPlanNode) -> NodeKey {
        NodeKey(
            operation: node.operation,
            schema: node.schema,
            relation: node.relation,
            alias: node.alias,
            identifiers: node.properties
                .filter { identifyingPropertyKeys.contains($0.key) }
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
        )
    }

    static func keyed(_ nodes: [QueryPlanNode]) -> [KeyedNode] {
        var occurrences: [NodeKey: Int] = [:]
        return nodes.map { node in
            let key = key(for: node)
            let occurrence = occurrences[key, default: 0] + 1
            occurrences[key] = occurrence
            return KeyedNode(node: node, key: key, occurrence: occurrence)
        }
    }

    /// A path that is stable between two runs and unique inside one plan, so SwiftUI can key a row
    /// by it and a test can assert on it.
    static func pathComponent(_ keyed: KeyedNode) -> String {
        var component = keyed.node.operation
        if let relation = keyed.node.relation, !relation.isEmpty {
            component += "[\(relation)]"
        }
        if let alias = keyed.node.alias, !alias.isEmpty, alias != keyed.node.relation {
            component += "(\(alias))"
        }
        return component.replacingOccurrences(of: "/", with: "\u{2215}") + "#\(keyed.occurrence)"
    }
}

// MARK: - Tree walk

private extension QueryPlanDiff {
    static func compareRoots(
        _ baseline: QueryPlanNode,
        _ current: QueryPlanNode,
        into changes: inout [QueryPlanNodeChange]
    ) {
        let baselineKeyed = keyed([baseline])[0]
        let currentKeyed = keyed([current])[0]
        guard baselineKeyed.key == currentKeyed.key else {
            appendSubtree(baseline, kind: .removed, path: pathComponent(baselineKeyed), into: &changes)
            appendSubtree(current, kind: .added, path: pathComponent(currentKeyed), into: &changes)
            return
        }
        compareMatched(baseline, current, path: pathComponent(currentKeyed), into: &changes)
    }

    static func compareMatched(
        _ baseline: QueryPlanNode,
        _ current: QueryPlanNode,
        path: String,
        into changes: inout [QueryPlanNodeChange]
    ) {
        let fieldChanges = changedFields(baseline: baseline, current: current)
        if !fieldChanges.isEmpty {
            changes.append(QueryPlanNodeChange(
                kind: .changed,
                path: path,
                operation: current.operation,
                relation: current.relation,
                schema: current.schema,
                alias: current.alias,
                fieldChanges: fieldChanges
            ))
        }

        let baselineChildren = keyed(baseline.children)
        let currentChildren = keyed(current.children)
        let alignment = align(baselineChildren, currentChildren)

        for offset in alignment.removed {
            let child = baselineChildren[offset]
            appendSubtree(
                child.node,
                kind: .removed,
                path: "\(path)/\(pathComponent(child))",
                into: &changes
            )
        }
        for offset in alignment.inserted {
            let child = currentChildren[offset]
            appendSubtree(
                child.node,
                kind: .added,
                path: "\(path)/\(pathComponent(child))",
                into: &changes
            )
        }
        for match in alignment.matches {
            let child = currentChildren[match.current]
            compareMatched(
                baselineChildren[match.baseline].node,
                child.node,
                path: "\(path)/\(pathComponent(child))",
                into: &changes
            )
        }
    }

    struct Alignment {
        struct Match {
            let baseline: Int
            let current: Int
        }

        let matches: [Match]
        let removed: [Int]
        let inserted: [Int]
    }

    /// `CollectionDifference` reports removals as offsets into the baseline and insertions as
    /// offsets into the current list, and applying one then the other turns the baseline into the
    /// current list. Everything it did not touch therefore pairs up in order, which is the match
    /// set.
    static func align(_ baseline: [KeyedNode], _ current: [KeyedNode]) -> Alignment {
        let difference = current.map(\.key).difference(from: baseline.map(\.key))
        var removed: Set<Int> = []
        var inserted: Set<Int> = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var matches: [Alignment.Match] = []
        var baselineIndex = 0
        var currentIndex = 0
        while baselineIndex < baseline.count, currentIndex < current.count {
            if removed.contains(baselineIndex) {
                baselineIndex += 1
                continue
            }
            if inserted.contains(currentIndex) {
                currentIndex += 1
                continue
            }
            matches.append(Alignment.Match(baseline: baselineIndex, current: currentIndex))
            baselineIndex += 1
            currentIndex += 1
        }
        return Alignment(matches: matches, removed: removed.sorted(), inserted: inserted.sorted())
    }

    static func appendSubtree(
        _ node: QueryPlanNode,
        kind: QueryPlanNodeChange.Kind,
        path: String,
        into changes: inout [QueryPlanNodeChange]
    ) {
        changes.append(QueryPlanNodeChange(
            kind: kind,
            path: path,
            operation: node.operation,
            relation: node.relation,
            schema: node.schema,
            alias: node.alias,
            fieldChanges: fields(of: node).sorted { $0.key.sortOrder < $1.key.sortOrder }.map { field, value in
                QueryPlanFieldChange(
                    field: field,
                    before: kind == .removed ? value : nil,
                    after: kind == .added ? value : nil
                )
            }
        ))

        for child in keyed(node.children) {
            appendSubtree(
                child.node,
                kind: kind,
                path: "\(path)/\(pathComponent(child))",
                into: &changes
            )
        }
    }
}

// MARK: - Fields

private extension QueryPlanDiff {
    static func changedFields(
        baseline: QueryPlanNode,
        current: QueryPlanNode
    ) -> [QueryPlanFieldChange] {
        let before = fields(of: baseline)
        let after = fields(of: current)
        return Set(before.keys).union(after.keys)
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { field in
                let change = QueryPlanFieldChange(field: field, before: before[field], after: after[field])
                return change.hasChange ? change : nil
            }
    }

    /// Reads `properties` directly rather than through `QueryPlanLabels.visibleProperties`, which
    /// drops any value spelled `0` or `false`. Dropping those is right for a node inspector, where
    /// they are noise, and wrong here: `Rows Removed by Filter` falling from 1000 to 0 is the
    /// improvement the reader opened the comparison to find, and hiding the zero reported it as the
    /// property being removed.
    static func fields(of node: QueryPlanNode) -> [QueryPlanField: QueryPlanFieldValue] {
        var fields: [QueryPlanField: QueryPlanFieldValue] = [:]
        for metric in QueryPlanMetric.allCases {
            guard let value = metric.value(of: node) else { continue }
            fields[.metric(metric)] = .number(value)
        }
        for (key, value) in node.properties where !QueryPlanLabels.hiddenPropertyKeys.contains(key) {
            fields[.property(key)] = .text(value)
        }
        return fields
    }
}
