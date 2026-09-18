import Foundation

public enum SpannerPlanRenderer {
    public static let columnName = "QUERY PLAN"
    public static let noPlanLine = "No query plan returned"

    private static let emulatorPlaceholderName = "No query plan"
    private static let scalarKind = "SCALAR"
    private static let indentUnit = "  "

    public static func lines(_ plan: SpannerQueryPlan?) -> [String] {
        guard let nodes = plan?.nodes, let root = rootNode(in: nodes) else { return [noPlanLine] }
        if nodes.count == 1, root.displayName == emulatorPlaceholderName { return [noPlanLine] }
        let nodesByIndex = Dictionary(nodes.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        return render(root: root, nodesByIndex: nodesByIndex)
    }

    private static func rootNode(in nodes: [SpannerPlanNode]) -> SpannerPlanNode? {
        nodes.first { $0.index == 0 } ?? nodes.first
    }

    private static func render(root: SpannerPlanNode, nodesByIndex: [Int: SpannerPlanNode]) -> [String] {
        var lines: [String] = []
        var visited: Set<Int> = []
        var pending: [(node: SpannerPlanNode, depth: Int)] = [(root, 0)]
        while let (node, depth) = pending.popLast() {
            guard visited.insert(node.index).inserted else { continue }
            lines.append(String(repeating: indentUnit, count: depth) + line(for: node, nodesByIndex: nodesByIndex))
            let children = relationalChildren(of: node, nodesByIndex: nodesByIndex).filter { !visited.contains($0.index) }
            pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
        return lines
    }

    private static func line(for node: SpannerPlanNode, nodesByIndex: [Int: SpannerPlanNode]) -> String {
        var text = node.displayName.isEmpty ? node.kind ?? "Operator" : node.displayName
        if let summary = summary(of: node) {
            text += " (\(summary))"
        }
        for annotation in scalarAnnotations(of: node, nodesByIndex: nodesByIndex) {
            text += " [\(annotation)]"
        }
        return text
    }

    private static func summary(of node: SpannerPlanNode) -> String? {
        if let description = node.shortDescription, !description.isEmpty { return description }
        guard case .string(let target) = node.metadata["scan_target"] else { return nil }
        guard case .string(let scanType) = node.metadata["scan_type"] else { return target }
        return "\(scanType): \(target)"
    }

    private static func scalarAnnotations(of node: SpannerPlanNode, nodesByIndex: [Int: SpannerPlanNode]) -> [String] {
        node.childLinks.compactMap { link in
            guard let child = nodesByIndex[link.childIndex], child.kind == scalarKind,
                  let description = child.shortDescription, !description.isEmpty
            else {
                return nil
            }
            let label = link.type.flatMap { $0.isEmpty ? nil : $0 } ?? child.displayName
            return "\(label): \(description)"
        }
    }

    private static func relationalChildren(
        of node: SpannerPlanNode,
        nodesByIndex: [Int: SpannerPlanNode]
    ) -> [SpannerPlanNode] {
        node.childLinks.compactMap { link in
            guard let child = nodesByIndex[link.childIndex], child.kind != scalarKind else { return nil }
            return child
        }
    }
}
