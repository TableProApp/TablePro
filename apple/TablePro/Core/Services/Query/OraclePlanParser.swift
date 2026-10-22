//
//  OraclePlanParser.swift
//  TablePro
//

import Foundation

struct OraclePlanParser: QueryPlanParser {
    private static let maximumDepth = 256

    func parse(rawText: String) -> QueryPlan? {
        guard let data = rawText.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        let steps = rows.compactMap(Step.init)
        guard !steps.isEmpty else { return nil }

        let ids = Set(steps.map(\.id))
        var childrenByParent: [Int: [Step]] = [:]
        var roots: [Step] = []
        for step in steps.sorted(by: { $0.id < $1.id }) {
            if let parent = step.parentId, parent != step.id, ids.contains(parent) {
                childrenByParent[parent, default: []].append(step)
            } else {
                roots.append(step)
            }
        }

        func build(_ step: Step, depth: Int) -> QueryPlanNode {
            let children = depth < Self.maximumDepth
                ? (childrenByParent[step.id] ?? []).map { build($0, depth: depth + 1) }
                : []
            return step.node(children: children)
        }

        guard let root = QueryPlanTreeBuilder.root(from: roots.map { build($0, depth: 0) }) else { return nil }
        let elapsed = steps.compactMap(\.lastElapsedMicroseconds).max()
        var plan = QueryPlan(
            rootNode: root,
            planningTime: nil,
            executionTime: elapsed.map { $0 / 1_000 },
            rawText: rawText
        )
        plan.computeCostFractions()
        return plan
    }

    private struct Step {
        let id: Int
        let parentId: Int?
        let row: [String: Any]

        init?(row: [String: Any]) {
            guard let id = Self.int(row["ID"]) else { return nil }
            self.id = id
            self.parentId = Self.int(row["PARENT_ID"])
            self.row = row
        }

        var lastElapsedMicroseconds: Double? { Self.double(row["LAST_ELAPSED_TIME"]) }

        func node(children: [QueryPlanNode]) -> QueryPlanNode {
            let operation = [text("OPERATION"), text("OPTIONS")].compactMap { $0 }.joined(separator: " ")
            let isIndex = text("OBJECT_TYPE")?.uppercased().hasPrefix("INDEX") == true
            var properties: [String: String] = [:]
            if isIndex, let index = text("OBJECT_NAME") { properties["Index Name"] = index }
            properties["Access Predicates"] = text("ACCESS_PREDICATES")
            properties["Filter Predicates"] = text("FILTER_PREDICATES")
            properties["Bytes"] = text("BYTES")
            properties["CPU Cost"] = text("CPU_COST")
            properties["I/O Cost"] = text("IO_COST")
            properties["Partition Start"] = text("PARTITION_START")
            properties["Partition Stop"] = text("PARTITION_STOP")
            properties["Query Block"] = text("QBLOCK_NAME")
            properties["Buffer Gets"] = text("LAST_CR_BUFFER_GETS")
            properties["Disk Reads"] = text("LAST_DISK_READS")
            properties["Memory Used"] = text("LAST_MEMORY_USED")
            properties["Temp Space"] = text("LAST_TEMPSEG_SIZE")

            // V$SQL_PLAN_STATISTICS_ALL totals rows and time over every start; the plan model holds per-start values.
            let starts = Self.int(row["LAST_STARTS"])
            var actualRows: Int?
            var actualTime: Double?
            if let starts, starts > 0 {
                actualRows = Self.double(row["LAST_OUTPUT_ROWS"]).flatMap { Self.bounded($0 / Double(starts)) }
                actualTime = lastElapsedMicroseconds.map { $0 / 1_000 / Double(starts) }
            } else if starts == 0 {
                properties["Execution"] = String(localized: "Never executed")
            }

            var node = QueryPlanNode(
                operation: operation.isEmpty ? "Unknown" : operation,
                relation: isIndex ? nil : text("OBJECT_NAME"),
                schema: text("OBJECT_OWNER"),
                alias: text("OBJECT_ALIAS"),
                estimatedStartupCost: nil,
                estimatedTotalCost: Self.double(row["COST"]),
                estimatedRows: Self.int(row["CARDINALITY"]),
                estimatedWidth: nil,
                actualStartupTime: nil,
                actualTotalTime: actualTime,
                actualRows: actualRows,
                actualLoops: starts,
                properties: properties,
                children: children
            )
            node.reportedTotalActualRows = Self.int(row["LAST_OUTPUT_ROWS"])
            return node
        }

        private func text(_ key: String) -> String? {
            guard let value = row[key] else { return nil }
            let text = "\(value)".trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        static func double(_ value: Any?) -> Double? {
            switch value {
            case let number as NSNumber: return number.doubleValue
            case let text as String: return Double(text)
            default: return nil
            }
        }

        static func int(_ value: Any?) -> Int? {
            double(value).flatMap(bounded)
        }

        static func bounded(_ value: Double) -> Int? {
            let rounded = value.rounded()
            guard rounded.isFinite, rounded >= Double(Int.min), rounded < Double(Int.max) else { return nil }
            return Int(rounded)
        }
    }
}
