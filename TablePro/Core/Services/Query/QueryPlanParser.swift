//
//  QueryPlanParser.swift
//  TablePro
//
//  Parses EXPLAIN output into QueryPlan tree for visualization.
//

import Foundation
import os

private let logger = Logger(subsystem: "com.TablePro", category: "QueryPlanParser")

// MARK: - Parser Protocol

protocol QueryPlanParser {
    func parse(rawText: String) -> QueryPlan?
}

// MARK: - PostgreSQL JSON Parser

/// Parses PostgreSQL `EXPLAIN (FORMAT JSON)` and `EXPLAIN (ANALYZE, FORMAT JSON)` output.
struct PostgreSQLPlanParser: QueryPlanParser {
    func parse(rawText: String) -> QueryPlan? {
        guard let data = rawText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let planDict = json.first,
              let plan = planDict["Plan"] as? [String: Any]
        else {
            logger.debug("Failed to parse PostgreSQL EXPLAIN JSON")
            return nil
        }

        let planningTime = planDict["Planning Time"] as? Double
        let executionTime = planDict["Execution Time"] as? Double
        let rootNode = parseNode(plan)

        var queryPlan = QueryPlan(
            rootNode: rootNode,
            planningTime: planningTime,
            executionTime: executionTime,
            rawText: rawText
        )
        queryPlan.computeCostFractions()
        return queryPlan
    }

    private func parseNode(_ dict: [String: Any]) -> QueryPlanNode {
        let children: [QueryPlanNode]
        if let plans = dict["Plans"] as? [[String: Any]] {
            children = plans.map { parseNode($0) }
        } else {
            children = []
        }

        // Collect all properties except the ones we extract explicitly
        let knownKeys: Set<String> = [
            "Node Type", "Relation Name", "Schema", "Alias",
            "Startup Cost", "Total Cost", "Plan Rows", "Plan Width",
            "Actual Startup Time", "Actual Total Time", "Actual Rows", "Actual Loops",
            "Plans",
        ]
        var properties: [String: String] = [:]
        for (key, value) in dict where !knownKeys.contains(key) {
            properties[key] = "\(value)"
        }

        return QueryPlanNode(
            operation: dict["Node Type"] as? String ?? "Unknown",
            relation: dict["Relation Name"] as? String,
            schema: dict["Schema"] as? String,
            alias: dict["Alias"] as? String,
            estimatedStartupCost: dict["Startup Cost"] as? Double,
            estimatedTotalCost: dict["Total Cost"] as? Double,
            estimatedRows: dict["Plan Rows"] as? Int,
            estimatedWidth: dict["Plan Width"] as? Int,
            actualStartupTime: dict["Actual Startup Time"] as? Double,
            actualTotalTime: dict["Actual Total Time"] as? Double,
            actualRows: dict["Actual Rows"] as? Int,
            actualLoops: dict["Actual Loops"] as? Int,
            properties: properties,
            children: children
        )
    }
}

// MARK: - MySQL JSON Parser

/// Parses MySQL and MariaDB `EXPLAIN FORMAT=JSON` output.
/// Handles both MySQL's flat structure and MariaDB's nested structure
/// (query_block → filesort → temporary_table → nested_loop).
struct MySQLPlanParser: QueryPlanParser {
    func parse(rawText: String) -> QueryPlan? {
        guard let data = rawText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let queryBlock = json["query_block"] as? [String: Any]
        else {
            logger.debug("Failed to parse MySQL EXPLAIN JSON")
            return nil
        }

        let cost = queryBlock["cost"] as? Double
            ?? (queryBlock["cost_info"] as? [String: Any])?["query_cost"].flatMap { Double("\($0)") }
        let rootNode = parseBlock(queryBlock, operation: "Query Block", cost: cost)

        var queryPlan = QueryPlan(
            rootNode: rootNode,
            planningTime: nil,
            executionTime: nil,
            rawText: rawText
        )
        queryPlan.computeCostFractions()
        return queryPlan
    }

    /// Recursively parse a JSON dict, looking for known operation keys.
    private func parseBlock(_ dict: [String: Any], operation: String, cost: Double?) -> QueryPlanNode {
        var children: [QueryPlanNode] = []

        // Direct table access
        if let table = dict["table"] as? [String: Any] {
            children.append(parseTable(table))
        }

        // Nested loop (array of table entries)
        if let nestedLoop = dict["nested_loop"] as? [[String: Any]] {
            for item in nestedLoop {
                if let table = item["table"] as? [String: Any] {
                    children.append(parseTable(table))
                }
            }
        }

        // MariaDB: filesort wraps the inner plan
        if let filesort = dict["filesort"] as? [String: Any] {
            let sortKey = filesort["sort_key"] as? String
            let sortOp = sortKey.map { "Sort (\($0))" } ?? "Sort"
            let inner = parseBlock(filesort, operation: sortOp, cost: nil)
            if !inner.children.isEmpty {
                children = [inner]
            }
        }

        // MariaDB: temporary_table wraps nested_loop
        if let tempTable = dict["temporary_table"] as? [String: Any] {
            let inner = parseBlock(tempTable, operation: "Temporary Table", cost: nil)
            if !inner.children.isEmpty {
                children = inner.children
            }
        }

        // MySQL: ordering_operation
        if let orderingOp = dict["ordering_operation"] as? [String: Any] {
            let inner = parseBlock(orderingOp, operation: "Sort", cost: nil)
            children.append(inner)
        }

        // MySQL: grouping_operation
        if let groupingOp = dict["grouping_operation"] as? [String: Any] {
            let inner = parseBlock(groupingOp, operation: "Group", cost: nil)
            children.append(inner)
        }

        return QueryPlanNode(
            operation: operation,
            relation: nil, schema: nil, alias: nil,
            estimatedStartupCost: nil,
            estimatedTotalCost: cost,
            estimatedRows: nil, estimatedWidth: nil,
            actualStartupTime: nil, actualTotalTime: nil,
            actualRows: nil, actualLoops: nil,
            properties: [:],
            children: children
        )
    }

    private func parseTable(_ table: [String: Any]) -> QueryPlanNode {
        // MariaDB uses "cost" directly, MySQL uses "cost_info.read_cost"
        let cost = table["cost"] as? Double
            ?? (table["cost_info"] as? [String: Any])?["read_cost"].flatMap { Double("\($0)") }
        let rows = table["rows"] as? Int
            ?? table["rows_examined_per_scan"] as? Int
            ?? table["rows_produced_per_join"] as? Int

        var properties: [String: String] = [:]
        if let key = table["key"] as? String { properties["Key"] = key }
        if let ref = table["ref"] as? [String] { properties["Ref"] = ref.joined(separator: ", ") }
        if let cond = table["attached_condition"] as? String { properties["Filter"] = cond }
        if let filtered = table["filtered"] as? Double, filtered < 100 {
            properties["Filtered"] = String(format: "%.0f%%", filtered)
        }

        return QueryPlanNode(
            operation: table["access_type"] as? String ?? "ALL",
            relation: table["table_name"] as? String,
            schema: nil, alias: nil,
            estimatedStartupCost: nil,
            estimatedTotalCost: cost,
            estimatedRows: rows,
            estimatedWidth: nil,
            actualStartupTime: nil, actualTotalTime: nil,
            actualRows: nil, actualLoops: nil,
            properties: properties,
            children: []
        )
    }
}

// MARK: - SQLite Parser

/// Parses SQLite `EXPLAIN QUERY PLAN` output (id/parent/notused/detail columns).
struct SQLitePlanParser: QueryPlanParser {
    func parse(rawText: String) -> QueryPlan? {
        let lines = rawText.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        // SQLite EXPLAIN QUERY PLAN returns: id | parent | notused | detail
        // Parse tab-separated or pipe-separated rows
        var nodes: [(id: Int, parent: Int, detail: String)] = []
        for line in lines {
            let parts = line.components(separatedBy: "\t")
            if parts.count >= 4,
               let id = Int(parts[0].trimmingCharacters(in: .whitespaces)),
               let parent = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                nodes.append((id: id, parent: parent, detail: parts[3].trimmingCharacters(in: .whitespaces)))
            } else {
                // Fallback: treat entire line as a detail node
                nodes.append((id: nodes.count, parent: -1, detail: line))
            }
        }

        guard !nodes.isEmpty else { return nil }

        func buildChildren(parentId: Int) -> [QueryPlanNode] {
            nodes.filter { $0.parent == parentId }.map { node in
                QueryPlanNode(
                    operation: node.detail,
                    relation: nil, schema: nil, alias: nil,
                    estimatedStartupCost: nil, estimatedTotalCost: nil,
                    estimatedRows: nil, estimatedWidth: nil,
                    actualStartupTime: nil, actualTotalTime: nil,
                    actualRows: nil, actualLoops: nil,
                    properties: [:],
                    children: buildChildren(parentId: node.id)
                )
            }
        }

        // Find the minimum parent ID to use as the virtual root parent
        let minParent = nodes.map(\.parent).min() ?? 0
        let rootChildren = buildChildren(parentId: minParent)
        let rootNode: QueryPlanNode
        if rootChildren.count == 1 {
            rootNode = rootChildren[0]
        } else {
            rootNode = QueryPlanNode(
                operation: "Query Plan",
                relation: nil, schema: nil, alias: nil,
                estimatedStartupCost: nil, estimatedTotalCost: nil,
                estimatedRows: nil, estimatedWidth: nil,
                actualStartupTime: nil, actualTotalTime: nil,
                actualRows: nil, actualLoops: nil,
                properties: [:],
                children: rootChildren
            )
        }

        return QueryPlan(rootNode: rootNode, planningTime: nil, executionTime: nil, rawText: rawText)
    }
}

// MARK: - Indented Text Parser (ClickHouse, DuckDB)

/// Parses indented text EXPLAIN output into a tree based on leading whitespace depth.
/// Works for ClickHouse EXPLAIN, DuckDB EXPLAIN, and any text plan with indentation hierarchy.
struct IndentedTextPlanParser: QueryPlanParser {
    func parse(rawText: String) -> QueryPlan? {
        let lines = rawText.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        struct ParsedLine {
            let indent: Int
            let text: String
        }
        let parsed: [ParsedLine] = lines.map { line in
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let indent = (line as NSString).length - (String(trimmed) as NSString).length
            return ParsedLine(indent: indent, text: String(trimmed))
        }

        // Build tree from indentation
        func buildNodes(from startIndex: Int, parentIndent: Int) -> (nodes: [QueryPlanNode], nextIndex: Int) {
            var nodes: [QueryPlanNode] = []
            var i = startIndex

            while i < parsed.count {
                let line = parsed[i]
                if line.indent <= parentIndent && i > startIndex {
                    break
                }

                let children: [QueryPlanNode]
                let nextI: Int
                if i + 1 < parsed.count && parsed[i + 1].indent > line.indent {
                    let result = buildNodes(from: i + 1, parentIndent: line.indent)
                    children = result.nodes
                    nextI = result.nextIndex
                } else {
                    children = []
                    nextI = i + 1
                }

                nodes.append(QueryPlanNode(
                    operation: line.text,
                    relation: nil, schema: nil, alias: nil,
                    estimatedStartupCost: nil, estimatedTotalCost: nil,
                    estimatedRows: nil, estimatedWidth: nil,
                    actualStartupTime: nil, actualTotalTime: nil,
                    actualRows: nil, actualLoops: nil,
                    properties: [:],
                    children: children
                ))
                i = nextI
            }
            return (nodes, i)
        }

        let result = buildNodes(from: 0, parentIndent: -1)
        let rootNode: QueryPlanNode
        if result.nodes.count == 1 {
            rootNode = result.nodes[0]
        } else {
            rootNode = QueryPlanNode(
                operation: "Query Plan",
                relation: nil, schema: nil, alias: nil,
                estimatedStartupCost: nil, estimatedTotalCost: nil,
                estimatedRows: nil, estimatedWidth: nil,
                actualStartupTime: nil, actualTotalTime: nil,
                actualRows: nil, actualLoops: nil,
                properties: [:],
                children: result.nodes
            )
        }

        return QueryPlan(rootNode: rootNode, planningTime: nil, executionTime: nil, rawText: rawText)
    }
}

// MARK: - CockroachDB Parser

/// Parses CockroachDB `EXPLAIN` and `EXPLAIN ANALYZE` text output. CockroachDB
/// renders plans as a tree using `•` node markers with `│ ├── └──` tree-drawing
/// characters, and `key: value` properties indented beneath each node.
struct CockroachDBPlanParser: QueryPlanParser {
    private struct RawNode {
        let depth: Int
        let operation: String
        var properties: [String: String]
    }

    private static let knownKeys: Set<String> = ["estimated row count", "actual row count", "table"]
    private static let treeDecoration = CharacterSet(charactersIn: " \t│├└─")

    func parse(rawText: String) -> QueryPlan? {
        let lines = rawText.components(separatedBy: "\n")

        var planningTime: Double?
        var executionTime: Double?
        var nodes: [RawNode] = []

        for line in lines {
            guard let bulletRange = line.range(of: "•") else {
                let trimmed = line.trimmingCharacters(in: Self.treeDecoration)
                guard !trimmed.isEmpty, let (key, value) = Self.keyValue(trimmed) else { continue }
                switch key {
                case "planning time":
                    planningTime = Self.milliseconds(from: value)
                case "execution time":
                    executionTime = Self.milliseconds(from: value)
                default:
                    if !nodes.isEmpty {
                        nodes[nodes.count - 1].properties[key] = value
                    }
                }
                continue
            }

            let depth = line.distance(from: line.startIndex, to: bulletRange.lowerBound)
            let operation = line[bulletRange.upperBound...].trimmingCharacters(in: .whitespaces)
            nodes.append(RawNode(depth: depth, operation: operation, properties: [:]))
        }

        guard !nodes.isEmpty else { return nil }

        var index = 0
        func build(parentDepth: Int) -> [QueryPlanNode] {
            var result: [QueryPlanNode] = []
            while index < nodes.count {
                let raw = nodes[index]
                if raw.depth <= parentDepth { break }
                index += 1
                let children = build(parentDepth: raw.depth)
                result.append(Self.makeNode(raw, children: children))
            }
            return result
        }

        let roots = build(parentDepth: -1)
        let rootNode: QueryPlanNode
        if roots.count == 1 {
            rootNode = roots[0]
        } else {
            rootNode = QueryPlanNode(
                operation: "Query Plan",
                relation: nil, schema: nil, alias: nil,
                estimatedStartupCost: nil, estimatedTotalCost: nil,
                estimatedRows: nil, estimatedWidth: nil,
                actualStartupTime: nil, actualTotalTime: nil,
                actualRows: nil, actualLoops: nil,
                properties: [:],
                children: roots
            )
        }

        return QueryPlan(
            rootNode: rootNode,
            planningTime: planningTime,
            executionTime: executionTime,
            rawText: rawText
        )
    }

    private static func makeNode(_ raw: RawNode, children: [QueryPlanNode]) -> QueryPlanNode {
        let relation = raw.properties["table"].map { value in
            String(value.split(separator: "@").first ?? Substring(value))
        }
        let properties = raw.properties.filter { !knownKeys.contains($0.key) }
        return QueryPlanNode(
            operation: raw.operation.isEmpty ? "Unknown" : raw.operation,
            relation: relation,
            schema: nil,
            alias: nil,
            estimatedStartupCost: nil,
            estimatedTotalCost: nil,
            estimatedRows: rowCount(from: raw.properties["estimated row count"]),
            estimatedWidth: nil,
            actualStartupTime: nil,
            actualTotalTime: nil,
            actualRows: rowCount(from: raw.properties["actual row count"]),
            actualLoops: nil,
            properties: properties,
            children: children
        )
    }

    private static func keyValue(_ line: String) -> (key: String, value: String)? {
        guard let separator = line.range(of: ": ") else { return nil }
        let key = String(line[..<separator.lowerBound])
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        let value = String(line[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private static func rowCount(from value: String?) -> Int? {
        guard let value else { return nil }
        let digits = value.prefix { $0.isNumber || $0 == "," }
            .filter { $0 != "," }
        return Int(digits)
    }

    private static func milliseconds(from value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let numberPart = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let number = Double(numberPart) else { return nil }
        let unit = trimmed.dropFirst(numberPart.count).trimmingCharacters(in: .whitespaces).lowercased()
        switch unit {
        case "s": return number * 1_000
        case "µs", "us": return number / 1_000
        default: return number
        }
    }
}

// MARK: - Factory

enum QueryPlanParserFactory {
    static func parser(for databaseType: DatabaseType) -> QueryPlanParser? {
        switch databaseType {
        case .postgresql, .redshift:
            return PostgreSQLPlanParser()
        case .cockroachdb:
            return CockroachDBPlanParser()
        case .mysql, .mariadb:
            return MySQLPlanParser()
        case .sqlite:
            return SQLitePlanParser()
        case .clickhouse, .duckdb:
            return IndentedTextPlanParser()
        default:
            return nil
        }
    }
}
